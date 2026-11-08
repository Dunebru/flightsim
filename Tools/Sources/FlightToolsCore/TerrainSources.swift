import CoreGraphics
import Foundation
import ImageIO
import Terrain
import UniformTypeIdentifiers

// MARK: - Elevation: AWS Terrain Tiles

/// Elevation tiles from the AWS Open Data "Terrain Tiles" set (Mapzen/Tilezen, terrarium PNG
/// encoding: height = R * 256 + G + B / 256 - 32768 metres). Built from public sources (SRTM,
/// NED, GMTED2010, ETOPO1 and others); used for the regional ring out to the horizon, where a
/// 30 m DEM would be wasted. Tiles are cached on disk.
public actor TerrariumSource {
    public static let template = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png"
    public let cache: URL
    private var decoded: [TileKey: [Float]] = [:]
    private let fetch: @Sendable (TileKey) async throws -> Data

    public init(cache: URL) {
        self.cache = cache
        fetch = { k in try await Downloader.get(String(format: Self.template, k.z, k.x, k.y)) }
    }

    /// For tests: tiles from a closure instead of the network.
    init(cache: URL, fetch: @escaping @Sendable (TileKey) async throws -> Data) {
        self.cache = cache
        self.fetch = fetch
    }

    /// Source zoom used for a target tile's heights.
    public nonisolated static func sourceZoom(for k: TileKey) -> Int { k.z <= 5 ? k.z : min(k.z + 1, 15) }

    /// Source tiles a target needs: its own footprint at the source zoom plus a one-tile margin
    /// (bilinear samples on the edge reach into neighbours).
    public nonisolated static func sources(for k: TileKey) -> Set<TileKey> {
        let zs = sourceZoom(for: k)
        let n = 1 << zs
        // The target's footprint in source tiles: several when the source is finer, the one
        // ancestor when it is coarser (zoom 16 and up read zoom 15).
        let lo: SIMD2<Int>, hi: SIMD2<Int>
        if zs >= k.z {
            let scale = 1 << (zs - k.z)
            lo = SIMD2(k.x * scale, k.y * scale)
            hi = SIMD2(k.x * scale + scale - 1, k.y * scale + scale - 1)
        } else {
            let shift = k.z - zs
            lo = SIMD2(k.x >> shift, k.y >> shift)
            hi = lo
        }
        var out = Set<TileKey>()
        for x in (lo.x - 1)...(hi.x + 1) {
            for y in (lo.y - 1)...(hi.y + 1) {
                out.insert(TileKey(z: zs, x: (x + n) % n, y: min(max(y, 0), n - 1)))
            }
        }
        return out
    }

    /// Downloads every source tile the targets need that is not cached yet, eight at a time.
    public func prefetch(_ targets: [TileKey], log: @Sendable (String) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let all = targets.reduce(into: Set<TileKey>()) { $0.formUnion(Self.sources(for: $1)) }
        let missing = all.filter { !fm.fileExists(atPath: cache.appendingPathComponent("\($0.z)/\($0.x)/\($0.y).png").path) }.sorted()
        log("terrain tiles: \(missing.count) of \(all.count) to download")
        let fetch = self.fetch, cache = self.cache
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = missing.makeIterator()
            func add() {
                guard let k = iterator.next() else { return }
                group.addTask {
                    let data = try await fetch(k)
                    let file = cache.appendingPathComponent("\(k.z)/\(k.x)/\(k.y).png")
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file)
                }
            }
            for _ in 0..<8 { add() }
            var done = 0
            while try await group.next() != nil {
                done += 1
                if done % 250 == 0 { log("terrain tiles: \(done) of \(missing.count)") }
                add()
            }
        }
    }

    /// Height in metres of one terrarium pixel.
    public nonisolated static func height(r: UInt8, g: UInt8, b: UInt8) -> Float {
        Float(r) * 256 + Float(g) + Float(b) / 256 - 32_768
    }

    /// The decoded 256 x 256 heights of a source tile, row-major from the north-west.
    func tile(_ k: TileKey) async throws -> [Float] {
        if let t = decoded[k] { return t }
        let file = cache.appendingPathComponent("\(k.z)/\(k.x)/\(k.y).png")
        let data: Data
        if let d = try? Data(contentsOf: file) {
            data = d
        } else {
            data = try await fetch(k)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        guard let heights = Self.decode(data) else { throw CocoaError(.fileReadCorruptFile) }
        decoded[k] = heights
        if decoded.count > 256 { decoded.removeAll() }
        return heights
    }

    /// Reads the PNG's stored bytes directly (no colour management, which would alter the
    /// encoded heights).
    nonisolated static func decode(_ data: Data) -> [Float]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              img.width == 256, img.height == 256, img.bitsPerComponent == 8,
              let bytes = img.dataProvider?.data as Data? else { return nil }
        let bpp = img.bitsPerPixel / 8, row = img.bytesPerRow
        guard bpp >= 3 else { return nil }
        var out = [Float](repeating: 0, count: 256 * 256)
        bytes.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<256 {
                for x in 0..<256 {
                    let i = y * row + x * bpp
                    out[y * 256 + x] = height(r: p[i], g: p[i + 1], b: p[i + 2])
                }
            }
        }
        return out
    }

    /// Bilinear height at fractional tile coordinates of zoom `z` (pixel centres at +0.5),
    /// continuous across source-tile boundaries.
    func sample(x: Double, y: Double, zoom z: Int) async throws -> Float {
        let px = x * 256 - 0.5, py = y * 256 - 0.5
        let x0 = Int(floor(px)), y0 = Int(floor(py))
        let tx = Float(px - Double(x0)), ty = Float(py - Double(y0))
        let n = 1 << z
        func at(_ gx: Int, _ gy: Int) async throws -> Float {
            let cx = min(max(gx, 0), n * 256 - 1), cy = min(max(gy, 0), n * 256 - 1)
            let t = try await tile(TileKey(z: z, x: cx / 256, y: cy / 256))
            return t[(cy % 256) * 256 + cx % 256]
        }
        let a = try await at(x0, y0), b = try await at(x0 + 1, y0)
        let c = try await at(x0, y0 + 1), d = try await at(x0 + 1, y0 + 1)
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// The `samples`-squared corner-inclusive height grid of a target tile, sampled from source
    /// tiles one level finer (512 source pixels across 64 sample intervals; capped at zoom 15).
    /// The global base (zoom 5 and coarser) samples its own level, which is plenty there.
    public func heights(for k: TileKey, samples: Int = 65) async throws -> [Float] {
        let zs = Self.sourceZoom(for: k)
        // Fractional when the source is coarser than the target (1 << negative is 0).
        let scale = pow(2, Double(zs - k.z))
        let step = 1.0 / Double(samples - 1)
        var out = [Float]()
        out.reserveCapacity(samples * samples)
        for j in 0..<samples {
            for i in 0..<samples {
                let x = (Double(k.x) + Double(i) * step) * scale
                let y = (Double(k.y) + Double(j) * step) * scale
                // The set carries ocean depths; the drawn surface over the sea is the water,
                // at sea level. (Land below sea level, such as Death Valley, is raised to it
                // from this source; a local DEM keeps it.)
                out.append(max(0, try await sample(x: x, y: y, zoom: zs)))
            }
        }
        return out
    }
}

// MARK: - Imagery

public enum ImagerySource: String, Sendable, CaseIterable {
    /// EOX Sentinel-2 cloudless 2025, 10 m, CC BY-NC-SA 4.0 (personal, non-commercial use).
    case eox
    /// USGS The National Map orthoimagery (NAIP-based in the US), public domain, cached to
    /// zoom 16 (about 2 m per pixel at Phoenix).
    case usgs
    /// USDA NAIP aerial photography (0.6 m, public domain) through Microsoft Planetary
    /// Computer's mosaic tiler, for the levels finer than the USGS cache (zoom 17 and 18).
    case naip

    /// `naipSearch`: a Planetary Computer mosaic search registered for the region.
    public func url(_ k: TileKey, naipSearch: String? = nil) -> String {
        switch self {
        case .eox: String(format: "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/GoogleMapsCompatible/%d/%d/%d.jpg", k.z, k.y, k.x)
        case .usgs: String(format: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/tile/%d/%d/%d", k.z, k.y, k.x)
        case .naip:
            "https://planetarycomputer.microsoft.com/api/data/v1/mosaic/\(naipSearch ?? "")/tiles/WebMercatorQuad/\(k.z)/\(k.x)/\(k.y)@1x"
                + "?collection=naip&assets=image&asset_bidx=image%7C1%2C2%2C3&nodata=0&format=jpg"
        }
    }

    /// Registers a NAIP mosaic over a bounding box (newest imagery first) and returns its id.
    public static func registerNAIP(south: Double, west: Double, north: Double, east: Double) async throws -> String {
        var request = URLRequest(url: URL(string: "https://planetarycomputer.microsoft.com/api/data/v1/mosaic/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = """
        {"collections":["naip"],"filter-lang":"cql2-json","filter":{"op":"and","args":[{"op":"s_intersects","args":[{"property":"geometry"},\
        {"type":"Polygon","coordinates":[[[\(west),\(south)],[\(east),\(south)],[\(east),\(north)],[\(west),\(north)],[\(west),\(south)]]]}]},\
        {"op":">=","args":[{"property":"datetime"},"2019-01-01T00:00:00Z"]}]},"sortby":[{"field":"datetime","direction":"desc"}]}
        """
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Reply: Decodable { let searchid: String }
        return try JSONDecoder().decode(Reply.self, from: data).searchid
    }

    public var attribution: String {
        switch self {
        case .eox: "EOX Sentinel-2 cloudless 2025 (CC BY-NC-SA 4.0), https://s2maps.eu"
        case .usgs: "USGS The National Map orthoimagery (public domain)"
        case .naip: "USDA NAIP aerial imagery via Microsoft Planetary Computer (public domain)"
        }
    }
}

/// NASA Black Marble 2016 night lights (VIIRS, public domain) from NASA GIBS, zoom 0-8.
public enum NightLights {
    public static func url(_ k: TileKey) -> String {
        "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/VIIRS_Black_Marble/default/2016-01-01/GoogleMapsCompatible_Level8/\(k.z)/\(k.y)/\(k.x).png"
    }
    public static let attribution = "NASA Black Marble 2016 (VIIRS), via NASA GIBS (public domain)"

    /// The lights alone, 0-255 grey: the composite paints moonlit land dark blue (red about half
    /// the blue) while lights are warm, so (R - 0.55 B - 5) / 150 keeps the lights and drops the land.
    public static func lights(fromRGBA px: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: px.count / 4)
        for i in 0..<out.count {
            let r = Double(px[i * 4]), b = Double(px[i * 4 + 2])
            out[i] = UInt8(max(0, min(255, ((r - 0.55 * b - 5) / 150 * 255).rounded())))
        }
        return out
    }
}

/// Per-channel mean and standard deviation of a set of images (sRGB 0-255).
public struct ColourStats: Sendable, Equatable {
    public var mean: SIMD3<Double>
    public var std: SIMD3<Double>

    public static func of(_ images: [[UInt8]]) -> ColourStats {
        var sum = SIMD3<Double>.zero, sq = SIMD3<Double>.zero, n = 0.0
        for px in images {
            for i in stride(from: 0, to: px.count, by: 4) {
                let v = SIMD3(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
                sum += v; sq += v * v; n += 1
            }
        }
        let mean = sum / max(n, 1)
        let variance = sq / max(n, 1) - mean * mean
        return ColourStats(mean: mean, std: SIMD3(variance.x.squareRoot(), variance.y.squareRoot(), variance.z.squareRoot()))
    }

    /// Maps pixels with these statistics onto `target`'s (Reinhard-style transfer per channel).
    public func transfer(_ px: [UInt8], to target: ColourStats) -> [UInt8] {
        var out = px
        let gain = target.std / SIMD3(max(std.x, 1), max(std.y, 1), max(std.z, 1))
        for i in stride(from: 0, to: px.count, by: 4) {
            for c in 0..<3 {
                let v = (Double(px[i + c]) - mean[c]) * gain[c] + target.mean[c]
                out[i + c] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        return out
    }
}

enum ImageCodec {
    /// Decodes to RGBA8 sRGB.
    static func decode(_ data: Data) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (px, w, h) : nil
    }

    /// RGBA8 to PNG (lossless; tests encode terrarium heights with it).
    static func encodePNG(_ px: [UInt8]) -> Data {
        let data = NSMutableData()
        let img = CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// 8-bit grey PNG.
    static func encodeGreyPNG(_ px: [UInt8], width: Int, height: Int) -> Data? {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func encodeJPEG(_ px: [UInt8], width: Int, height: Int, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

enum Downloader {
    static func get(_ url: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("flightsim-personal-test", forHTTPHeaderField: "User-Agent")
        var lastError: any Error = URLError(.unknown)
        for attempt in 0..<4 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100 else {
                    throw URLError(.badServerResponse)
                }
                return data
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw lastError
    }
}
