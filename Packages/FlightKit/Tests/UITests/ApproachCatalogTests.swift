import Airports
import Autopilot
import FlightModel
import Foundation
import Testing
@testable import UI

/// ILS approaches built from the generated airports.
struct ApproachCatalogTests {
    static let airports = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Airports").standardized

    /// KPHX: every runway end NASR lists with an ILS, on the runway's true course, the threshold
    /// moved past 08's 274 m displacement, the glidepath through the published crossing height.
    @Test func kphxApproaches() throws {
        let site = try AirportSite.load(Self.airports.appendingPathComponent("KPHX.json"))
        let a = ApproachCatalog.approaches(at: site)
        let names = Set(a.map(\.name))
        #expect(names == ["ILS 07L", "ILS 07R", "ILS 25L", "ILS 08", "ILS 26"], "\(names.sorted())")
        let ils08 = try #require(a.first { $0.name == "ILS 08" })
        #expect(abs(ils08.courseDegrees - 90) < 1.5, "course \(ils08.courseDegrees)")
        let end = try #require(site.layout.runways.flatMap(\.ends).first { $0.ident == "08" })
        let moved = ils08.offsets(latitude: end.position.lat, longitude: end.position.lon)
        #expect(abs(moved.along + 273.7) < 2, "pavement end \(moved.along) m from the threshold")
        #expect(abs(ils08.thresholdCrossingHeightFeet - 69) < 1)
        // The localizer antenna is beyond the far end (26), about 300 m.
        let far = try #require(site.layout.runways.flatMap(\.ends).first { $0.ident == "26" })
        let o = ils08.offsets(latitude: far.position.lat, longitude: far.position.lon)
        #expect(abs(ils08.localizerDistanceMetres - o.along - 300) < 2)
    }

    /// The approach picked is the one ahead and lined up, not one behind or crossing.
    @Test func picksTheApproachAhead() throws {
        let site = try AirportSite.load(Self.airports.appendingPathComponent("KLAX.json"))
        let a = ApproachCatalog.approaches(at: site)
        #expect(a.count >= 6)
        let ils24R = try #require(a.first { $0.name == "ILS 24R" })
        // 15 km out on the extended centreline of 24R, heading down it.
        let r = 6_371_000.0
        let back = (ils24R.courseDegrees + 180) * .pi / 180
        var s = FlightState()
        s.latitude = ils24R.thresholdLatitude + 15_000 * cos(back) / r * 180 / .pi
        s.longitude = ils24R.thresholdLongitude + 15_000 * sin(back) / (r * cos(ils24R.thresholdLatitude * .pi / 180)) * 180 / .pi
        s.heading = ils24R.courseDegrees * .pi / 180
        #expect(ApproachCatalog.approachAhead(a, state: s)?.name == "ILS 24R")
        // Turned around, nothing is ahead.
        s.heading += .pi
        #expect(ApproachCatalog.approachAhead(a, state: s) == nil)
    }
}
