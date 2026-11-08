import Foundation

/// A tile in the Web Mercator (EPSG:3857, "XYZ") pyramid: the same grid the imagery sources use,
/// so a terrain tile and its imagery line up exactly.
public struct TileKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    public var description: String { "\(z)/\(x)/\(y)" }

    public var parent: TileKey? { z > 0 ? TileKey(z: z - 1, x: x / 2, y: y / 2) : nil }

    public var children: [TileKey] {
        [TileKey(z: z + 1, x: 2 * x, y: 2 * y), TileKey(z: z + 1, x: 2 * x + 1, y: 2 * y),
         TileKey(z: z + 1, x: 2 * x, y: 2 * y + 1), TileKey(z: z + 1, x: 2 * x + 1, y: 2 * y + 1)]
    }

    public static func < (a: TileKey, b: TileKey) -> Bool { (a.z, a.x, a.y) < (b.z, b.x, b.y) }

    public init?(path: String) {
        let parts = path.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(z: parts[0], x: parts[1], y: parts[2])
    }
}

/// Spherical Web Mercator maths. Latitudes are clamped to the projection's +-85.0511 degree limit.
public enum WebMercator {
    public static let maxLatitude = 85.051_128_779_806_59
    /// Half the projected world width, metres.
    public static let originShift = 20_037_508.342_789_244

    /// Fractional tile coordinates of a point at a zoom level.
    public static func tileCoordinates(latitude: Double, longitude: Double, zoom: Int) -> (x: Double, y: Double) {
        let lat = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        let n = Double(1 << zoom)
        let x = (longitude + 180) / 360 * n
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        return (x, y)
    }

    public static func tile(latitude: Double, longitude: Double, zoom: Int) -> TileKey {
        let t = tileCoordinates(latitude: latitude, longitude: longitude, zoom: zoom)
        let n = 1 << zoom
        return TileKey(z: zoom, x: min(max(Int(t.x), 0), n - 1), y: min(max(Int(t.y), 0), n - 1))
    }

    /// Latitude and longitude of fractional tile coordinates.
    public static func coordinate(x: Double, y: Double, zoom: Int) -> (latitude: Double, longitude: Double) {
        let n = Double(1 << zoom)
        let lon = x / n * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi
        return (lat, lon)
    }

    /// Geographic bounds of a tile.
    public static func bounds(_ k: TileKey) -> (south: Double, north: Double, west: Double, east: Double) {
        let nw = coordinate(x: Double(k.x), y: Double(k.y), zoom: k.z)
        let se = coordinate(x: Double(k.x + 1), y: Double(k.y + 1), zoom: k.z)
        return (se.latitude, nw.latitude, nw.longitude, se.longitude)
    }

    /// Projected EPSG:3857 metres of a point.
    public static func project(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let lat = min(max(latitude, -maxLatitude), maxLatitude) * .pi / 180
        return (longitude * originShift / 180, log(tan(.pi / 4 + lat / 2)) * originShift / .pi)
    }

    /// Projected metres of fractional tile coordinates.
    public static func projected(x: Double, y: Double, zoom: Int) -> (x: Double, y: Double) {
        let size = 2 * originShift / Double(1 << zoom)
        return (-originShift + x * size, originShift - y * size)
    }
}
