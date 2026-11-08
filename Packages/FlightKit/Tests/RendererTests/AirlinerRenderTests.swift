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

    /// The C172 outside and from the pilot's seat, after hiding FlightGear's helper objects.
    @Test func c172Views() throws {
        let aircraft = try C172Model.loadAircraft(directory: RendererTests.c172Dir)
        let site = try AirportSite.load(AirportRenderTests.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try AirportRenderTests.scene(site, aircraft: false)
        try r.setAircraft(aircraft.model, textures: RendererTests.c172Dir, hiddenParts: ["hidden"],
                          animation: aircraft, cullsBackFaces: true)
        let rw08 = site.layout.runways.first { $0.name == "08/26" }!
        let f = site.runwayFrame(rw08)
        let at = f.point(rw08.ends[0].displacedThreshold + 60, 0)
        var s = base
        s.showAircraft = true
        // Readings with every needle off its stop: 105 kt, 4,500 ft, climbing 500 fpm in a
        // standard-rate right turn at 2,300 rpm, heading 080, yoke turned right.
        typealias P = C172Model.Property
        s.instrumentValues = [P.airspeed: 105, P.altitude: 4_500, P.verticalSpeed: 500, P.turnRate: 1, P.roll: 20, P.pitch: 5,
                              P.heading: 80, P.headingBug: 120, P.rpm: 2_300, P.yokeAileron: 0.5, P.clock: 37_800,
                              P.flaps: 1, P.throttle: 0.8]
        s.instrumentValues.merge(C172Model.surfaceReadings(leftAileron: 1, rightAileron: -1, elevator: -1, rudder: 1)) { a, _ in a }
        s.aircraftPosition = site.onSurface(at)
        s.aircraftHeading = f.heading * .pi / 180
        let h = s.aircraftHeading
        let fwd = SIMD3(sin(h), cos(h), 0.0), left = SIMD3(-cos(h), sin(h), 0.0)
        let eye = SIMD3(1.62, 0.21, 1.6)
        let views: [(String, CameraPose)] = [
            ("c172-outside", CameraPose(position: s.aircraftPosition + fwd * 7 + left * 6 + SIMD3(0, 0, 2.2),
                                        forward: simd_normalize(-fwd * 7 - left * 6 - SIMD3(0, 0, 1.2)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)),
            ("c172-cockpit", CameraPose(position: s.aircraftPosition + fwd * eye.x + left * eye.y + SIMD3(0, 0, eye.z),
                                        forward: simd_normalize(fwd - SIMD3(0, 0, 0.18)), up: SIMD3(0, 0, 1), fovY: 70 * .pi / 180)),
            ("c172-cockpit-down", CameraPose(position: s.aircraftPosition + fwd * eye.x + left * eye.y + SIMD3(0, 0, eye.z),
                                             forward: simd_normalize(fwd * 0.4 - SIMD3(0, 0, 1)), up: SIMD3(0, 0, 1), fovY: 70 * .pi / 180)),
            // From behind: right roll, nose-up elevator, right rudder, full flap. The left
            // aileron should be down, the right up, the elevator trailing edge up.
            ("c172-tail", CameraPose(position: s.aircraftPosition - fwd * 6 + SIMD3(0, 0, 1.6),
                                     forward: simd_normalize(fwd * 6 - SIMD3(0, 0, 0.4)), up: SIMD3(0, 0, 1), fovY: 75 * .pi / 180)),
            // The airspeed indicator from 30 cm.
            ("c172-asi", CameraPose(position: s.aircraftPosition + fwd * (eye.x + 0.5) + left * (eye.y + 0.025) + SIMD3(0, 0, eye.z - 0.15),
                                    forward: simd_normalize(fwd * 0.3 + left * 0.015 - SIMD3(0, 0, 0.09)), up: SIMD3(0, 0, 1), fovY: 40 * .pi / 180)),
        ]
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
