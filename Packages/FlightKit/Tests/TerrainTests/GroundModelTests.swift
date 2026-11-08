import Foundation
import SimCore
import Testing
@testable import Terrain

/// The solid ground from the baked KPHX pack: the runway held at its published elevations, real
/// heights elsewhere, and the scene origin's height outside the pack.
struct GroundModelTests {
    static let packURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Scenery/kphx").standardized
    // KPHX 8/26 midpoint and published end elevations (OurAirports): 1,113 ft and 1,135 ft.
    static let origin = Geodetic(latitude: 33.44085076, longitude: -112.01099777, height: 342.60)
    static let runway = FlattenArea(centre: .zero, halfLength: 1_851, halfWidth: 75,
                                    angle: (90 - 90.168) * .pi / 180, height: 0, gradient: 0.0019)

    @Test func runwayFollowsItsPublishedElevations() throws {
        var g = GroundModel(scenery: SceneryLibrary(try SceneryPack(root: Self.packURL)), frame: LocalFrame(origin: Self.origin), flatten: [.area(Self.runway)])
        let frame = LocalFrame(origin: Self.origin)
        func height(at s: Double) -> Double {
            let a = Self.runway.angle
            let p = frame.geodetic(SIMD3(s * cos(a), s * sin(a), 0))
            return g.height(latitude: p.latitude, longitude: p.longitude)
        }
        #expect(abs(height(at: 0) - 342.60) < 0.05)
        #expect(abs(height(at: -1_751) - 1_113 * 0.3048) < 0.3)   // runway 08 end
        #expect(abs(height(at: 1_751) - 1_135 * 0.3048) < 0.3)    // runway 26 end
    }

    /// South Mountain's summit area (Mount Suppoa, about 2,690 ft) stands well above the valley.
    @Test func realHeightsAwayFromTheRunway() throws {
        var g = GroundModel(scenery: SceneryLibrary(try SceneryPack(root: Self.packURL)), frame: LocalFrame(origin: Self.origin), flatten: [.area(Self.runway)])
        let summit = g.height(latitude: 33.3337, longitude: -112.0610)
        #expect(summit > 700 && summit < 840, "South Mountain summit: \(summit) m")
        let valley = g.height(latitude: 33.4500, longitude: -112.0700)
        #expect(valley > 300 && valley < 360, "downtown Phoenix: \(valley) m")
        #expect(g.height(latitude: 40, longitude: -100) == Self.origin.height)   // outside the pack
    }
}

/// Every level of each region's heights agrees with the field elevation at the airport. Caught
/// a bake bug that left KLAX's zoom 16-18 heights at 0 m (sampling the wrong place).
struct PackHeightsTests {
    @Test(arguments: [("kphx", 33.4343, -112.0116, 340.0), ("klax", 33.9425, -118.4081, 38.0)])
    func everyLevelMatchesTheField(pack: String, lat: Double, lon: Double, field: Double) throws {
        let root = GroundModelTests.packURL.deletingLastPathComponent().appendingPathComponent(pack)
        let p = try SceneryPack(root: root)
        // Tiles of 4 km and less (zoom 13 up), where the mean should sit near the field.
        for z in max(p.index.minZoom, 13)...p.index.maxZoom {
            let t = WebMercator.tile(latitude: lat, longitude: lon, zoom: z)
            guard p.available.contains(t) else { continue }
            let h = try p.heights(t)
            let mean = Double(h.reduce(0, +)) / Double(h.count)
            #expect(abs(mean - field) < 20, "\(pack) zoom \(z): mean height \(mean) m, field \(field) m")
        }
    }
}
