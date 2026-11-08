public import Foundation
public import Traffic
import simd

/// One transmission: who said it, the words shown, and the words spoken.
public struct ATCMessage: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public var from: String
    public var text: String
    public var spoken: String
    /// From the player (shown, not spoken).
    public var isPilot: Bool

    public static func == (a: ATCMessage, b: ATCMessage) -> Bool { a.id == b.id }
}

/// What the player can say now.
public enum ATCRequest: String, Sendable, CaseIterable, Identifiable {
    case atis, taxi, readyForDeparture, checkInDeparture, requestApproach, inboundForLanding, clearOfRunway, taxiToParking
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .atis: "Listen to ATIS"
        case .taxi: "Request taxi"
        case .readyForDeparture: "Ready for departure"
        case .checkInDeparture: "Check in with departure"
        case .requestApproach: "Request the ILS"
        case .inboundForLanding: "Inbound for landing"
        case .clearOfRunway: "Clear of the runway"
        case .taxiToParking: "Request taxi to parking"
        }
    }
}

/// Where the player is, as ATC sees it.
public struct ATCSituation: Sendable {
    public var position: SIMD2<Double>          // airport frame, metres
    public var heightAboveGroundFeet: Double
    public var altitudeFeet: Double
    public var groundSpeedKnots: Double
    public var onGround: Bool
    /// The ILS the aircraft is lined up for, if any (its runway end).
    public var approachRunway: String?

    public init(position: SIMD2<Double>, heightAboveGroundFeet: Double, altitudeFeet: Double, groundSpeedKnots: Double,
                onGround: Bool, approachRunway: String?) {
        self.position = position
        self.heightAboveGroundFeet = heightAboveGroundFeet
        self.altitudeFeet = altitudeFeet
        self.groundSpeedKnots = groundSpeedKnots
        self.onGround = onGround
        self.approachRunway = approachRunway
    }
}

/// The weather for the ATIS, from the METAR.
public struct ATISWeather: Sendable {
    public var windFrom: Double, windKnots: Double, gust: Double?
    public var visibilityMiles: Double
    /// Layers as "few", "scattered", "broken", "overcast" with base in feet above the field.
    public var clouds: [(cover: String, baseFeet: Int)]
    public var temperature: Int, dewpoint: Int?
    public var altimeterHPa: Double
    public var observed: Date

    public init(windFrom: Double, windKnots: Double, gust: Double?, visibilityMiles: Double, clouds: [(cover: String, baseFeet: Int)],
                temperature: Int, dewpoint: Int?, altimeterHPa: Double, observed: Date) {
        self.windFrom = windFrom
        self.windKnots = windKnots
        self.gust = gust
        self.visibilityMiles = visibilityMiles
        self.clouds = clouds
        self.temperature = temperature
        self.dewpoint = dewpoint
        self.altimeterHPa = altimeterHPa
        self.observed = observed
    }
}

/// Ground, tower, departure and approach at one airport, for one aircraft: offers the calls that
/// make sense where the aircraft is, and answers them with the traffic in mind.
public final class ATCController {
    public let city: String
    public let approachFacility: String
    public let callsign: String
    public let spokenCallsign: String
    public private(set) var log: [ATCMessage] = []

    // What has been cleared so far.
    private var taxiRunway: String?
    private var takeoffRunway: String?
    private var checkedIn = false
    private var approachRunway: String?
    private var landingRunway: String?
    private var landed = false
    private var parkingCleared = false

    public init(city: String, approachFacility: String, callsign: String, spokenCallsign: String) {
        self.city = city
        self.approachFacility = approachFacility
        self.callsign = callsign
        self.spokenCallsign = spokenCallsign
    }

    /// The calls available now.
    public func requests(_ s: ATCSituation, traffic: AirportTraffic) -> [ATCRequest] {
        var out: [ATCRequest] = [.atis]
        let distance = simd_length(s.position)
        if s.onGround {
            if let rw = traffic.runway(at: s.position) {
                if landed || (s.groundSpeedKnots < 60 && landingRunway == rw) { out.append(.clearOfRunway) }
            } else if landed || landingRunway != nil {
                if !parkingCleared { out.append(.taxiToParking) }
            } else if traffic.holdingShort(at: s.position) != nil, takeoffRunway == nil {
                out.append(.readyForDeparture)
            } else if taxiRunway == nil {
                out.append(.taxi)
            }
        } else {
            if takeoffRunway != nil && !checkedIn && distance < 25_000 && s.heightAboveGroundFeet > 400 { out.append(.checkInDeparture) }
            if approachRunway == nil && distance < 60_000 { out.append(.requestApproach) }
            if landingRunway == nil && distance < 25_000 { out.append(.inboundForLanding) }
        }
        return out
    }

    /// Says a call and gets the answer; returns the new messages (also appended to the log).
    @discardableResult
    public func say(_ request: ATCRequest, _ s: ATCSituation, traffic: AirportTraffic, weather: ATISWeather) -> [ATCMessage] {
        var out: [ATCMessage] = []
        func pilot(_ facility: String, _ words: String) {
            out.append(ATCMessage(from: "You", text: "\(city) \(facility), \(callsign), \(words)", spoken: "", isPilot: true))
        }
        func atc(_ facility: String, _ text: String, _ spoken: String) {
            out.append(ATCMessage(from: "\(city) \(facility)", text: "\(callsign), \(text)",
                                  spoken: "\(spokenCallsign), \(spoken)", isPilot: false))
        }
        let windText = weather.windKnots < 1 ? "wind calm"
            : String(format: "wind %03d at %d%@", Int((weather.windFrom / 10).rounded()) * 10, Int(weather.windKnots.rounded()),
                     weather.gust.map { " gust \(Int($0.rounded()))" } ?? "")
        let windSpoken = Phraseology.wind(from: weather.windFrom, knots: weather.windKnots, gust: weather.gust)

        switch request {
        case .atis:
            let a = atis(weather, runways: traffic.activeRunways)
            out.append(ATCMessage(from: "\(city) ATIS", text: a.text, spoken: a.spoken, isPilot: false))
        case .taxi:
            pilot("Ground", "ready to taxi with information \(atisWord(weather.observed))")
            if let route = traffic.routeToRunway(from: s.position) {
                taxiRunway = route.destination
                let via = route.via.isEmpty ? "" : ", taxi via \(route.via.joined(separator: ", "))"
                let viaSpoken = route.via.isEmpty ? "" : ", taxi via " + route.via.map(Phraseology.taxiway).joined(separator: ", ")
                atc("Ground", "runway \(route.destination)\(via), hold short of runway \(route.destination).",
                    "\(Phraseology.runway(route.destination))\(viaSpoken), hold short of \(Phraseology.runway(route.destination)).")
            } else {
                atc("Ground", "unable to find a route, taxi to the runway in use at your discretion.",
                    "unable to find a route, taxi to the runway in use at your discretion.")
            }
        case .readyForDeparture:
            let rw = traffic.holdingShort(at: s.position) ?? taxiRunway ?? traffic.activeRunways.first ?? ""
            pilot("Tower", "holding short of runway \(rw), ready for departure")
            if traffic.runwayIsClear(rw) {
                takeoffRunway = rw
                traffic.playerClearance = (rw, false)
                atc("Tower", "\(windText), runway \(rw), cleared for takeoff.", "\(windSpoken), \(Phraseology.runway(rw)), cleared for takeoff.")
            } else {
                atc("Tower", "hold short of runway \(rw), traffic landing.", "hold short of \(Phraseology.runway(rw)), traffic landing.")
            }
        case .checkInDeparture:
            checkedIn = true
            traffic.playerClearance = nil
            let target = s.altitudeFeet < 9_000 ? 10_000 : Int((s.altitudeFeet / 1_000).rounded(.up)) * 1_000 + 2_000
            pilot("Departure", "climbing through \(Int((s.altitudeFeet / 100).rounded()) * 100)")
            atc("Departure", "radar contact, climb and maintain \(target.formatted()).",
                "radar contact, climb and maintain \(Phraseology.altitude(target)).")
        case .requestApproach:
            let rw = s.approachRunway ?? traffic.arrivalRunway(near: s.position) ?? ""
            approachRunway = rw
            pilot("Approach", "with information \(atisWord(weather.observed)), request the ILS runway \(rw)")
            atc(approachFacility == city ? "Approach" : approachFacility, "cleared ILS runway \(rw) approach, maintain 2,000 until established.",
                "cleared I L S \(Phraseology.runway(rw)) approach, maintain two thousand until established on the localizer.")
        case .inboundForLanding:
            let rw = approachRunway ?? s.approachRunway ?? traffic.arrivalRunway(near: s.position) ?? ""
            pilot("Tower", "inbound on the ILS runway \(rw)")
            let ahead = traffic.arrivalsAhead(runway: rw, of: s.position)
            if ahead > 0 {
                atc("Tower", "number \(ahead + 1), follow the traffic on final, runway \(rw), cleared to land, \(windText).",
                    "number \(ahead + 1), follow the traffic on final, \(Phraseology.runway(rw)), cleared to land, \(windSpoken).")
            } else {
                atc("Tower", "\(windText), runway \(rw), cleared to land.", "\(windSpoken), \(Phraseology.runway(rw)), cleared to land.")
            }
            landingRunway = rw
            traffic.playerClearance = (rw, true)
        case .clearOfRunway:
            landed = true
            traffic.playerClearance = nil
            pilot("Tower", "clear of the runway")
            atc("Tower", "contact ground.", "contact ground.")
        case .taxiToParking:
            pilot("Ground", "clear of the runway, request taxi to parking")
            if let route = traffic.routeToGate(from: s.position) {
                parkingCleared = true
                let via = route.via.isEmpty ? "" : " via \(route.via.joined(separator: ", "))"
                let viaSpoken = route.via.isEmpty ? "" : " via " + route.via.map(Phraseology.taxiway).joined(separator: ", ")
                atc("Ground", "taxi to gate \(route.destination)\(via).", "taxi to gate \(Phraseology.spell(route.destination))\(viaSpoken).")
            } else {
                atc("Ground", "taxi to parking at your discretion.", "taxi to parking at your discretion.")
            }
        }
        log.append(contentsOf: out)
        if log.count > 40 { log.removeFirst(log.count - 40) }
        return out
    }

    /// The ATIS letter: a new one each hour.
    func atisLetter(_ observed: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String(letters[utc.component(.hour, from: observed) % 26])
    }

    /// The ATIS letter as a word: "Hotel".
    func atisWord(_ observed: Date) -> String {
        let word = Phraseology.letters[Character(atisLetter(observed))] ?? atisLetter(observed)
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// The broadcast: information letter, time, wind, visibility, sky, temperature, altimeter, runways.
    public func atis(_ w: ATISWeather, runways: [String]) -> (text: String, spoken: String) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.hour, .minute], from: w.observed)
        let time = String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
        let letter = atisLetter(w.observed)
        let letterWord = Phraseology.letters[Character(letter)] ?? letter
        let letterTitle = letterWord.prefix(1).uppercased() + letterWord.dropFirst()
        let vis = w.visibilityMiles >= 10 ? 10 : max(Int(w.visibilityMiles.rounded()), 0)
        let sky = w.clouds.isEmpty ? ("clear", "sky clear")
            : (w.clouds.map { "\($0.cover) \($0.baseFeet.formatted())" }.joined(separator: ", "),
               w.clouds.map { "\($0.cover) \(Phraseology.altitude($0.baseFeet))" }.joined(separator: ", "))
        let rwText = runways.joined(separator: ", ")
        let rwSpoken = runways.map(Phraseology.runway).joined(separator: ", ")
        let inches = String(format: "%.2f", w.altimeterHPa / 33.863_9)
        let windText = w.windKnots < 1 ? "wind calm" : String(format: "wind %03d at %d", Int((w.windFrom / 10).rounded()) * 10, Int(w.windKnots.rounded()))
        let text = "\(city) information \(letterTitle), \(time) Zulu. \(windText). Visibility \(vis). \(sky.0.prefix(1).uppercased() + sky.0.dropFirst()). "
            + "Temperature \(w.temperature)\(w.dewpoint.map { ", dewpoint \($0)" } ?? ""). Altimeter \(inches). "
            + "Landing and departing \(rwText). Advise on initial contact you have information \(letterTitle)."
        let tempSpoken = (w.temperature < 0 ? "minus " : "") + Phraseology.spell(String(abs(w.temperature)))
        let dewSpoken = w.dewpoint.map { ", dewpoint " + ($0 < 0 ? "minus " : "") + Phraseology.spell(String(abs($0))) } ?? ""
        let spoken = "\(city) information \(letterWord), \(Phraseology.spell(time)) zulu. "
            + "\(Phraseology.wind(from: w.windFrom, knots: w.windKnots, gust: w.gust)). visibility \(Phraseology.spell(String(vis))). \(sky.1). "
            + "temperature \(tempSpoken)\(dewSpoken). \(Phraseology.altimeter(hPa: w.altimeterHPa)). "
            + "landing and departing \(rwSpoken). advise on initial contact you have information \(letterWord)."
        return (text, spoken)
    }
}
