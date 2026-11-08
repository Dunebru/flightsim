import Aircraft
import Airports
import Foundation
import ImageIO
import CoreGraphics
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

    /// The A320 spawned at a KPHX gate exactly as the flight places it: nose wheel on the
    /// stand's stop point, facing along the lead-in line, wheels on the apron, its windows
    /// tinted. Views from the front quarter, at wheel height and of the bridge.
    @Test func a320AtGate() throws {
        let site = try AirportSite.load(AirportRenderTests.airportsURL.appendingPathComponent("KPHX.json"))
        let slot = try #require(site.airlinerStands.first { $0.ref != nil && $0.occupied && $0.ref!.hasPrefix("D") }
                                ?? site.airlinerStands.first { $0.ref != nil && $0.occupied })
        let ref = slot.ref!
        let (r, base) = try AirportRenderTests.scene(site, aircraft: false, excludeStand: ref)
        let m = try A320Model.loadAnimated(from: Self.a320)
        let nose = try #require(m.centre(ofObject: "NLGWheels"))
        try r.setAircraft(m.model, textures: Self.a320, textureMap: A320Model.liveries[0].textures, hiddenParts: ["hidden"],
                          animation: m, cullsBackFaces: true, noseWheel: (nose, Float((672 - 196.1) * 0.0254)))
        let placement = try #require(site.placement(.stand(ref)))
        let h = placement.heading * .pi / 180
        let fwd = SIMD3(sin(h), cos(h), 0.0), left = SIMD3(-cos(h), sin(h), 0.0)
        let cg = placement.position - fwd * (672 - 196.1) * 0.0254
        var s = base
        s.showAircraft = true
        s.aircraftPosition = site.onSurface(SIMD2(cg.x, cg.y))
        s.aircraftHeading = h
        s.aircraftPivotHeight = (-40 - -142) * 0.0254
        s.instrumentValues = A320Model.readings(leftAileron: 0, rightAileron: 0, elevator: 0, rudder: 0, flaps: 0, speedbrake: 0,
                                                steering: 0, gear: 1, compression: .zero, wheelSpeed: .zero, n1: 20, reverser: 0)
        print("gate \(ref): stop point \(placement.position), heading \(placement.heading)")
        // The screens, from the pages the display test draws (when it has run).
        let renders = RendererTests.repoRoot.appendingPathComponent("artifacts/renders")
        for (screen, page) in [("pfd1", "pfd"), ("pfd2", "pfd"), ("nd1", "nd"), ("nd2", "nd"), ("ewd", "ewd"), ("sd", "sd")] {
            guard let src = CGImageSourceCreateWithURL(renders.appendingPathComponent("display-\(page).png") as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let n = img.width
            var px = [UInt8](repeating: 0, count: n * n * 4)
            px.withUnsafeMutableBytes { b in
                let ctx = CGContext(data: b.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            }
            s.displays[screen] = DisplayImage(pixels: px, size: n, version: 1)
        }
        let p = s.aircraftPosition
        let views: [(String, CameraPose)] = [
            ("a320-gate", CameraPose(position: p + left * 38 - fwd * 22 + SIMD3(0, 0, 14),
                                     forward: simd_normalize(-left * 38 + fwd * 30 - SIMD3(0, 0, 12)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)),
            ("a320-gate-wheels", CameraPose(position: p - left * 9 + fwd * 1 + SIMD3(0, 0, 0.6),
                                            forward: simd_normalize(left * 9 - fwd * 1 - SIMD3(0, 0, 0.3)), up: SIMD3(0, 0, 1), fovY: 40 * .pi / 180)),
            ("a320-flightdeck", CameraPose(position: p + fwd * 14.7 + left * 0.53 + SIMD3(0, 0, 5.0),
                                           forward: simd_normalize(fwd - SIMD3(0, 0, 0.2)), up: SIMD3(0, 0, 1), fovY: 68 * .pi / 180)),
            ("a320-gate-nose", CameraPose(position: p + left * 14 + fwd * 6 + SIMD3(0, 0, 4),
                                          forward: simd_normalize(-left * 14 + fwd * 8 - SIMD3(0, 0, 0.5)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)),
        ]
        for (name, pose) in views {
            s.cameraPose = pose
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            let img = try r.renderImage(s, width: 1600, height: 900)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
        // The nearest parked neighbour from its right side: its ground equipment.
        if let other = site.airlinerStands.filter({ $0.occupied && $0.ref != ref })
            .min(by: { simd_distance($0.position, slot.position) < simd_distance($1.position, slot.position) }) {
            let f2 = SIMD3(sin(other.heading), cos(other.heading), 0.0), l2 = SIMD3(-cos(other.heading), sin(other.heading), 0.0)
            let o = site.onSurface(other.position)
            let eye = o - f2 * 42 - l2 * 22 + SIMD3(0, 0, 14), look = o - f2 * 10 - l2 * 6 + SIMD3(0, 0, 1)
            s.cameraPose = CameraPose(position: eye, forward: simd_normalize(look - eye), up: SIMD3(0, 0, 1), fovY: 45 * .pi / 180)
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            try RendererTests.savePNG(try r.renderImage(s, width: 1600, height: 900), 1600, 900, name: "gate-equipment")
        }
        // In the air with the gear halfway and the flaps out: doors open, gear folding.
        s.aircraftPosition = p + SIMD3(0, 0, 30)
        s.instrumentValues = A320Model.readings(leftAileron: 0, rightAileron: 0, elevator: 0, rudder: 0, flaps: 0.5, speedbrake: 0,
                                                steering: 0, gear: 0.5, compression: .zero, wheelSpeed: .zero, n1: 60, reverser: 0)
        s.cameraPose = CameraPose(position: p + SIMD3(0, 0, 26) - left * 30 - fwd * 4, forward: simd_normalize(left * 30 + SIMD3(0, 0, 3)),
                                  up: SIMD3(0, 0, 1), fovY: 45 * .pi / 180)
        r.exposureAdaptation = 1
        try TerrainRenderTests.settle(r, s, limit: .seconds(60))
        r.resetHistory()
        try RendererTests.savePNG(try r.renderImage(s, width: 1600, height: 900), 1600, 900, name: "a320-gear-transit")
    }

    /// What the pilot sees from the chase camera (60 m behind, as the app), the gear at five
    /// stages of retraction from below, and the apron surface close up.
    @Test func a320Review() throws {
        let site = try AirportSite.load(AirportRenderTests.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try AirportRenderTests.scene(site, aircraft: false)
        let m = try A320Model.loadAnimated(from: Self.a320)
        let nose = try #require(m.centre(ofObject: "NLGWheels"))
        try r.setAircraft(m.model, textures: Self.a320, textureMap: A320Model.liveries[0].textures, hiddenParts: ["hidden"],
                          animation: m, cullsBackFaces: true, noseWheel: (nose, Float((672 - 196.1) * 0.0254)))
        let rw08 = site.layout.runways.first { $0.name == "08/26" }!
        let f = site.runwayFrame(rw08)
        let at = f.point(rw08.ends[0].displacedThreshold + 400, 0)
        let h = f.heading * .pi / 180
        let fwd = SIMD3(sin(h), cos(h), 0.0), left = SIMD3(-cos(h), sin(h), 0.0)
        var s = base
        s.showAircraft = true
        s.aircraftHeading = h
        s.aircraftPivotHeight = (-40 - -142) * 0.0254
        func readings(gear: Double, n1: Double = 25) -> [String: Double] {
            A320Model.readings(leftAileron: 0, rightAileron: 0, elevator: 0, rudder: 0, flaps: 0, speedbrake: 0, steering: 0,
                               gear: gear, compression: gear > 0.99 ? SIMD3(repeating: 0.4) : .zero, wheelSpeed: .zero, n1: n1, reverser: 0)
        }
        func shot(_ name: String, _ eye: SIMD3<Double>, _ look: SIMD3<Double>, fov: Double = 50) throws {
            s.cameraPose = CameraPose(position: eye, forward: simd_normalize(look - eye), up: SIMD3(0, 0, 1), fovY: fov * .pi / 180)
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            try RendererTests.savePNG(try r.renderImage(s, width: 1600, height: 900), 1600, 900, name: name)
        }
        let ground = site.onSurface(at)
        s.aircraftPosition = ground
        s.instrumentValues = readings(gear: 1)
        let p = ground + SIMD3(0, 0, 3)
        try shot("review-chase", p - fwd * 58 + SIMD3(0, 0, 13), p + fwd * 6, fov: 55)
        try shot("review-side", p + left * 40 + fwd * 4 + SIMD3(0, 0, 2), p + fwd * 2, fov: 50)
        try shot("review-front", p + fwd * 38 - left * 14 + SIMD3(0, 0, 1.5), p + fwd * 6, fov: 50)
        try shot("review-apron", ground + fwd * 30 + left * 20 + SIMD3(0, 0, 1.7), ground + fwd * 45 + left * 10, fov: 60)
        // In the air, from below and to the side, the gear at five stages.
        s.aircraftPosition = ground + SIMD3(0, 0, 60)
        for g in [1.0, 0.75, 0.5, 0.25, 0.0] {
            s.instrumentValues = readings(gear: g, n1: 80)
            s.aircraftGearDown = g > 0.97
            let q = s.aircraftPosition + SIMD3(0, 0, 2)
            try shot(String(format: "review-gear-%03d", Int(g * 100)), q + left * 22 - fwd * 6 - SIMD3(0, 0, 9), q + fwd * 3, fov: 45)
        }
    }

    /// The C172 outside and from the pilot's seat, after hiding FlightGear's helper objects.
    @Test func c172Views() throws {
        let aircraft = try C172Model.loadAircraft(directory: RendererTests.c172Dir)
        let site = try AirportSite.load(AirportRenderTests.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try AirportRenderTests.scene(site, aircraft: false)
        try r.setAircraft(aircraft.model, textures: RendererTests.c172Dir, hiddenParts: ["hidden"],
                          animation: aircraft, cullsBackFaces: true,
                          noseWheel: (try #require(aircraft.centre(ofObject: "NoseWheel")), Float((41 - -6.8) * 0.0254)))
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
        let eye = SIMD3(-0.26, 0.21, 1.6)
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
