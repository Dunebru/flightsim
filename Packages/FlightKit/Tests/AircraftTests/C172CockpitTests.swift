import Foundation
import Testing
import simd
@testable import Aircraft

/// The c172p cockpit assembles from FlightGear's panel model, and its animations line up with
/// the geometry they move.
struct C172CockpitTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Aircraft/c172p").standardized

    /// The airframe file brings the cockpit with it, and its control surfaces move.
    @Test func wholeAircraftLoads() throws {
        let m = try C172Model.loadAircraft(directory: Self.directory)
        let parts = Set(m.model.groups.map(\.part))
        print("aircraft: \(m.model.triangleCount) triangles; properties: \(m.properties.sorted().filter { !$0.contains("kap140") })")
        for p in ["anim:c172p-model|leftaileron", "anim:c172p-model|rudder_1", "anim:c172p-model|elevatorleft", "anim:c172p-model|flaps",
                  "anim:asi|Needle", "anim:yoke|LeftYoke", "anim:pedals-pilot|LeftPedal", "prop-fast", "hidden", "airframe", "cabin"] {
            #expect(parts.contains(where: { $0 == p || $0.hasPrefix(p + "/") }), "missing \(p)")
        }
        #expect(m.isInterior(part: "anim:asi|Needle") && !m.isInterior(part: "anim:c172p-model|rudder_1"))
    }

    @Test func loadsPanelInstrumentsYokeAndPedals() throws {
        let m = try C172Model.loadCockpit(directory: Self.directory)
        let parts = Set(m.model.groups.map(\.part))
        let animatedParts = parts.filter { $0.hasPrefix("anim:") }
        print("cockpit: \(m.model.triangleCount) triangles, \(m.model.groups.count) groups, \(animatedParts.count) animated parts")
        print("properties: \(m.properties.sorted())")
        #expect(m.model.triangleCount > 50_000)
        for p in ["anim:asi|Needle", "anim:AI|Roll", "anim:alt|Needle100", "anim:hi|Face", "anim:VSI|PointerCentre",
                  "anim:tc|Airplane", "anim:RPM|PointerCentre", "anim:yoke|LeftYoke", "anim:pedals-pilot|LeftPedal"] {
            #expect(animatedParts.contains(where: { $0 == p || $0.hasPrefix(p + "/") }), "missing \(p)")
        }
    }

    /// Every rotating needle turns about a point on its own geometry. Were the FlightGear XML
    /// axes converted wrongly (a sign or a swapped axis), the pivots would land tens of
    /// centimetres away from the needles.
    @Test func needlesPivotOnThemselves() throws {
        let m = try C172Model.loadCockpit(directory: Self.directory)
        let checks = [("asi", "Needle"), ("alt", "Needle100"), ("alt", "Needle1000"), ("VSI", "PointerCentre"),
                      ("RPM", "PointerCentre"), ("tc", "Airplane"), ("hi", "Face"), ("vor", "Ring")]
        for (model, object) in checks {
            let positions = m.model.groups.filter { $0.part.hasPrefix("anim:\(model)|") && $0.part.hasSuffix(object) }
                .flatMap(\.positions)
            #expect(!positions.isEmpty, "\(model) \(object) has no geometry")
            guard let anim = m.animations["\(model)|\(object)"]?.first(where: { $0.kind == .rotate }), !positions.isEmpty else {
                Issue.record("\(model) \(object) has no rotation")
                continue
            }
            let lo = positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            let c = SIMD3<Float>(anim.center)
            // Within the needle's bounding box, a few millimetres of slack.
            let inside = all(c .>= lo - 0.006) && all(c .<= hi + 0.006)
            print("\(model) \(object): pivot \(c) box \(lo)...\(hi)")
            #expect(inside, "\(model) \(object) pivot \(c) outside \(lo)...\(hi)")
        }
    }

    /// The airspeed needle reads what FlightGear's table says: at 100 knots it has turned 197
    /// degrees clockwise as the pilot sees it (looking forward, along -x).
    @Test func airspeedNeedleTurnsClockwise() throws {
        let m = try C172Model.loadCockpit(directory: Self.directory)
        let tipBase = m.model.groups.filter { $0.part == "anim:asi|Needle" }.flatMap(\.positions)
        guard let anim = m.animations["asi|Needle"]?.first else { Issue.record("no ASI animation"); return }
        let c = SIMD3<Float>(anim.center)
        // The needle's far end: the vertex farthest from the pivot, at rest (0 kt).
        guard let tip = tipBase.max(by: { simd_distance($0, c) < simd_distance($1, c) }),
              let t = m.transform(part: "anim:asi|Needle", values: [C172Model.Property.airspeed: 100]) else {
            Issue.record("no needle"); return
        }
        let moved = t * SIMD4(tip, 1)
        // Angles in the panel plane as the pilot sees it: right is -z (AC3D z points left), up is +y.
        func angle(_ p: SIMD3<Float>) -> Float { atan2(-(p.z - c.z), p.y - c.y) }   // clockwise from 12 o'clock
        var turned = (angle(SIMD3(moved.x, moved.y, moved.z)) - angle(tip)) * 180 / .pi
        if turned < 0 { turned += 360 }
        print("ASI needle turned \(turned) degrees at 100 kt")
        #expect(abs(turned - 197) < 3)
    }

    /// The control surfaces move the right way for what the flight supplies: JSBSim's c172p
    /// positions for a right roll (left aileron +1, right -1), nose up (elevator -1) and right
    /// yaw (rudder +1) must lower the left aileron's trailing edge, raise the right one's and the
    /// elevator's, and swing the rudder's to the right. AC3D frame: x aft, y up, z left.
    @Test func controlSurfacesMoveTheRightWay() throws {
        let m = try C172Model.loadAircraft(directory: Self.directory)
        let values = C172Model.surfaceReadings(leftAileron: 1, rightAileron: -1, elevator: -1, rudder: 1)
        func trailingEdgeShift(_ part: String) -> SIMD3<Float> {
            let p = m.model.groups.filter { $0.part == part }.flatMap(\.positions)
            guard let maxX = p.map(\.x).max(), let t = m.transform(part: part, values: values) else { return SIMD3(repeating: .nan) }
            let edge = p.filter { $0.x > maxX - 0.02 }
            let before = edge.reduce(SIMD3<Float>.zero, +) / Float(edge.count)
            let after = edge.map { SIMD3((t * SIMD4($0, 1)).x, (t * SIMD4($0, 1)).y, (t * SIMD4($0, 1)).z) }.reduce(SIMD3<Float>.zero, +) / Float(edge.count)
            return after - before
        }
        let left = trailingEdgeShift("anim:c172p-model|leftaileron").y
        let right = trailingEdgeShift("anim:c172p-model|rightaileron").y
        let elevator = trailingEdgeShift("anim:c172p-model|elevatorleft").y
        let rudder = trailingEdgeShift("anim:c172p-model|rudder_1").z
        print("left aileron \(left) m, right aileron \(right) m, elevator \(elevator) m, rudder \(rudder) m (z, left positive)")
        #expect(left < -0.05)
        #expect(right > 0.05)
        #expect(elevator > 0.05)
        #expect(rudder < -0.05)
    }
}

/// The radio stack's digit drums read the frequencies: COMM 1 at 118.70 turns its hundreds drum to
/// show 1, its tens to 1 and its units to 8 (each a tenth of the strip per digit).
struct RadioDrumTests {
    @Test func commDrumsShowTheFrequency() throws {
        let m = try C172Model.loadAircraft(directory: C172CockpitTests.directory)
        func shift(_ object: String) -> Float {
            let part = m.model.groups.first { $0.part.hasSuffix("|" + object) }?.part ?? ""
            let o = m.textureOffset(part: part, values: [:])
            return (o.x * 10).rounded() / 10
        }
        let hundreds = shift("CommUse100M"), tens = shift("CommUse10M"), units = shift("CommUse1M"), tenths = shift("CommUse100K")
        print("drums: \(hundreds) \(tens) \(units) \(tenths)")
        func digit(_ v: Float) -> Int { Int((v * 10).truncatingRemainder(dividingBy: 10).rounded()) }
        #expect(digit(hundreds) == 1 && digit(tens) == 1 && digit(units) == 8 && digit(tenths) == 7)
    }
}
