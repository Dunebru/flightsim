import SimCore
import Testing
import simd
@testable import Terrain

struct TerrainGeometryTests {
    static let frame = LocalFrame(origin: Geodetic(latitude: 33.4342, longitude: -112.0116, height: 345))
    static let n = 65

    static func flat(_ h: Float) -> [Float] { [Float](repeating: h, count: n * n) }

    @Test func flatGroundHasUpwardNormals() {
        let k = WebMercator.tile(latitude: 33.4342, longitude: -112.0116, zoom: 14)
        let g = TerrainTileGeometry.build(key: k, heights: Self.flat(345), samples: Self.n, frame: Self.frame)
        for normal in g.normals.prefix(Self.n * Self.n) {
            #expect(normal.z > 0.999)
        }
        // Grid plus four skirts of n vertices.
        #expect(g.positions.count == Self.n * Self.n + 4 * Self.n)
    }

    /// Neighbouring tiles at the same zoom share their edge exactly: no cracks.
    @Test func neighboursShareTheirEdge() {
        let k = WebMercator.tile(latitude: 33.4342, longitude: -112.0116, zoom: 14)
        let east = TileKey(z: k.z, x: k.x + 1, y: k.y)
        var heights = [Float]()
        for j in 0..<Self.n { for i in 0..<Self.n { heights.append(Float(340 + i + j)) } }
        // A height field continuous across the boundary: the east tile's west column equals
        // this tile's east column.
        var eastHeights = [Float]()
        for j in 0..<Self.n { for i in 0..<Self.n { eastHeights.append(Float(340 + (Self.n - 1) + i + j)) } }
        let a = TerrainTileGeometry.build(key: k, heights: heights, samples: Self.n, frame: Self.frame)
        let b = TerrainTileGeometry.build(key: east, heights: eastHeights, samples: Self.n, frame: Self.frame)
        for j in 0..<Self.n {
            let pa = SIMD3<Double>(a.positions[j * Self.n + Self.n - 1]) + a.centre
            let pb = SIMD3<Double>(b.positions[j * Self.n]) + b.centre
            #expect(simd_distance(pa, pb) < 0.01, "row \(j): \(pa) vs \(pb)")
        }
    }

    @Test func runwayAreaIsFlattened() {
        let k = WebMercator.tile(latitude: 33.4342, longitude: -112.0116, zoom: 14)
        var heights = [Float]()
        for j in 0..<Self.n { for i in 0..<Self.n { heights.append(Float(330 + (i % 7) + (j % 5))) } }
        let area = FlattenArea(centre: .zero, halfLength: 400, halfWidth: 100, angle: 0, height: 0)
        let g = TerrainTileGeometry.build(key: k, heights: heights, samples: Self.n, frame: Self.frame, flatten: [.area(area)])
        var inside = 0
        for idx in 0..<(Self.n * Self.n) {
            let p = SIMD3<Double>(g.positions[idx]) + g.centre
            if abs(p.x) < 380 && abs(p.y) < 80 {
                inside += 1
                #expect(abs(p.z) < 0.01)
            }
        }
        #expect(inside > 0)
    }

    @Test func selectorRefinesNearTheCameraWithoutOverlap() {
        let root = TileKey(z: 10, x: 193, y: 410)
        var available = Set<TileKey>([root])
        var frontier = [root]
        for _ in 0..<3 {
            frontier = frontier.flatMap(\.children)
            available.formUnion(frontier)
        }
        func centre(_ k: TileKey) -> (centre: SIMD3<Double>, radius: Double) {
            let c = WebMercator.coordinate(x: Double(k.x) + 0.5, y: Double(k.y) + 0.5, zoom: k.z)
            let size = 40_075_000 * cos(33.4 * .pi / 180) / Double(1 << k.z)
            return (Self.frame.enu(Geodetic(latitude: c.latitude, longitude: c.longitude, height: 345)), size * 0.71)
        }
        // Camera low over the south-west corner of the root tile.
        let corner = WebMercator.coordinate(x: 193.05, y: 410.95, zoom: 10)
        let cam = Self.frame.enu(Geodetic(latitude: corner.latitude, longitude: corner.longitude, height: 800))
        let selected = TileSelector.select(roots: [root], camera: cam, available: available,
                                           tileCentre: centre, isLoaded: { _ in true })
        #expect(selected.contains { $0.z == 13 })          // fine detail near the camera
        #expect(selected.contains { $0.z <= 12 })          // coarser far away
        // Detail falls off with distance: the finest selected tile is nearer than the coarsest.
        let finest = selected.filter { $0.z == 13 }.map { simd_distance(centre($0).centre, cam) }.min()!
        let coarsest = selected.filter { $0.z <= 12 }.map { simd_distance(centre($0).centre, cam) }.max()!
        #expect(finest < coarsest)
        // No selected tile is an ancestor of another.
        for a in selected {
            var p = a.parent
            while let q = p { #expect(!selected.contains(q)); p = q.parent }
        }
    }

    /// Out of view the quadtree refines less; the same tiles in view refine fully.
    @Test func selectorRefinesLessOutOfView() {
        let root = TileKey(z: 10, x: 193, y: 410)
        var available = Set<TileKey>([root])
        var frontier = [root]
        for _ in 0..<3 { frontier = frontier.flatMap(\.children); available.formUnion(frontier) }
        func centre(_ k: TileKey) -> (centre: SIMD3<Double>, radius: Double) {
            let c = WebMercator.coordinate(x: Double(k.x) + 0.5, y: Double(k.y) + 0.5, zoom: k.z)
            let size = 40_075_000 * cos(33.4 * .pi / 180) / Double(1 << k.z)
            return (Self.frame.enu(Geodetic(latitude: c.latitude, longitude: c.longitude, height: 345)), size * 0.71)
        }
        let corner = WebMercator.coordinate(x: 193.05, y: 410.95, zoom: 10)
        let cam = Self.frame.enu(Geodetic(latitude: corner.latitude, longitude: corner.longitude, height: 800))
        let seen = TileSelector.select(roots: [root], camera: cam, available: available, tileCentre: centre,
                                       isLoaded: { _ in true }, hiddenDetailScale: 3)
        let unseen = TileSelector.select(roots: [root], camera: cam, available: available, tileCentre: centre,
                                         isLoaded: { _ in true }, isVisible: { _, _ in false }, hiddenDetailScale: 3)
        #expect(unseen.count < seen.count / 2, "out of view \(unseen.count) tiles vs in view \(seen.count)")
        #expect(seen.contains { $0.z == 13 })
    }

    @Test func selectorDrawsTheParentUntilAllChildrenLoad() {
        let root = TileKey(z: 10, x: 193, y: 410)
        let available = Set([root] + root.children)
        let loaded = Set([root] + Array(root.children.prefix(3)))
        var wanted: [TileKey] = []
        let selected = TileSelector.select(roots: [root], camera: .zero, available: available,
                                           tileCentre: { _ in (.zero, 10_000) }, isLoaded: loaded.contains,
                                           wantsChildren: { wanted.append($0) })
        #expect(selected == [root])
        #expect(wanted == [root])
    }

    /// Vertices at sea level (where ocean depths were clamped at bake time) are flagged as
    /// water, land is not, and skirts copy their edge's flag.
    @Test func seaLevelIsWater() {
        let k = WebMercator.tile(latitude: 33.94, longitude: -118.45, zoom: 14)
        var heights = [Float]()
        for _ in 0..<Self.n { for i in 0..<Self.n { heights.append(i < Self.n / 2 ? 0 : 12) } }
        let g = TerrainTileGeometry.build(key: k, heights: heights, samples: Self.n, frame: Self.frame)
        #expect(g.water.count == g.positions.count)
        #expect(g.water[0] && !g.water[Self.n - 1])
        #expect(g.water[Self.n * Self.n] == g.water[0])     // first skirt vertex copies the north-west corner
    }

    @Test func heightFieldInterpolates() {
        let k = WebMercator.tile(latitude: 33.4342, longitude: -112.0116, zoom: 14)
        var heights = [Float]()
        for j in 0..<Self.n { for i in 0..<Self.n { heights.append(Float(i)) } }
        var field = HeightField(samples: Self.n, maxZoom: 14)
        field.insert(k, heights: heights)
        let b = WebMercator.bounds(k)
        let mid = WebMercator.coordinate(x: Double(k.x) + 0.5, y: Double(k.y) + 0.5, zoom: 14)
        #expect(abs((field.height(latitude: mid.latitude, longitude: mid.longitude) ?? -1) - 32) < 1e-3)
        #expect(field.height(latitude: b.north + 1, longitude: b.west) == nil)
    }
}

struct TreeDetectorTests {
    /// A dark green blob on brown ground becomes trees at the blob, a light green lawn does not.
    @Test func findsCanopyNotLawn() {
        let size = 256
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                var c: (UInt8, UInt8, UInt8) = (150, 130, 105)                      // desert
                if (x - 64) * (x - 64) + (y - 64) * (y - 64) < 100 { c = (45, 70, 40) }   // canopy, 10 px radius
                if x > 160 && y > 160 { c = (110, 160, 90) }                          // lawn
                px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
            }
        }
        let trees = TreeDetector.detect(pixels: px, size: size, metresPerPixel: 0.5) { u, v in
            SIMD3(Float(u * 128), Float(v * 128), 0)
        }
        #expect(!trees.isEmpty)
        // All trees sit on the blob (centre 32 m, 32 m; radius 5 m), none on the lawn.
        for t in trees {
            let d = ((t.position.x - 32) * (t.position.x - 32) + (t.position.y - 32) * (t.position.y - 32)).squareRoot()
            #expect(d < 6, "tree at \(t.position)")
        }
    }
}
