import Foundation
import Testing
import simd
@testable import Aircraft

/// The flyable A320 carries FlightGear's animations, and they move the way the flight means.
/// AC3D frame: x aft, y up, z left (FlightGear's A320 has its nose toward -x).
struct A320AnimationTests {
    static let directory = A320ModelTests.directory

    static func readings(roll: Double = 0, pitch: Double = 0, yaw: Double = 0, gear: Double = 1, compression: Double = 0,
                         wheels: Double = 0, n1: Double = 20) -> [String: Double] {
        // JSBSim's A320: right roll makes the left aileron positive and the right negative,
        // nose up makes the elevator negative, right yaw makes the rudder positive.
        A320Model.readings(leftAileron: 15 * roll, rightAileron: -15 * roll, elevator: -15 * pitch, rudder: 15 * yaw, flaps: 0,
                           speedbrake: 0, steering: 0, gear: gear, compression: SIMD3(repeating: compression),
                           wheelSpeed: SIMD3(repeating: wheels), n1: n1, reverser: 0)
    }

    func centroidShift(_ m: AnimatedModel, _ suffix: String, _ values: [String: Double], trailingEdge: Bool = false) -> SIMD3<Float> {
        let groups = m.model.groups.filter { $0.part.hasPrefix("anim:") && ($0.part.hasSuffix("|" + suffix) || $0.part.hasSuffix("/" + suffix)) }
        var before = SIMD3<Float>.zero, after = SIMD3<Float>.zero, n: Float = 0
        for g in groups {
            guard let t = m.transform(part: g.part, values: values) else { continue }
            let maxX = g.positions.map(\.x).max() ?? 0
            for p in g.positions where !trailingEdge || p.x > maxX - 0.05 {
                before += p
                let q = t * SIMD4(p, 1)
                after += SIMD3(q.x, q.y, q.z)
                n += 1
            }
        }
        return n > 0 ? (after - before) / n : SIMD3(repeating: .nan)
    }

    @Test func loadsWithAnimations() throws {
        let m = try A320Model.loadAnimated(from: Self.directory)
        let parts = Set(m.model.groups.map(\.part))
        print("A320: \(m.model.triangleCount) triangles, \(parts.filter { $0.hasPrefix("anim:") }.count) animated parts, spin: \(m.spinProperties.sorted())")
        for object in ["NLGWheels", "MLGWheelsL", "AileronL", "Rudder", "ElevatorL", "FlapL1", "SlatL1", "SpoilerL1", "FanLCFM56L", "ReverserLDoor1"] {
            #expect(parts.contains { $0.hasSuffix("|" + object) || $0.hasSuffix("/" + object) }, "missing \(object)")
        }
        #expect(m.spinProperties.contains("engines/engine[3]/n1"))
        #expect(m.spinProperties.contains("gear/gear[1]/rollspeed-ms"))
    }

    @Test func controlSurfacesMoveTheRightWay() throws {
        let m = try A320Model.loadAnimated(from: Self.directory)
        let left = centroidShift(m, "AileronL", Self.readings(roll: 1), trailingEdge: true).y
        let right = centroidShift(m, "AileronR", Self.readings(roll: 1), trailingEdge: true).y
        let elevator = centroidShift(m, "ElevatorL", Self.readings(pitch: 1), trailingEdge: true).y
        let rudder = centroidShift(m, "Rudder", Self.readings(yaw: 1), trailingEdge: true).z
        print("right roll: left aileron \(left), right \(right); nose up: elevator \(elevator); right yaw: rudder \(rudder) (z left)")
        #expect(left < -0.05, "left aileron should go down for a right roll")
        #expect(right > 0.05, "right aileron should go up for a right roll")
        #expect(elevator > 0.05, "elevator trailing edge should rise for nose up")
        #expect(rudder < -0.05, "rudder trailing edge should swing right for right yaw")
    }

    @Test func gearRetractsUpAndStrutsCompressUp() throws {
        let m = try A320Model.loadAnimated(from: Self.directory)
        let retract = centroidShift(m, "MLGWheelsL", Self.readings(gear: 0))
        let nose = centroidShift(m, "NLGWheels", Self.readings(gear: 0))
        let squeeze = centroidShift(m, "MLGWheelsL", Self.readings(compression: 1))
        print("gear up: main wheels \(retract), nose wheels \(nose); 1 ft compression: \(squeeze)")
        #expect(retract.y > 1, "main wheels should rise into the bay")
        #expect(abs(retract.z) > 0.5, "main gear folds sideways toward the centre")
        #expect(nose.y > 0.8, "nose wheels should rise into the bay")
        #expect(abs(squeeze.y - 0.3048) < 0.05, "a foot of compression lifts the wheels a foot")
    }

    @Test func fansAndWheelsSpinAndFanBlurSwaps() throws {
        let m = try A320Model.loadAnimated(from: Self.directory)
        var v = Self.readings(n1: 20)
        v["spin:engines/engine[3]/n1"] = 0.013        // 0.65 fan turns at factor 50
        let fan = m.model.groups.first { $0.part.hasSuffix("|FanLCFM56L") }
        let still = fan.flatMap { m.transform(part: $0.part, values: Self.readings(n1: 20)) }
        let turned = fan.flatMap { m.transform(part: $0.part, values: v) }
        #expect(still != nil && turned != nil && still != turned, "fan should turn")
        #expect(m.isVisible(part: fan!.part, values: Self.readings(n1: 20)))
        #expect(!m.isVisible(part: fan!.part, values: Self.readings(n1: 85)), "bladed fan hidden at high N1")
        let blur = m.model.groups.first { $0.part.hasSuffix("|FanSpinningCFM56L") }!
        #expect(m.isVisible(part: blur.part, values: Self.readings(n1: 85)))
        #expect(!m.isVisible(part: blur.part, values: Self.readings(n1: 20)))
    }
}

/// How far the drawn nose wheels sit ahead of the model's bounds centre (where the renderer
/// put the body origin before aligning to the flight model): the camera offsets move by the
/// difference.
struct NoseWheelPlacementProbe {
    @Test func drawnNoseWheels() throws {
        let a = try A320Model.loadAnimated(from: A320ModelTests.directory)
        let c = try C172Model.loadAircraft(directory: C172CockpitTests.directory)
        for (name, m, object) in [("A320", a, "NLGWheels"), ("C172", c, "NoseWheel")] {
            let cx = (m.model.boundsMin.x + m.model.boundsMax.x) / 2
            let nose = try #require(m.centre(ofObject: object))
            print("\(name): nose wheel \(cx - nose.x) m ahead of the bounds centre, lowest point y \(m.model.boundsMin.y), nose wheel bottom ~ \(nose.y)")
        }
    }
}

/// The flight deck loads with the airframe: its controls move, its lamps are fixed.
struct A320FlightDeckTests {
    @Test func flightDeckLoads() throws {
        let start = Date()
        let m = try A320Model.loadAnimated(from: A320ModelTests.directory)
        let parts = Set(m.model.groups.map(\.part))
        let deckParts = parts.filter { $0.hasPrefix("anim:a320.flightdeck|") }
        print("A320 with flight deck: \(m.model.triangleCount) triangles, \(m.model.groups.count) groups, \(deckParts.count) moving deck parts, loaded in \(Date().timeIntervalSince(start)) s")
        #expect(m.interiorModels.contains("a320.flightdeck"))
        #expect(deckParts.contains { $0.contains("sidestick_1") })
        #expect(deckParts.contains { $0.contains("thr_l_body") })
        #expect(deckParts.count < 40, "lamps and switches should not each be a separate moving part")
        #expect(parts.contains("windshield"))
        let screens = parts.filter { $0.hasPrefix("display:") && !$0.hasPrefix("display:text:") }
        print("readouts: \(parts.filter { $0.hasPrefix("display:text:") }.count)")
        #expect(parts.filter { $0.hasPrefix("display:text:") }.count == A320Model.deckReadouts.count)
        print("screens: \(screens.sorted())")
        #expect(Set(screens) == ["display:pfd1", "display:pfd2", "display:nd1", "display:nd2", "display:ewd", "display:sd",
                                 "display:mcdu", "display:dcdu", "display:isis", "display:clock", "display:atc", "display:batt1", "display:batt2"])
    }
}

/// A rolling wheel turns about its own axle wherever the strut has put it: its centre does not
/// move as it spins (with the animations nested the wrong way round, it orbited the
/// uncompressed axle and wobbled).
struct WheelSpinTests {
    @Test func wheelCentreStaysPutWhileSpinning() throws {
        let m = try A320Model.loadAnimated(from: A320ModelTests.directory)
        for object in ["MLGWheelsL", "NLGWheels"] {
            let groups = m.model.groups.filter { $0.part.hasSuffix("|" + object) || $0.part.hasSuffix("/" + object) }
            let pts = groups.flatMap(\.positions)
            func centre(_ turns: Double) -> SIMD3<Float> {
                var v = A320AnimationTests.readings(compression: 1.2)
                for p in A320Model.Property.wheelSpeed { v["spin:" + p] = turns }
                guard let t = m.transform(part: groups[0].part, values: v) else { return .zero }
                let moved = pts.map { t * SIMD4($0, 1) }
                let lo = moved.reduce(SIMD4<Float>(repeating: .infinity)) { simd_min($0, $1) }
                let hi = moved.reduce(SIMD4<Float>(repeating: -.infinity)) { simd_max($0, $1) }
                return SIMD3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
            }
            let drift = [0.01, 0.013, 0.021].map { simd_distance(centre(0), centre($0)) }.max() ?? 0
            print("\(object): centre drifts \(drift) m while spinning")
            #expect(drift < 0.02)
        }
    }
}
