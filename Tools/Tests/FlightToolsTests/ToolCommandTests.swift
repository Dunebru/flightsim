import Airports
import Foundation
import Testing
@testable import FlightToolsCore
import Terrain

@Test func unknownCommandPrintsUsage() async {
    let result = await runTool(["bogus"])
    #expect(result.code == 64)
    #expect(result.output.contains("terrain-bake"))
}

/// Regression: two options passed as one shell word were silently ignored, and the bake ran
/// without its caches.
@Test func unknownOptionsAreRejected() async {
    let r = await runTool(["terrain-bake", "--world", "2", "--name", "w", "--out", "/tmp/x",
                           "--terrarium-cache Data/raw/terrarium --imagery-cache Data/raw/imagery"])
    #expect(r.code == 64)
    #expect(r.output.contains("unknown option"))
}

@Test func unbuiltCommandsReportTheirMilestone() async {
    for command in ToolCommand.allCases where command.plannedFor != nil {
        let result = await runTool([command.rawValue])
        #expect(result.code == 69)
        #expect(result.output.contains("not implemented"))
    }
}

/// A synthetic north-up raster whose height is its projected x in kilometres: sampling must be
/// bilinear and oriented (west to east increases, rows run north to south).
struct DEMRasterTests {
    static func ramp() -> DEMRaster {
        // 400 x 400 pixels of 100 m covering the KPHX area in Web Mercator.
        let origin = WebMercator.project(latitude: 33.6, longitude: -112.3)
        let w = 400, h = 400
        var values = [Float]()
        for row in 0..<h {
            for col in 0..<w {
                let x = origin.x + (Double(col) + 0.5) * 100
                values.append(Float((x - origin.x) / 1000))
                _ = row
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return DEMRaster(width: w, height: h, geoTransform: [origin.x, 100, 0, origin.y, 0, -100], data: data)
    }

    @Test func bilinearSampleMatchesTheRamp() throws {
        let r = Self.ramp()
        let o = WebMercator.project(latitude: 33.6, longitude: -112.3)
        let v = try #require(r.sample(x: o.x + 12_345, y: o.y - 5_000))
        #expect(abs(Double(v) - 12.345) < 1e-3)
        #expect(r.sample(x: o.x - 10_000, y: o.y) == nil)
    }

    @Test func tileHeightsRunWestToEast() throws {
        let r = Self.ramp()
        let k = WebMercator.tile(latitude: 33.5, longitude: -112.2, zoom: 13)
        let h = try #require(r.heights(for: k))
        #expect(h.count == 65 * 65)
        #expect(h[64] > h[0])            // east edge higher than west on the first row
        #expect(abs(h[0] - h[64 * 65]) < 1e-3)   // same column, north vs south: equal on a x-ramp
    }

    @Test func heightsRoundTripThroughFloat16() throws {
        let values: [Float] = [338.44, -12.5, 4_205.0, 0]
        let back = try SceneryPack.decodeHeights(SceneryPack.encodeHeights(values), count: 4)
        for (a, b) in zip(values, back) { #expect(abs(a - b) <= max(0.25, abs(a) * 0.001)) }
    }

    /// The quadtree refines a tile only when all four children exist; the plan must never leave
    /// a sibling set partial.
    @Test func planKeepsSiblingSetsWhole() {
        let tiles = Set(BakePlan.airportRegion.tiles(latitude: 33.44085, longitude: -112.011))
        let minZoom = tiles.map(\.z).min()!
        for k in tiles {
            guard let p = k.parent, k.z == minZoom || tiles.contains(p) else { continue }
            #expect(p.children.allSatisfy(tiles.contains), "\(p) has a partial set of children")
        }
        #expect(BakePlan.world(maxZoom: 2).count == 1 + 4 + 16)
    }

    @Test func planPutsTheDetailNearTheCentre() {
        let tiles = BakePlan.airportRegion.tiles(latitude: 33.4342, longitude: -112.0116)
        let z14 = tiles.filter { $0.z == 14 }
        #expect(!z14.isEmpty)
        #expect(z14.contains(TileKey(z: 14, x: 3094, y: 6575)))
        #expect(tiles.filter { $0.z == 8 }.count >= 1)
        // Every zoom-14 tile centre is within the 12 km ring, plus at most one tile diagonal
        // (2 km x 1.42) where sibling sets are completed.
        for k in z14 {
            let c = WebMercator.coordinate(x: Double(k.x) + 0.5, y: Double(k.y) + 0.5, zoom: 14)
            #expect(BakePlan.distanceKm(33.4342, -112.0116, c.latitude, c.longitude) <= 12 + 2.9)
        }
    }
}

/// Approach corridors add sharp tiles out along each final, and every tile keeps its full chain
/// of ancestors (an orphan would be drawn over coarser terrain).
@Test func corridorsReachOutAndKeepTheirAncestors() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Data/Bundle/Airports/KPHX.json").standardized
    let layout = try AirportLayout.load(url)
    var plan = BakePlan.airportRegion
    let plain = Set(plan.tiles(latitude: 33.44085, longitude: -112.011))
    plan.corridors = BakePlan.approachCorridors(layout)
    let tiles = Set(plan.tiles(latitude: 33.44085, longitude: -112.011))
    // A zoom-17 tile 5 km out on the extended centreline of 08 exists only with corridors.
    let e08 = layout.runways.first { $0.name == "08/26" }!.ends[0].position
    let far = WebMercator.tile(latitude: e08.lat, longitude: e08.lon - 5.0 / (111.32 * cos(e08.lat * .pi / 180)), zoom: 17)
    #expect(tiles.contains(far))
    #expect(!plain.contains(far))
    let minZoom = tiles.map(\.z).min()!
    for k in tiles where k.z > minZoom { #expect(tiles.contains(k.parent!), "\(k) has no parent") }
}
