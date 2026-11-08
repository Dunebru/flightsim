import Foundation
import Testing
import simd
@testable import Airports

/// Apron floodlight masts stand clear of the stands: none inside the footprint of an A320
/// parked at any airliner stand (nose 6 m ahead of the nose wheel, tail 33 m behind, wings
/// 18 m each side).
struct MastPlacementTests {
    @Test(arguments: ["KPHX", "KLAX"])
    func mastsClearOfParkedAircraft(icao: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Data/Bundle/Airports/\(icao).json").standardized
        let site = try AirportSite.load(url)
        let masts = AirportLights.mastPositions(site)
        var inside = 0
        for m in masts {
            for slot in site.airlinerStands {
                let f = SIMD2(sin(slot.heading), cos(slot.heading)), l = SIMD2(-f.y, f.x)
                let d = m - slot.position
                let along = simd_dot(d, f), across = simd_dot(d, l)
                if along < 6, along > -33, abs(across) < 18 { inside += 1; break }
            }
        }
        print("\(icao): \(masts.count) masts, \(inside) inside a stand")
        #expect(masts.count > 20)
        #expect(inside == 0)
    }
}
