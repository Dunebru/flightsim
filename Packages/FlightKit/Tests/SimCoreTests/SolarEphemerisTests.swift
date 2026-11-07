import Foundation
import Testing
@testable import SimCore

/// Reference positions from NREL's Solar Position Algorithm (pvlib 0.x, method "nrel_numpy"),
/// an independent, higher-accuracy algorithm. PLAN.md M1 criterion: within 0.1 degrees.
struct SolarEphemerisTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let latitude, longitude: Double
        let time: String
        let azimuth, elevation, apparentElevation: Double
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "KPHX summer, sun high", latitude: 33.4342, longitude: -112.0116, time: "2026-06-21T19:30:00Z", azimuth: 180.0900, elevation: 80.0026, apparentElevation: 80.0054),
        Case(name: "KPHX winter morning", latitude: 33.4342, longitude: -112.0116, time: "2026-12-21T15:10:00Z", azimuth: 123.8444, elevation: 6.6571, apparentElevation: 6.7800),
        Case(name: "EGLL equinox, near sunset", latitude: 51.47, longitude: -0.4543, time: "2026-03-20T17:45:00Z", azimuth: 265.2944, elevation: 3.7980, apparentElevation: 3.9928),
        Case(name: "YSSY afternoon", latitude: -33.9461, longitude: 151.1772, time: "2026-11-07T04:00:00Z", azimuth: 290.3334, elevation: 53.7660, apparentElevation: 53.7783),
        Case(name: "Tromso polar night", latitude: 69.6496, longitude: 18.956, time: "2026-12-21T11:00:00Z", azimuth: 184.0838, elevation: -3.1439, apparentElevation: -3.1439),
        Case(name: "Equator, midnight", latitude: 0, longitude: 0, time: "2026-09-01T00:00:00Z", azimuth: 359.7159, elevation: -81.6526, apparentElevation: -81.6526),
    ]

    @Test(arguments: cases)
    func matchesSPA(_ c: Case) throws {
        let date = try #require(ISO8601DateFormatter().date(from: c.time))
        let sun = SolarEphemeris.sunPosition(at: date, latitude: c.latitude, longitude: c.longitude)
        #expect(abs(sun.elevation - c.elevation) < 0.1)
        #expect(abs(sun.apparentElevation - c.apparentElevation) < 0.1)
        var dAz = abs(sun.azimuth - c.azimuth).truncatingRemainder(dividingBy: 360)
        if dAz > 180 { dAz = 360 - dAz }
        #expect(dAz < 0.1)
    }

    @Test func directionIsUnitAndPointsUp() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-06-21T19:30:00Z"))
        let d = SolarEphemeris.sunPosition(at: date, latitude: 33.4342, longitude: -112.0116).directionENU
        #expect(abs((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() - 1) < 1e-12)
        #expect(d.z > 0.98)
    }
}
