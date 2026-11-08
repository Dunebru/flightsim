import Foundation
import Terrain

/// A float32 elevation raster in EPSG:3857 written by `gdalwarp -of ENVI`, with its geotransform
/// from `gdalinfo -json`. Memory-mapped; samples are bilinear.
public struct DEMRaster: Sendable {
    public let width: Int
    public let height: Int
    public let originX: Double, pixelWidth: Double
    public let originY: Double, pixelHeight: Double   // pixelHeight is negative (north-up)
    private let data: Data

    public init(width: Int, height: Int, geoTransform: [Double], data: Data) {
        self.width = width
        self.height = height
        originX = geoTransform[0]
        pixelWidth = geoTransform[1]
        originY = geoTransform[3]
        pixelHeight = geoTransform[5]
        self.data = data
    }

    public init(binary: URL, info: URL) throws {
        struct Info: Decodable { let size: [Int]; let geoTransform: [Double] }
        let i = try JSONDecoder().decode(Info.self, from: Data(contentsOf: info))
        let d = try Data(contentsOf: binary, options: .alwaysMapped)
        guard d.count == i.size[0] * i.size[1] * 4 else { throw CocoaError(.fileReadCorruptFile) }
        self.init(width: i.size[0], height: i.size[1], geoTransform: i.geoTransform, data: d)
    }

    private func value(_ col: Int, _ row: Int) -> Float {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: (row * width + col) * 4, as: Float.self) }
    }

    /// Bilinear sample at projected metres, or nil outside the raster.
    public func sample(x: Double, y: Double) -> Float? {
        // Pixel centres sit at origin + (i + 0.5) * size.
        let fx = (x - originX) / pixelWidth - 0.5
        let fy = (y - originY) / pixelHeight - 0.5
        guard fx >= 0, fy >= 0, fx <= Double(width - 1), fy <= Double(height - 1) else { return nil }
        let x0 = min(Int(fx), width - 2), y0 = min(Int(fy), height - 2)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let a = value(x0, y0), b = value(x0 + 1, y0), c = value(x0, y0 + 1), d = value(x0 + 1, y0 + 1)
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    /// The 65 x 65 (or `samples` squared) height grid of a tile, north-west first; nil if any
    /// sample falls outside the raster.
    public func heights(for tile: TileKey, samples: Int = 65) -> [Float]? {
        var out = [Float]()
        out.reserveCapacity(samples * samples)
        let step = 1.0 / Double(samples - 1)
        for j in 0..<samples {
            for i in 0..<samples {
                let p = WebMercator.projected(x: Double(tile.x) + Double(i) * step, y: Double(tile.y) + Double(j) * step, zoom: tile.z)
                guard let h = sample(x: p.x, y: p.y) else { return nil }
                out.append(h)
            }
        }
        return out
    }
}

/// Which tiles to bake: rings of detail around a centre point.
public struct BakePlan: Sendable {
    public struct Ring: Sendable {
        public let zooms: ClosedRange<Int>
        public let radiusKilometres: Double
        public init(zooms: ClosedRange<Int>, radiusKilometres: Double) {
            self.zooms = zooms
            self.radiusKilometres = radiusKilometres
        }
    }
    public let rings: [Ring]

    /// The default airport region: coarse to the horizon, detailed near the field.
    public static let airportRegion = BakePlan(rings: [
        Ring(zooms: 8...11, radiusKilometres: 150),
        Ring(zooms: 12...13, radiusKilometres: 40),
        Ring(zooms: 14...14, radiusKilometres: 12),
    ])

    public init(rings: [Ring]) { self.rings = rings }

    /// Tiles whose centre lies within each ring's radius of the centre (great-circle distance).
    public func tiles(latitude: Double, longitude: Double) -> [TileKey] {
        var set = Set<TileKey>()
        for ring in rings {
            for z in ring.zooms {
                let c = WebMercator.tileCoordinates(latitude: latitude, longitude: longitude, zoom: z)
                // Generous search window in tiles, then filter by distance.
                let tileKm = 40_075.0 * cos(latitude * .pi / 180) / Double(1 << z)
                let r = Int((ring.radiusKilometres / tileKm).rounded(.up)) + 1
                for x in (Int(c.x) - r)...(Int(c.x) + r) {
                    for y in (Int(c.y) - r)...(Int(c.y) + r) {
                        let k = TileKey(z: z, x: x, y: y)
                        let mid = WebMercator.coordinate(x: Double(x) + 0.5, y: Double(y) + 0.5, zoom: z)
                        if Self.distanceKm(latitude, longitude, mid.latitude, mid.longitude) <= ring.radiusKilometres {
                            set.insert(k)
                        }
                    }
                }
            }
        }
        return set.sorted()
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371.0, p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}

/// Bakes a scenery pack: heights from the DEM and imagery from EOX Sentinel-2 cloudless.
public struct TerrainBaker: Sendable {
    public let dem: DEMRaster
    public let output: URL
    public let name: String
    public let downloadImagery: Bool
    /// EOX Sentinel-2 cloudless 2025 (CC BY-NC-SA 4.0), Web Mercator, {z}/{row}/{column}.
    public static let imageryTemplate = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/GoogleMapsCompatible/%d/%d/%d.jpg"

    public init(dem: DEMRaster, output: URL, name: String, downloadImagery: Bool) {
        self.dem = dem
        self.output = output
        self.name = name
        self.downloadImagery = downloadImagery
    }

    /// Writes heights (and imagery) for every tile the DEM fully covers; returns the index.
    public func bake(tiles: [TileKey], log: @Sendable (String) -> Void = { _ in }) async throws -> SceneryPackIndex {
        let fm = FileManager.default
        var baked: [TileKey] = []
        for k in tiles {
            guard let h = dem.heights(for: k) else { continue }
            let url = output.appendingPathComponent(SceneryPack.heightsPath(k))
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SceneryPack.encodeHeights(h).write(to: url)
            baked.append(k)
        }
        log("heights: \(baked.count) of \(tiles.count) tiles inside the DEM")

        if downloadImagery {
            let missing = baked.filter { !fm.fileExists(atPath: output.appendingPathComponent(SceneryPack.imageryPath($0)).path) }
            log("imagery: \(missing.count) tiles to download")
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = missing.makeIterator()
                func next() -> TileKey? { iterator.next() }
                for _ in 0..<4 {
                    guard let k = next() else { break }
                    group.addTask { try await Self.download(k, to: output) }
                }
                var done = 0
                while try await group.next() != nil {
                    done += 1
                    if done % 100 == 0 { log("imagery: \(done) of \(missing.count)") }
                    if let k = next() { group.addTask { try await Self.download(k, to: output) } }
                }
            }
        }
        let zooms = baked.map(\.z)
        let index = SceneryPackIndex(
            name: name, heightSamples: 65, minZoom: zooms.min() ?? 0, maxZoom: zooms.max() ?? 0,
            tiles: baked.map(\.description),
            heightDatum: "EGM2008 (mean sea level)",
            imagerySource: "EOX Sentinel-2 cloudless 2025 (CC BY-NC-SA 4.0), https://s2maps.eu",
            elevationSource: "Copernicus GLO-30 DEM (produced using Copernicus WorldDEM-30)"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: output.appendingPathComponent("index.json"))
        return index
    }

    static func download(_ k: TileKey, to output: URL) async throws {
        let url = URL(string: String(format: imageryTemplate, k.z, k.y, k.x))!
        var request = URLRequest(url: url)
        request.setValue("flightsim-personal-test", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 100 else {
                    throw URLError(.badServerResponse)
                }
                let dest = output.appendingPathComponent(SceneryPack.imageryPath(k))
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
                return
            } catch where attempt < 2 {
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
    }
}
