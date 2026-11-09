import Airports
import Foundation
import Testing
import simd
@testable import ATC
@testable import Traffic

struct PhraseologyTests {
    @Test func saysThingsTheFAAWay() {
        #expect(Phraseology.runway("25R") == "runway two five right")
        #expect(Phraseology.runway("8") == "runway eight")
        #expect(Phraseology.heading(90) == "zero niner zero")
        #expect(Phraseology.heading(360) == "three six zero")
        #expect(Phraseology.altitude(5_000) == "five thousand")
        #expect(Phraseology.altitude(11_500) == "one one thousand five hundred")
        #expect(Phraseology.altitude(24_000) == "flight level two four zero")
        #expect(Phraseology.altimeter(hPa: 1_013.25) == "altimeter two niner niner two")
        #expect(Phraseology.wind(from: 258, knots: 8, gust: nil) == "wind two six zero at eight")
        #expect(Phraseology.wind(from: 220, knots: 18, gust: 32) == "wind two two zero at one eight gusts three two")
        #expect(Phraseology.wind(from: 0, knots: 0, gust: nil) == "wind calm")
        #expect(Phraseology.taxiway("B3") == "bravo three")
    }
}

/// ATC at KPHX with its traffic running.
@Suite(.serialized)
struct ATCControllerTests {
    static let airports = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Airports").standardized

    static let weather = ATISWeather(windFrom: 260, windKnots: 8, gust: nil, visibilityMiles: 10,
                                     clouds: [("few", 6_000)], temperature: 24, dewpoint: 4, altimeterHPa: 1_012.6,
                                     observed: ISO8601DateFormatter().date(from: "2026-06-21T19:51:00Z")!)

    func setup() throws -> (ATCController, AirportTraffic, AirportSite) {
        let site = try AirportSite.load(Self.airports.appendingPathComponent("KPHX.json"))
        let traffic = AirportTraffic(site: site, excludingStand: nil, seed: 5)
        return (ATCController(city: "Phoenix", approachFacility: "Phoenix", callsign: "N172SP", spokenCallsign: "Cessna one seven two sierra papa"),
                traffic, site)
    }

    @Test func atisReadsTheWeatherAndRunways() throws {
        let (atc, traffic, _) = try setup()
        let a = atc.atis(Self.weather, runways: traffic.activeRunways)
        #expect(a.text.contains("Phoenix information Tango, 1951 Zulu"), "\(a.text)")
        #expect(a.text.contains("wind 260 at 8") && a.text.contains("Altimeter 29.90") && a.text.contains("25L"))
        #expect(a.spoken.contains("altimeter two niner niner zero") && a.spoken.contains("runway two five left"))
    }

    /// From a gate: taxi offered, a real route by taxiway names to a runway in use; at its hold,
    /// takeoff offered, and refused while an arrival is on short final.
    @Test func taxiAndTakeoff() throws {
        let (atc, traffic, site) = try setup()
        let gate = try #require(site.airlinerStands.first { !$0.occupied })
        let atGate = ATCSituation(position: gate.line[0], heightAboveGroundFeet: 0, altitudeFeet: 1_135, groundSpeedKnots: 0,
                                  onGround: true, approachRunway: nil)
        #expect(atc.requests(atGate, traffic: traffic).contains(.taxi))
        let taxi = atc.say(.taxi, atGate, traffic: traffic, weather: Self.weather)
        let reply = try #require(taxi.last)
        print("ATC \(reply.text)")
        #expect(taxi.first?.text.hasSuffix("with information Tango") == true, "\(taxi.first?.text ?? "")")
        #expect(reply.text.contains("taxi via") && reply.text.contains("hold short of runway"))
        let route = try #require(traffic.routeToRunway(from: gate.line[0]))
        let hold = try #require(route.path.last)
        // The cleared route is kept for the map: from the aircraft to the hold.
        #expect(atc.taxiPath.first == gate.line[0])
        #expect(atc.taxiPath.last == hold)
        #expect(atc.taxiPath.count >= 3)
        let atHold = ATCSituation(position: hold, heightAboveGroundFeet: 0, altitudeFeet: 1_135, groundSpeedKnots: 0,
                                  onGround: true, approachRunway: nil)
        #expect(atc.requests(atHold, traffic: traffic).contains(.readyForDeparture))
        // Wait for an arrival to be on short final for that runway: takeoff is refused.
        var refused = false
        for _ in 0..<(30 * 60 * 4) {
            traffic.update(dt: 0.25)
            if !traffic.runwayIsClear(route.destination) { refused = true; break }
        }
        #expect(refused, "an arrival came to that runway")
        let held = atc.say(.readyForDeparture, atHold, traffic: traffic, weather: Self.weather)
        #expect(held.last?.text.contains("hold short") == true, "\(held.last?.text ?? "")")
    }
}
