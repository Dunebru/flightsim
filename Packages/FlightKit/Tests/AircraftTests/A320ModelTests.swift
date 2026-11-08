import Foundation
import Testing
import simd
@testable import Aircraft

/// The FlightGear A320 loads whole and its parts are sorted the way the renderer needs.
struct A320ModelTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Aircraft/A320").standardized

    @Test func loadsWithGearAndHiddenParts() throws {
        let m = try A320Model.load(from: Self.directory)
        let parts = Set(m.groups.map(\.part))
        #expect(parts == ["airframe", "gear", "hidden"], "\(parts)")
        #expect(m.triangleCount > 100_000)
        // Length about 37.6 m along x, span about 34.1 m along z (wingtip fences included).
        let size = m.boundsMax - m.boundsMin
        print("A320 size \(size), min \(m.boundsMin)")
        #expect(abs(size.x - 37.6) < 1)
        #expect(abs(size.z - 35.8) < 1.5)
        // The nose wheels: well forward, on the ground.
        let nose = m.groups.filter { $0.part == "gear" }.flatMap(\.positions).filter { $0.x < -8 }
        let noseX = nose.map(\.x).reduce(0, +) / Float(max(nose.count, 1))
        print("A320 nose gear at x \(noseX)")
        #expect(noseX < -11 && noseX > -16)
    }
}
