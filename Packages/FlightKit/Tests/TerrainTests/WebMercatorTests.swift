import Testing
@testable import Terrain

struct WebMercatorTests {
    /// KPHX at zoom 14 falls in tile 14/3094/6575 (computed independently in Python with the
    /// standard slippy-map formula).
    @Test func kphxTile() {
        let k = WebMercator.tile(latitude: 33.4342, longitude: -112.0116, zoom: 14)
        #expect(k == TileKey(z: 14, x: 3094, y: 6575))
        let b = WebMercator.bounds(k)
        #expect(b.south <= 33.4342 && 33.4342 <= b.north && b.west <= -112.0116 && -112.0116 <= b.east)
    }

    @Test(arguments: [(33.4342, -112.0116), (-33.9461, 151.1772), (51.47, -0.4543), (0.0, 0.0), (84.9, 179.9)])
    func roundTrip(lat: Double, lon: Double) {
        for z in [0, 8, 14, 18] {
            let t = WebMercator.tileCoordinates(latitude: lat, longitude: lon, zoom: z)
            let back = WebMercator.coordinate(x: t.x, y: t.y, zoom: z)
            #expect(abs(back.latitude - lat) < 1e-9 && abs(back.longitude - lon) < 1e-9)
        }
    }

    @Test func childrenTileTheParent() {
        let p = TileKey(z: 10, x: 193, y: 408)
        for c in p.children {
            #expect(c.parent == p)
            let pb = WebMercator.bounds(p), cb = WebMercator.bounds(c)
            #expect(cb.south >= pb.south - 1e-12 && cb.north <= pb.north + 1e-12)
            #expect(cb.west >= pb.west - 1e-12 && cb.east <= pb.east + 1e-12)
        }
    }

    @Test func projectionMatchesTileGrid() {
        // The north-west corner of tile 14/3094/6575, projected two ways.
        let corner = WebMercator.coordinate(x: 3094, y: 6575, zoom: 14)
        let a = WebMercator.project(latitude: corner.latitude, longitude: corner.longitude)
        let b = WebMercator.projected(x: 3094, y: 6575, zoom: 14)
        #expect(abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3)
    }

    @Test func pathRoundTrips() {
        #expect(TileKey(path: "14/3094/6575") == TileKey(z: 14, x: 3094, y: 6575))
        #expect(TileKey(path: "bad") == nil)
    }
}
