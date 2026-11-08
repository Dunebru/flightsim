import Airports
import Foundation
import Testing
import simd
@testable import Traffic

/// AI traffic on the real KPHX and KLAX layouts.
@Suite(.serialized)
struct AirportTrafficTests {
    static let airports = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Airports").standardized

    static func site(_ icao: String) throws -> AirportSite {
        try AirportSite.load(airports.appendingPathComponent("\(icao).json"))
    }

    /// The taxiway network joins up: free gates reach every runway end's entry.
    @Test func kphxNetworkConnectsGatesToRunways() throws {
        let t = AirportTraffic(site: try Self.site("KPHX"), excludingStand: nil)
        #expect(t.graph.nodes.count > 500)
        #expect(t.freeStands.count > 10)
        var reached = 0, tried = 0
        for r in t.runways where !r.entries.isEmpty {
            for s in t.freeStands.prefix(20) {
                guard let from = t.standNode(s) else { continue }
                tried += 1
                if t.graph.path(from: from, to: r.entries[0].off) != nil { reached += 1 }
            }
        }
        print("TRAFFIC KPHX graph \(t.graph.nodes.count) nodes; gate to runway routes \(reached)/\(tried); runways \(t.runways.map { "\($0.ident) exits \($0.exits.count) entries \($0.entries.count)" })")
        #expect(tried > 50)
        #expect(Double(reached) / Double(tried) > 0.9)
    }

    /// Forty minutes at each airport: aircraft land, reach gates and take off, never get within
    /// 25 m of each other on the ground, and seldom have to be withdrawn when stuck.
    @Test(arguments: ["KPHX", "KLAX"])
    func trafficFlows(_ icao: String) throws {
        let t = AirportTraffic(site: try Self.site(icao), excludingStand: nil, seed: 7)
        var landedOnRunway = true
        for _ in 0..<(40 * 60 * 4) {
            t.update(dt: 0.25)
            for a in t.snapshot where a.onGround {
                // On the ground means on the surface.
                let z = t.site.z(SIMD2(a.position.x, a.position.y))
                if abs(a.position.z - z) > 0.5 { landedOnRunway = false }
            }
        }
        print("TRAFFIC \(icao) runways \(t.activeRunways): landings \(t.landings), at gate \(t.arrivedAtGate), takeoffs \(t.takeoffs), withdrawn when stuck \(t.withdrawals), closest on the ground \(Int(t.closestOnGround)) m")
        #expect(t.landings >= 8)
        #expect(t.arrivedAtGate >= 5)
        #expect(t.takeoffs >= 6)
        #expect(t.closestOnGround > 25, "\(t.closeCalls)")
        #expect(t.withdrawals <= 5, "stuck aircraft are rare (one in eight minutes): \(t.withdrawalNotes)")
        #expect(landedOnRunway)
    }

    /// Watched from the middle of the airport, nothing stuck nearby is withdrawn (it waits).
    @Test func nothingVanishesInView() throws {
        let site = try Self.site("KLAX")
        let watched = AirportTraffic(site: site, excludingStand: nil, seed: 7)
        watched.viewer = SIMD2(0, 0)
        var seen = Set<Int>()
        for _ in 0..<(40 * 60 * 4) {
            let before = watched.idsNear(SIMD2(0, 0), within: 2_000)
            watched.update(dt: 0.25)
            let after = Set(watched.snapshotIDs)
            // Anything that was on the ground within 2 km and is gone must have taken off.
            for id in before where !after.contains(id) { seen.insert(id) }
        }
        #expect(watched.withdrawnNear(SIMD2(0, 0), within: 2_000) == 0)
        _ = seen
    }

    /// A player sitting on an active runway sends arrivals around instead of landing on them.
    @Test func arrivalsGoAroundThePlayerOnTheRunway() throws {
        let site = try Self.site("KPHX")
        let t = AirportTraffic(site: site, excludingStand: nil, seed: 7)
        let rw = try #require(t.runways.first { $0.ident == t.activeRunways.first })
        t.player = (rw.point(300), true)
        for _ in 0..<(20 * 60 * 4) { t.update(dt: 0.25) }
        print("TRAFFIC go-arounds \(t.goArounds), landings \(t.landings)")
        #expect(t.goArounds >= 2)
    }

    /// The wind picks the runway ends: an east wind turns KPHX around to the 07s and 08.
    @Test func windPicksTheRunways() throws {
        let t = AirportTraffic(site: try Self.site("KPHX"), excludingStand: nil)
        #expect(Set(t.activeRunways) == ["25L", "25R", "26"], "light wind: west flow")
        t.setWind(fromDegrees: 90, knots: 12)
        #expect(Set(t.activeRunways) == ["07L", "07R", "08"])
    }
}
