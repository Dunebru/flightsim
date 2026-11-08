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
    /// Live weather from the departure airport's METAR; off is clear and calm.
    public var liveWeather = true { didSet { save() } }

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
            liveWeather = s.liveWeather ?? true
        }
        // `-FlightAircraft A320` (scripts and screenshots): fly that aircraft this launch.
        if let forced = defaults.string(forKey: "FlightAircraft"), !forced.isEmpty { aircraftID = forced }
        // `-FlightAirport KLAX` (scripts and screenshots): fly from that airport this launch.
        if let forced = defaults.string(forKey: "FlightAirport"), !forced.isEmpty {
            airport = forced
            spot = .runway(forced == "KLAX" ? "24R" : "08")
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(aircraftID: aircraftID, airport: airport, spot: spot, fixedUTCHour: fixedUTCHour, controlMode: controlMode,
                       sensitivity: sensitivity, invertPitch: invertPitch, upscaler: upscaler, showStats: showStats,
                       liveWeather: liveWeather)
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
