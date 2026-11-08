import Airports
import Foundation
import Testing
@testable import FlightToolsCore

struct AirportImportTests {
    @Test func csvHandlesQuotesCommasAndNewlines() {
        let rows = CSV.rows("\"a\",\"b, c\",\"say \"\"hi\"\"\"\r\n1,\"two\nlines\",3\n")
        #expect(rows.count == 2)
        #expect(rows[0] == ["a", "b, c", "say \"hi\""])
        #expect(rows[1] == ["1", "two\nlines", "3"])
    }

    /// Member ways of a multipolygon, in any order and direction, join into one closed ring.
    @Test func ringsJoinMemberWays() {
        let a = LatLon(0, 0), b = LatLon(0, 1), c = LatLon(1, 1), d = LatLon(1, 0)
        // Edges a-b, c-b (reversed), c-d, a-d (reversed), shuffled.
        let rings = PlanarGeometry.rings([[c, d], [a, b], [a, d], [c, b]])
        #expect(rings.count == 1)
        #expect(rings[0].first == rings[0].last)
        #expect(Set(rings[0]) == Set([a, b, c, d]))
    }

    @Test func hullWrapsANotchedOutline() {
        // A U shape: the hull closes the notch.
        let u: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(7, 10), SIMD2(7, 3), SIMD2(3, 3), SIMD2(3, 10), SIMD2(0, 10)]
        let h = PlanarGeometry.hull(u)
        #expect(h.count == 5)   // four corners, closed
        #expect(PlanarGeometry.contains(h, SIMD2(5, 8)))
        #expect(!PlanarGeometry.contains(u + [u[0]], SIMD2(5, 8)))
    }

    /// The real NASR file: KPHX runway 08 matches the published record.
    @Test func nasrReadsKPHX() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Data/raw/nasr").standardized
        let a = try NASRAirport.load(directory: dir, icao: "KPHX")
        let r = try #require(a.runways.first { $0.name == "08/26" })
        let e = r.ends[0]
        #expect(e.ident == "08")
        #expect(abs(e.displacedThreshold - 898 * 0.3048) < 0.01)
        #expect(e.approachLights == "MALSF")
        #expect(e.visualGlideSlope == "P4L")
        #expect(r.surface == .concrete)
        #expect(abs(r.width - 150 * 0.3048) < 0.01)
    }
}
