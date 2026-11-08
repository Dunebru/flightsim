import Foundation
public import SimCore

/// The solid ground for physics and cameras: heights read straight from the scenery pack (the
/// finest tile that covers a point, loaded on demand), with runway areas held flat exactly as the
/// renderer draws them. Outside the pack the ground is the scene origin's height.
public struct GroundModel: Sendable {
    public let scenery: SceneryLibrary?
    public let frame: LocalFrame
    public let flatten: [GroundOverride]
    private var field: HeightField
    private var order: [TileKey] = []
    private var missing: Set<TileKey> = []
    /// Tiles kept in memory (each 65 x 65 floats, 17 KB).
    public var capacity = 96

    public init(scenery: SceneryLibrary?, frame: LocalFrame, flatten: [GroundOverride]) {
        self.scenery = scenery
        self.frame = frame
        self.flatten = flatten
        field = HeightField(samples: scenery?.heightSamples ?? 65, maxZoom: scenery?.maxZoom ?? 0)
    }

    /// Ground height above mean sea level, metres.
    public mutating func height(latitude: Double, longitude: Double) -> Double {
        var h = rawHeight(latitude: latitude, longitude: longitude) ?? frame.origin.height
        if !flatten.isEmpty {
            let p = frame.enu(Geodetic(latitude: latitude, longitude: longitude, height: frame.origin.height))
            for area in flatten {
                let w = area.weight(SIMD2(p.x, p.y))
                if w > 0 { h = h * (1 - w) + (frame.origin.height + area.height(at: SIMD2(p.x, p.y))) * w }
            }
        }
        return h
    }

    /// Ground under an ENU point, as an ENU height (includes Earth's curvature drop).
    public mutating func groundZ(atENU p: SIMD3<Double>) -> Double {
        let g = frame.geodetic(p)
        return frame.enu(Geodetic(latitude: g.latitude, longitude: g.longitude,
                                  height: height(latitude: g.latitude, longitude: g.longitude))).z
    }

    /// Pack height without flattening, or nil outside the pack.
    public mutating func rawHeight(latitude: Double, longitude: Double) -> Double? {
        guard let scenery else { return nil }
        for z in stride(from: scenery.maxZoom, through: scenery.minZoom, by: -1) {
            let t = WebMercator.tileCoordinates(latitude: latitude, longitude: longitude, zoom: z)
            let key = TileKey(z: z, x: Int(t.x), y: Int(t.y))
            guard scenery.available.contains(key), !missing.contains(key) else { continue }
            if field.tiles[key] == nil {
                guard let heights = try? scenery.heights(key) else { missing.insert(key); continue }
                field.insert(key, heights: heights)
                order.append(key)
                if order.count > capacity { field.remove(order.removeFirst()) }
            }
            return field.height(latitude: latitude, longitude: longitude)
        }
        return nil
    }
}
