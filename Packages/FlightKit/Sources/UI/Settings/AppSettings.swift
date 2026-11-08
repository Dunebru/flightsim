public import Foundation
public import Airports
import Observation

/// How the pilot flies.
public enum ControlMode: String, Codable, CaseIterable, Sendable {
    /// Tilt the phone (primary).
    case tilt
    /// On-screen stick.
    case stick
}

/// Settings that persist across launches (UserDefaults, one JSON value).
@Observable
public final class AppSettings {
    public var aircraftID = "c172p" { didSet { save() } }
    /// ICAO of the departure airport (KPHX or KLAX), and where at it the flight starts.
    public var airport = "KPHX" { didSet { save() } }
    public var spot: StartSpot = .runway("08") { didSet { save() } }
    /// nil: real time. Otherwise the UTC hour (0-23.99) pinned for the flight.
    public var fixedUTCHour: Double? = nil { didSet { save() } }
    public var controlMode: ControlMode = .tilt { didSet { save() } }
    /// Multiplies deflection: 0.5 gentle ... 2.0 sharp.
    public var sensitivity: Double = 1.0 { didSet { save() } }
    public var invertPitch = false { didSet { save() } }
    public var upscaler = "temporal" { didSet { save() } }
    public var showStats = false { didSet { save() } }
    /// The departure airport's live METAR, or a chosen kind of day.
    public var weather: WeatherChoice = .live { didSet { save() } }
    /// A METAR given at launch (scripts and screenshots), used instead of the live one.
    public private(set) var forcedMetar: String?

    private let defaults: UserDefaults
    private var loading = false
    static let key = "FlightSettings.v1"

    private struct Stored: Codable {
        var aircraftID: String
        var airport: String?
        var spot: StartSpot?
        var fixedUTCHour: Double?
        var controlMode: ControlMode
        var sensitivity: Double
        var invertPitch: Bool
        var upscaler: String
        var showStats: Bool
        var liveWeather: Bool?
        var weather: WeatherChoice?
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            aircraftID = s.aircraftID
            airport = s.airport ?? airport
            spot = s.spot ?? spot
            fixedUTCHour = s.fixedUTCHour
            controlMode = s.controlMode
            sensitivity = min(max(s.sensitivity, 0.5), 2)
            invertPitch = s.invertPitch
            upscaler = s.upscaler
            showStats = s.showStats
            weather = s.weather ?? (s.liveWeather == false ? .clear : .live)
        }
        // `-FlightAircraft A320` (scripts and screenshots): fly that aircraft this launch.
        if let forced = defaults.string(forKey: "FlightAircraft"), !forced.isEmpty { aircraftID = forced }
        // `-FlightAirport KLAX` (scripts and screenshots): fly from that airport this launch.
        if let forced = defaults.string(forKey: "FlightAirport"), !forced.isEmpty {
            airport = forced
            spot = .runway(forced == "KLAX" ? "24R" : "08")
        }
        // `-FlightSpot final:08` (or runway:25L, stand:C12): start there this launch.
        if let forced = defaults.string(forKey: "FlightSpot") {
            let parts = forced.split(whereSeparator: { $0 == " " || $0 == ":" }).map(String.init)
            if parts.count == 2 {
                switch parts[0] {
                case "final": spot = .final(parts[1])
                case "runway": spot = .runway(parts[1])
                case "stand": spot = .stand(parts[1])
                default: break
                }
            }
        }
        // `-FlightMETAR "KPHX 081751Z 27008KT 10SM SCT050 30/05 A2992"`: fly in that weather this launch.
        forcedMetar = defaults.string(forKey: "FlightMETAR").flatMap { $0.isEmpty ? nil : $0 }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(aircraftID: aircraftID, airport: airport, spot: spot, fixedUTCHour: fixedUTCHour, controlMode: controlMode,
                       sensitivity: sensitivity, invertPitch: invertPitch, upscaler: upscaler, showStats: showStats,
                       liveWeather: nil, weather: weather)
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: Self.key) }
    }

    /// The flight's date: now, or today at the pinned UTC hour.
    public func flightDate(now: Date = Date()) -> Date {
        guard let hour = fixedUTCHour else { return now }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let midnight = cal.startOfDay(for: now)
        return midnight.addingTimeInterval(hour * 3600)
    }
}

/// Weather for a flight: the live report, or a typical day of each kind written as a METAR so it
/// flies through exactly the same path as a real one.
public enum WeatherChoice: String, Codable, CaseIterable, Sendable {
    case live, clear, few, scattered, broken, overcast, mist, fog, rain, storm

    public var label: String {
        switch self {
        case .live: "Live"
        case .clear: "Clear"
        case .few: "Few clouds"
        case .scattered: "Scattered clouds"
        case .broken: "Broken clouds"
        case .overcast: "Overcast"
        case .mist: "Mist"
        case .fog: "Fog"
        case .rain: "Rain"
        case .storm: "Thunderstorms"
        }
    }

    public var symbol: String {
        switch self {
        case .live: "antenna.radiowaves.left.and.right"
        case .clear: "sun.max.fill"
        case .few: "cloud.sun.fill"
        case .scattered, .broken: "cloud.fill"
        case .overcast: "smoke.fill"
        case .mist, .fog: "cloud.fog.fill"
        case .rain: "cloud.rain.fill"
        case .storm: "cloud.bolt.rain.fill"
        }
    }

    /// The report for this kind of day at a station, issued now; nil for live.
    public func metar(station: String, at date: Date = Date()) -> String? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.day, .hour, .minute], from: date)
        let time = String(format: "%02d%02d%02dZ", c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        let body: String
        switch self {
        case .live: return nil
        case .clear: body = "27006KT 10SM CLR 24/02 A2992"
        case .few: body = "26008KT 10SM FEW060 FEW250 24/04 A2990"
        case .scattered: body = "25010KT 10SM SCT045 SCT250 22/08 A2988"
        case .broken: body = "24012KT 10SM BKN035 BKN120 19/10 A2984"
        case .overcast: body = "23010KT 7SM OVC020 15/11 A2982"
        case .mist: body = "00000KT 3SM BR OVC008 12/11 A3001"
        case .fog: body = "00000KT 1/4SM FG VV002 10/10 A3003"
        case .rain: body = "20014G22KT 4SM -RA BKN025 OVC060 13/11 A2976"
        case .storm: body = "22018G32KT 5SM TSRA FEW035CB BKN080 OVC200 21/17 A2970"
        }
        return "\(station) \(time) \(body)"
    }
}
