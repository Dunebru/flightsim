import Foundation
import Testing
import simd
@testable import Aircraft

/// The levers move the right way for the values the session feeds them (FlightGear's ranges):
/// gear lever up at 0 and down at 3; thrust levers forward with thrust; flap lever aft with
/// each detent. Axes given as line objects follow SimGear's ordering rules.
struct DeckLeverTests {
    /// Where a lever's geometry centre goes (AC3D frame: x aft, y up) for a value.
    static func moved(_ m: AnimatedModel, _ property: String, _ value: Double) throws -> SIMD3<Float> {
        let key = try #require(m.animations.first { $0.value.contains { $0.property == property && $0.kind == .rotate } }?.key)
        let part = try #require(m.model.groups.first { $0.part.hasSuffix(key) || $0.part.contains(key + "/") }?.part)
        let pts = m.model.groups.filter { $0.part == part }.flatMap(\.positions)
        let c = pts.reduce(SIMD3<Float>.zero, +) / Float(pts.count)
        let t = try #require(m.transform(part: part, values: [property: value]))
        let p = t * SIMD4(c, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    @Test func leversMoveTheRightWay() throws {
        let m = try A320Model.loadAnimated(from: A320ModelTests.directory)
        typealias D = A320Model.DeckControl
        let gearUp = try Self.moved(m, D.gear, 0), gearDown = try Self.moved(m, D.gear, 3)
        print("gear lever down \(gearDown) up \(gearUp)")
        #expect(gearUp.y > gearDown.y + 0.01, "gear lever up should be higher")
        let idle = try Self.moved(m, D.throttle[0], 0), toga = try Self.moved(m, D.throttle[0], 1)
        print("thrust lever idle \(idle) toga \(toga)")
        #expect(toga.x < idle.x - 0.02, "thrust lever forward (toward the nose, -x) with thrust")
        let f0 = try Self.moved(m, D.flaps, 0), f4 = try Self.moved(m, D.flaps, 4)
        print("flap lever 0 \(f0) full \(f4)")
        #expect(f4.x > f0.x + 0.02, "flap lever aft for full flap")
    }
}

/// Every touchable flight deck object is found, inside the flight deck: within a few metres of
/// the pilot's eye (AC3D frame, about 16.5 m forward of the origin).
struct DeckPickTests {
    @Test func touchableObjectsAreFound() throws {
        let m = try A320Model.loadAnimated(from: A320ModelTests.directory)
        let missing = Set(A320Model.deckActions.keys).subtracting(m.pickTargets.keys)
        #expect(missing.isEmpty, "not found: \(missing.sorted())")
        for (name, t) in m.pickTargets {
            #expect(t.x > -19 && t.x < -14, "\(name) at x \(t.x)")
            #expect(t.w > 0.005 && t.w < 0.3, "\(name) radius \(t.w)")
        }
        // The FCU sits above the pedestal's gear lever... the glareshield is the highest.
        let fcu = try #require(m.pickTargets["hdg_sel"]), park = try #require(m.pickTargets["ParkBrk"])
        #expect(fcu.y > park.y + 0.3, "FCU \(fcu) above the parking brake \(park)")
    }
}
