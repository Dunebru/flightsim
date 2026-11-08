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

    public init(name: String, heightSamples: Int, minZoom: Int, maxZoom: Int, tiles: [String],
                heightDatum: String, imagerySource: String, elevationSource: String) {
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
