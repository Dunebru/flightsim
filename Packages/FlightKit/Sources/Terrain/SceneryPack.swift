public import Foundation

/// A baked scenery region on disk:
///
///     <pack>/index.json
///     <pack>/heights/<z>/<x>/<y>.h16    65 x 65 Float16, metres above mean sea level (EGM2008)
///     <pack>/imagery/<z>/<x>/<y>.jpg    256 x 256 imagery for the same tile
///
/// Height samples lie on the tile's corners and edges inclusive: row 0 is the north edge, column
/// 0 the west edge, so neighbouring tiles share their edge samples exactly.
public struct SceneryPackIndex: Codable, Sendable, Equatable {
    public var name: String
    public var heightSamples: Int
    public var minZoom: Int
    public var maxZoom: Int
    /// Tiles present, as "z/x/y".
    public var tiles: [String]
    public var heightDatum: String
    public var imagerySource: String
    public var elevationSource: String
    /// Source of the night-lights layer (zoom 8 and coarser tiles), when the pack has one.
    public var nightLightsSource: String?

    public init(name: String, heightSamples: Int, minZoom: Int, maxZoom: Int, tiles: [String],
                heightDatum: String, imagerySource: String, elevationSource: String, nightLightsSource: String? = nil) {
        self.nightLightsSource = nightLightsSource
        self.name = name
        self.heightSamples = heightSamples
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.tiles = tiles
        self.heightDatum = heightDatum
        self.imagerySource = imagerySource
        self.elevationSource = elevationSource
    }
}

/// Read access to a scenery pack.
public struct SceneryPack: Sendable {
    public let root: URL
    public let index: SceneryPackIndex
    public let available: Set<TileKey>

    public init(root: URL) throws {
        self.root = root
        let data = try Data(contentsOf: root.appendingPathComponent("index.json"))
        index = try JSONDecoder().decode(SceneryPackIndex.self, from: data)
        available = Set(index.tiles.compactMap(TileKey.init(path:)))
    }

    public static func heightsPath(_ k: TileKey) -> String { "heights/\(k.z)/\(k.x)/\(k.y).h16" }
    public static func imageryPath(_ k: TileKey) -> String { "imagery/\(k.z)/\(k.x)/\(k.y).jpg" }
    public static func nightPath(_ k: TileKey) -> String { "night/\(k.z)/\(k.x)/\(k.y).png" }
    /// Night lights exist for tiles at zoom 8 and coarser.
    public static let nightMaxZoom = 8

    public func nightURL(_ k: TileKey) -> URL? {
        guard index.nightLightsSource != nil, k.z <= Self.nightMaxZoom else { return nil }
        return root.appendingPathComponent(Self.nightPath(k))
    }

    public func heightsURL(_ k: TileKey) -> URL { root.appendingPathComponent(Self.heightsPath(k)) }
    public func imageryURL(_ k: TileKey) -> URL { root.appendingPathComponent(Self.imageryPath(k)) }

    /// The tile's height grid, row-major from the north-west corner, metres.
    public func heights(_ k: TileKey) throws -> [Float] {
        try Self.decodeHeights(Data(contentsOf: heightsURL(k)), count: index.heightSamples * index.heightSamples)
    }

    public static func encodeHeights(_ heights: [Float]) -> Data {
        var data = Data(capacity: heights.count * 2)
        for h in heights {
            let bits = Float16(h).bitPattern.littleEndian
            withUnsafeBytes(of: bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decodeHeights(_ data: Data, count: Int) throws -> [Float] {
        guard data.count == count * 2 else { throw CocoaError(.fileReadCorruptFile) }
        return data.withUnsafeBytes { raw in
            (0..<count).map { i in Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self)))) }
        }
    }
}

/// Several packs read as one: a coarse world base under detailed regions. Where packs share a
/// tile, the first pack listed wins.
public struct SceneryLibrary: Sendable {
    public let packs: [SceneryPack]
    public let available: Set<TileKey>
    public let heightSamples: Int
    public let minZoom: Int
    public let maxZoom: Int

    public init(packs: [SceneryPack]) {
        let samples = packs.first?.index.heightSamples ?? 65
        let usable = packs.filter { $0.index.heightSamples == samples }
        self.packs = usable
        available = usable.reduce(into: Set<TileKey>()) { $0.formUnion($1.available) }
        heightSamples = samples
        minZoom = usable.map(\.index.minZoom).min() ?? 0
        maxZoom = usable.map(\.index.maxZoom).max() ?? 0
    }

    public init(_ pack: SceneryPack) { self.init(packs: [pack]) }

    private init(packs: [SceneryPack], available: Set<TileKey>) {
        self.packs = packs
        self.available = available
        heightSamples = packs.first?.index.heightSamples ?? 65
        minZoom = available.map(\.z).min() ?? 0
        maxZoom = available.map(\.z).max() ?? 0
    }

    /// The same packs with only some tiles (tests: remove coverage to prove a check fails).
    public func filtered(_ include: (TileKey) -> Bool) -> SceneryLibrary {
        SceneryLibrary(packs: packs, available: available.filter(include))
    }

    /// Every pack in a directory of packs (each a folder with an index.json), detailed regions
    /// first, the world base last.
    public init(directory: URL) {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let packs = folders.compactMap { try? SceneryPack(root: $0) }
            .sorted { ($0.index.maxZoom, $0.index.name) > ($1.index.maxZoom, $1.index.name) }
        self.init(packs: packs)
    }

    func pack(for k: TileKey) -> SceneryPack? { packs.first { $0.available.contains(k) } }

    public func heights(_ k: TileKey) throws -> [Float] {
        guard let p = pack(for: k) else { throw CocoaError(.fileNoSuchFile) }
        return try p.heights(k)
    }

    public func imageryURL(_ k: TileKey) -> URL? { pack(for: k)?.imageryURL(k) }
    public func nightURL(_ k: TileKey) -> URL? { pack(for: k)?.nightURL(k) }
}
