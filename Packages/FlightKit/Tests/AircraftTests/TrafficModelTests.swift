import Foundation
import Testing
import simd
@testable import Aircraft

/// The 777 and E175 traffic models load at their published size, with a nose wheel to stand on
/// and no lamp cones sticking out of them.
struct TrafficModelTests {
    static let aircraft = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Aircraft").standardized

    /// Extent of everything drawn (not hidden).
    static func drawnSize(_ m: AC3DModel) -> SIMD3<Float> {
        let p = m.groups.filter { $0.part != "hidden" }.flatMap(\.positions)
        let lo = p.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = p.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        return hi - lo
    }

    @Test(arguments: [("B777", "777", 63.7 as Float, 60.9 as Float), ("E175", "e175", 31.7, 26.0)])
    func publishedSize(folder: String, name: String, length: Float, span: Float) throws {
        let model = name == "777" ? TrafficModel.b777 : TrafficModel.e175
        let m = try model.load(from: Self.aircraft.appendingPathComponent(folder))
        let size = Self.drawnSize(m)
        print("\(name) drawn size \(size)")
        #expect(abs(size.x - length) < 1.5)
        #expect(abs(size.z - span) < 1.5)
        let nose = m.groups.filter { $0.part == "nosewheel" }.flatMap(\.positions)
        #expect(!nose.isEmpty)
        // Every livery's files are in the bundle.
        for livery in model.liveries {
            for file in livery.values {
                #expect(FileManager.default.fileExists(atPath: Self.aircraft.appendingPathComponent(folder).appendingPathComponent(file).path), "\(file)")
            }
        }
    }

    @Test func aboutAThirdOfNarrowStandsGetTheRegionalJet() {
        let seeds = (0..<1000).map { Float($0) / 1000 }
        let regional = seeds.filter { TrafficType.of(seed: $0, widebody: false) == .regional }.count
        #expect(regional > 220 && regional < 380, "\(regional)")
        #expect(seeds.allSatisfy { TrafficType.of(seed: $0, widebody: true) == .widebody })
    }
}
