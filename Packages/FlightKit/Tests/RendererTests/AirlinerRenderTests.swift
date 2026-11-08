import Aircraft
import Airports
import Foundation
import Metal
import Testing
import simd
@testable import Renderer

/// The FlightGear A320 as the player's aircraft, rendered for review.
@Suite(.serialized)
struct AirlinerRenderTests {
    static let a320 = RendererTests.repoRoot.appendingPathComponent("Data/Bundle/Aircraft/A320")

    @Test func a320Views() throws {
        let model = try A320Model.load(from: Self.a320)
        print("A320 \(model.triangleCount) triangles, \(model.groups.count) groups, bounds \(model.boundsMin) \(model.boundsMax)")
        let site = try AirportSite.load(AirportRenderTests.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try AirportRenderTests.scene(site, aircraft: false)
        try r.setAircraft(model, textures: Self.a320, textureMap: A320Model.liveries[0].textures, hiddenParts: ["hidden"])
        let rw08 = site.layout.runways.first { $0.name == "08/26" }!
        let f = site.runwayFrame(rw08)
        let threshold = f.point(rw08.ends[0].displacedThreshold + 60, 0)
        var s = base
        s.showAircraft = true
        s.aircraftPosition = site.onSurface(threshold)
        s.aircraftHeading = f.heading * .pi / 180
        var views: [(String, CameraPose)] = []
        // Chase from behind and left, a front three-quarter, and close on the nose gear.
        let behind = threshold - f.axis * 55 + f.left * 18
        views.append(("a320-chase", CameraPose(position: site.onSurface(behind) + SIMD3(0, 0, 9),
                                              forward: simd_normalize(SIMD3(f.axis.x * 55 - f.left.x * 18, f.axis.y * 55 - f.left.y * 18, -6)),
                                              up: SIMD3(0, 0, 1), fovY: 50 * .pi / 180)))
        let front = threshold + f.axis * 40 + f.left * 25
        views.append(("a320-front", CameraPose(position: site.onSurface(front) + SIMD3(0, 0, 4),
                                              forward: simd_normalize(SIMD3(-f.axis.x * 40 - f.left.x * 25, -f.axis.y * 40 - f.left.y * 25, -1)),
                                              up: SIMD3(0, 0, 1), fovY: 45 * .pi / 180)))
        for (name, pose) in views {
            s.cameraPose = pose
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            let img = try r.renderImage(s, width: 1600, height: 900)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
    }
}
