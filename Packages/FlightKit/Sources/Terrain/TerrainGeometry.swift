import Foundation
public import SimCore
import simd

/// A rectangle in the scene's ENU frame where the ground is held flat at a fixed height
/// (runways and aprons, so generated terrain never covers the drawn pavement).
public struct FlattenArea: Sendable, Equatable {
    public var centre: SIMD2<Double>
    /// Half extents along the area's own axes, metres.
    public var halfLength: Double
    public var halfWidth: Double
    /// Direction of the long axis, radians counter-clockwise from east.
    public var angle: Double
    /// Height above the scene origin at the centre, metres.
    public var height: Double
    /// Rise per metre along the long axis (positive toward `angle`), so a sloped runway stays
    /// sloped.
    public var gradient: Double

    public init(centre: SIMD2<Double>, halfLength: Double, halfWidth: Double, angle: Double, height: Double,
                gradient: Double = 0) {
        self.centre = centre
        self.halfLength = halfLength
        self.halfWidth = halfWidth
        self.angle = angle
        self.height = height
        self.gradient = gradient
    }

    /// The held height at a point (metres above the scene origin), following the gradient.
    public func height(at p: SIMD2<Double>) -> Double {
        let d = p - centre
        let along = d.x * cos(angle) + d.y * sin(angle)
        return height + gradient * max(-halfLength, min(halfLength, along))
    }

    /// 0 outside, 1 inside, blending over `margin` metres so the edge is a gentle slope.
    public func weight(_ p: SIMD2<Double>, margin: Double = 60) -> Double {
        let d = p - centre
        let u = abs(d.x * cos(angle) + d.y * sin(angle)) - halfLength
        let v = abs(-d.x * sin(angle) + d.y * cos(angle)) - halfWidth
        let outside = max(u, v)
        if outside <= 0 { return 1 }
        return max(0, 1 - outside / margin)
    }
}

/// Render-ready geometry of one terrain tile, positioned in the scene's ENU frame.
public struct TerrainTileGeometry: Sendable {
    public let key: TileKey
    /// Tile centre in the scene ENU frame (metres). Vertex positions are relative to it.
    public let centre: SIMD3<Double>
    /// Interleaved per vertex: position (relative to centre), normal, uv. Grid first, then skirts.
    public let positions: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let uvs: [SIMD2<Float>]
    public let indices: [UInt16]
    /// Per vertex: open water (height at sea level, where ocean depths were clamped).
    public let water: [Bool]
    /// Bounding radius around `centre`, metres.
    public let radius: Double

    /// Builds the mesh: sample (i, j) sits at fractional tile coordinates (x + i/(n-1),
    /// y + j/(n-1)), at its height above mean sea level, placed through real geodesy so Earth's
    /// curvature is exact. Skirts hang below every edge to hide cracks between levels of detail.
    public static func build(key: TileKey, heights: [Float], samples n: Int, frame: LocalFrame,
                             flatten: [GroundOverride] = []) -> TerrainTileGeometry {
        var world = [SIMD3<Double>]()
        world.reserveCapacity(n * n)
        let step = 1.0 / Double(n - 1)
        for j in 0..<n {
            for i in 0..<n {
                let c = WebMercator.coordinate(x: Double(key.x) + Double(i) * step, y: Double(key.y) + Double(j) * step, zoom: key.z)
                var p = frame.enu(Geodetic(latitude: c.latitude, longitude: c.longitude, height: Double(heights[j * n + i])))
                for area in flatten {
                    let w = area.weight(SIMD2(p.x, p.y))
                    if w > 0 {
                        // Heights are relative to the origin; ENU z includes curvature drop,
                        // which is negligible across an airport, so blend z directly.
                        p.z = p.z * (1 - w) + area.height(at: SIMD2(p.x, p.y)) * w
                    }
                }
                world.append(p)
            }
        }
        let centre = world[(n / 2) * n + n / 2]
        var positions = world.map { SIMD3<Float>($0 - centre) }

        // Normals from neighbouring samples (central differences, one-sided at the edges).
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: n * n)
        for j in 0..<n {
            for i in 0..<n {
                let l = positions[j * n + max(i - 1, 0)], r = positions[j * n + min(i + 1, n - 1)]
                let u = positions[max(j - 1, 0) * n + i], d = positions[min(j + 1, n - 1) * n + i]
                // Rows run north to south, so (u - d) points north.
                let nrm = simd_cross(r - l, u - d)
                normals[j * n + i] = simd_length_squared(nrm) > 0 ? simd_normalize(nrm) : SIMD3(0, 0, 1)
            }
        }
        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(n * n)
        for j in 0..<n { for i in 0..<n { uvs.append(SIMD2(Float(Double(i) * step), Float(Double(j) * step))) } }

        var water = heights.map { $0 <= 0.3 }
        // Skirts: a copy of each edge, dropped by a depth proportional to the tile's size.
        var radius = 0.0
        for p in positions { radius = max(radius, Double(simd_length(p))) }
        let depth = Float(max(radius * 0.04, 5))
        for edge in edges(n) {
            for idx in edge {
                positions.append(positions[idx] - SIMD3(0, 0, depth))
                normals.append(normals[idx])
                uvs.append(uvs[idx])
                water.append(water[idx])
            }
        }
        return TerrainTileGeometry(key: key, centre: centre, positions: positions, normals: normals,
                                   uvs: uvs, indices: indices(samples: n), water: water, radius: radius)
    }

    /// Edge vertex indices: north (west to east), south, west (north to south), east.
    static func edges(_ n: Int) -> [[Int]] {
        [(0..<n).map { $0 }, (0..<n).map { (n - 1) * n + $0 }, (0..<n).map { $0 * n }, (0..<n).map { $0 * n + n - 1 }]
    }

    /// Triangle list for a tile of `samples` squared: the grid, then the four skirts. The same for
    /// every tile, so the renderer shares one index buffer.
    public static func indices(samples n: Int) -> [UInt16] {
        var indices = [UInt16]()
        indices.reserveCapacity((n - 1) * (n - 1) * 6 + 4 * (n - 1) * 6)
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = UInt16(j * n + i), b = a + 1, c = UInt16((j + 1) * n + i), d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        var base = n * n
        for edge in edges(n) {
            for k in 0..<(n - 1) {
                let top0 = UInt16(edge[k]), top1 = UInt16(edge[k + 1])
                let bot0 = UInt16(base + k), bot1 = UInt16(base + k + 1)
                indices += [top0, bot0, top1, top1, bot0, bot1]
            }
            base += n
        }
        return indices
    }
}

/// Chooses which tiles to draw: a quadtree refined by distance, only into children that are all
/// loaded, so the drawn set never has holes or overlaps.
public enum TileSelector {
    /// - Parameters:
    ///   - roots: the coarsest tiles to start from.
    ///   - camera: camera position in the scene ENU frame.
    ///   - tileCentre: a tile's centre and radius in ENU (from loaded geometry or an estimate).
    ///   - isLoaded: whether a tile's geometry is ready to draw.
    ///   - wantsChildren: called for tiles that would refine if their children were loaded.
    ///   - detail: refine while tile radius / distance exceeds this (smaller = finer).
    public static func select(roots: [TileKey], camera: SIMD3<Double>,
                              available: Set<TileKey>,
                              tileCentre: (TileKey) -> (centre: SIMD3<Double>, radius: Double),
                              isLoaded: (TileKey) -> Bool,
                              wantsChildren: (TileKey) -> Void = { _ in },
                              detail: Double = 0.55,
                              isVisible: (SIMD3<Double>, Double) -> Bool = { _, _ in true },
                              hiddenDetailScale: Double = 1) -> [TileKey] {
        var out: [TileKey] = []
        func visit(_ k: TileKey) {
            let (c, r) = tileCentre(k)
            let distance = max(simd_distance(c, camera) - r, 1)
            let children = k.children
            // Out of view, refine less: enough to turn the camera without holes, at a fraction of
            // the memory.
            let threshold = isVisible(c, r) ? detail : detail * hiddenDetailScale
            let wantsFiner = r / distance > threshold && children.allSatisfy { available.contains($0) }
            if wantsFiner {
                if children.allSatisfy(isLoaded) {
                    children.forEach(visit)
                    return
                }
                wantsChildren(k)
            }
            out.append(k)
        }
        roots.filter(isLoaded).forEach(visit)
        return out
    }
}

/// Ground height lookups for physics and camera clamping, from the finest tile that has heights.
public struct HeightField: Sendable {
    public let samples: Int
    public private(set) var tiles: [TileKey: [Float]] = [:]
    public let maxZoom: Int

    public init(samples: Int, maxZoom: Int) {
        self.samples = samples
        self.maxZoom = maxZoom
    }

    public mutating func insert(_ key: TileKey, heights: [Float]) { tiles[key] = heights }
    public mutating func remove(_ key: TileKey) { tiles[key] = nil }

    /// Height above mean sea level (metres) at a point, or nil when no tile covers it.
    public func height(latitude: Double, longitude: Double) -> Double? {
        for z in stride(from: maxZoom, through: 0, by: -1) {
            let t = WebMercator.tileCoordinates(latitude: latitude, longitude: longitude, zoom: z)
            let key = TileKey(z: z, x: Int(t.x), y: Int(t.y))
            guard let h = tiles[key] else { continue }
            let fx = (t.x - Double(key.x)) * Double(samples - 1)
            let fy = (t.y - Double(key.y)) * Double(samples - 1)
            let i = min(Int(fx), samples - 2), j = min(Int(fy), samples - 2)
            let tx = Float(fx - Double(i)), ty = Float(fy - Double(j))
            let a = h[j * samples + i], b = h[j * samples + i + 1]
            let c = h[(j + 1) * samples + i], d = h[(j + 1) * samples + i + 1]
            return Double((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
        }
        return nil
    }
}
