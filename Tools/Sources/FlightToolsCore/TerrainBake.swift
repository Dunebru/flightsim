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
        Ring(zooms: 6...7, radiusKilometres: 700),      // to the horizon from cruise altitude
        Ring(zooms: 8...9, radiusKilometres: 350),
        Ring(zooms: 10...11, radiusKilometres: 150),
        Ring(zooms: 12...13, radiusKilometres: 40),
        Ring(zooms: 14...14, radiusKilometres: 12),
        Ring(zooms: 15...15, radiusKilometres: 5),      // the airport and its approaches
        Ring(zooms: 16...16, radiusKilometres: 2.6),
    ])

    public init(rings: [Ring]) { self.rings = rings }

    /// Every tile from zoom 0 to `maxZoom`: the coarse global base under the regions.
    public static func world(maxZoom: Int) -> [TileKey] {
        (0...maxZoom).flatMap { z in (0..<(1 << z)).flatMap { x in (0..<(1 << z)).map { y in TileKey(z: z, x: x, y: y) } } }
    }

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
        // A tile refines only when all four children exist, so complete every sibling set: the
        // ring edges would otherwise stop refining a level early.
        // At the coarsest level the parents live in another pack (the world base), so complete
        // those sets unconditionally.
        let minZoom = rings.flatMap(\.zooms).min() ?? 0
        for k in set.sorted() {
            if let p = k.parent, k.z == minZoom || set.contains(p) { set.formUnion(p.children) }
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

/// Bakes a scenery pack. Heights: AWS Terrain Tiles for the regional levels (out to the
/// horizon), the local 30 m DEM for the detailed levels. Imagery: EOX Sentinel-2 cloudless for
/// the regional levels, USGS orthoimagery for the detailed ones, colour-matched to the EOX
/// mosaic so detail levels do not show a seam.
public struct TerrainBaker: Sendable {
    public let dem: DEMRaster?
    public let terrarium: TerrariumSource?
    /// Levels at or below this take their heights from `terrarium` (when given).
    public let terrariumMaxZoom: Int
    public let output: URL
    public let name: String
    /// Raw downloads, per source: <cache>/<source>/<z>/<x>/<y>.jpg. nil: heights only.
    public let imageryCache: URL?
    /// Levels at or above this use USGS imagery; nil: EOX everywhere.
    public let usgsFromZoom: Int?

    public init(dem: DEMRaster?, terrarium: TerrariumSource?, terrariumMaxZoom: Int, output: URL, name: String,
                imageryCache: URL?, usgsFromZoom: Int?) {
        self.dem = dem
        self.terrarium = terrarium
        self.terrariumMaxZoom = terrariumMaxZoom
        self.output = output
        self.name = name
        self.imageryCache = imageryCache
        self.usgsFromZoom = usgsFromZoom
    }

    func source(for k: TileKey) -> ImagerySource {
        if let z = usgsFromZoom, k.z >= z { return .usgs }
        return .eox
    }

    /// Writes heights and imagery for every tile with a height source; returns the index.
    public func bake(tiles: [TileKey], log: @Sendable (String) -> Void = { _ in }) async throws -> SceneryPackIndex {
        let fm = FileManager.default
        var baked: [TileKey] = []
        var fromTerrarium = 0
        if let terrarium {
            // Regional levels always use the terrain tiles; detailed levels only past the DEM.
            let needed = tiles.filter { $0.z <= terrariumMaxZoom || dem?.heights(for: $0) == nil }
            try await terrarium.prefetch(needed, log: log)
        }
        for k in tiles {
            var h: [Float]?
            if let terrarium, k.z <= terrariumMaxZoom {
                h = try await terrarium.heights(for: k)
                fromTerrarium += 1
            } else {
                h = dem?.heights(for: k)
                // Past the DEM's edge, fall back to the terrain tiles so sibling sets stay whole.
                if h == nil, let terrarium {
                    h = try await terrarium.heights(for: k)
                    fromTerrarium += 1
                }
            }
            guard let h else { continue }
            let url = output.appendingPathComponent(SceneryPack.heightsPath(k))
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SceneryPack.encodeHeights(h).write(to: url)
            baked.append(k)
        }
        log("heights: \(baked.count) of \(tiles.count) tiles (\(fromTerrarium) from terrain tiles, the rest from the DEM)")

        var sources: [String] = []
        if let cache = imageryCache {
            // Raw downloads for every tile, plus EOX at the first USGS level as the colour reference.
            let reference = usgsFromZoom.map { z in baked.filter { $0.z == z } } ?? []
            try await Self.ensureCached(baked.map { ($0, source(for: $0)) } + reference.map { ($0, .eox) }, cache: cache, log: log)
            var transfer: (ColourStats, ColourStats)?
            if !reference.isEmpty {
                func stats(_ s: ImagerySource) throws -> ColourStats {
                    ColourStats.of(try reference.compactMap { k in ImageCodec.decode(try Data(contentsOf: Self.cached(k, s, cache)))?.pixels })
                }
                let usgs = try stats(.usgs), eox = try stats(.eox)
                transfer = (usgs, eox)
                log(String(format: "colour match at zoom %d: USGS mean %.0f %.0f %.0f -> EOX %.0f %.0f %.0f",
                           usgsFromZoom!, usgs.mean.x, usgs.mean.y, usgs.mean.z, eox.mean.x, eox.mean.y, eox.mean.z))
            }
            for k in baked {
                let raw = try Data(contentsOf: Self.cached(k, source(for: k), cache))
                var out = raw
                if source(for: k) == .usgs, let (from, to) = transfer, let img = ImageCodec.decode(raw),
                   let jpeg = ImageCodec.encodeJPEG(from.transfer(img.pixels, to: to), width: img.width, height: img.height) {
                    out = jpeg
                }
                let dest = output.appendingPathComponent(SceneryPack.imageryPath(k))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try out.write(to: dest)
            }
            let used = Set(baked.map { source(for: $0) })
            sources = ImagerySource.allCases.filter(used.contains).map { s in
                let zooms = baked.filter { source(for: $0) == s }.map(\.z)
                return "\(s.attribution), zoom \(zooms.min()!)-\(zooms.max()!)"
            }
        }
        let zooms = baked.map(\.z)
        var elevation: [String] = []
        if fromTerrarium > 0 {
            elevation.append("AWS Terrain Tiles (Mapzen/Tilezen terrarium; SRTM, NED, GMTED2010, ETOPO1), zoom \(zooms.min()!)-\(terrariumMaxZoom)")
        }
        if baked.count > fromTerrarium {
            elevation.append("Copernicus GLO-30 DEM (produced using Copernicus WorldDEM-30), zoom \(terrariumMaxZoom + 1)-\(zooms.max()!)")
        }
        let index = SceneryPackIndex(
            name: name, heightSamples: 65, minZoom: zooms.min() ?? 0, maxZoom: zooms.max() ?? 0,
            tiles: baked.map(\.description),
            heightDatum: "mean sea level (EGM2008 / NAVD88 / EGM96 by source)",
            imagerySource: sources.joined(separator: "; "),
            elevationSource: elevation.joined(separator: "; ")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: output.appendingPathComponent("index.json"))
        return index
    }

    static func cached(_ k: TileKey, _ s: ImagerySource, _ cache: URL) -> URL {
        cache.appendingPathComponent("\(s.rawValue)/\(k.z)/\(k.x)/\(k.y).jpg")
    }

    /// Downloads whatever is not cached yet, four at a time.
    static func ensureCached(_ wanted: [(TileKey, ImagerySource)], cache: URL, log: @Sendable (String) -> Void) async throws {
        let missing = wanted.filter { !FileManager.default.fileExists(atPath: cached($0.0, $0.1, cache).path) }
        log("imagery: \(missing.count) of \(wanted.count) tiles to download")
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = missing.makeIterator()
            func add() {
                guard let (k, s) = iterator.next() else { return }
                group.addTask {
                    let data = try await Downloader.get(s.url(k))
                    let dest = cached(k, s, cache)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: dest)
                }
            }
            for _ in 0..<4 { add() }
            var done = 0
            while try await group.next() != nil {
                done += 1
                if done % 100 == 0 { log("imagery: \(done) of \(missing.count)") }
                add()
            }
        }
    }
}
