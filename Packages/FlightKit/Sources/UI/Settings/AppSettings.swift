public import Foundation
import Observation
import Renderer

/// How the pilot flies.
public enum ControlMode: String, Codable, CaseIterable, Sendable {
    /// Tilt the phone (primary).
    case tilt
    /// On-screen stick.
    case stick
}

/// Where a free flight starts. KPHX only until airports are generated from data (M5).
public enum StartPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case kphxRunway08 = "KPHX 08"
    case kphxRunway26 = "KPHX 26"
    case kphxFinal08 = "KPHX 08, 3 nm final"

    public var id: String { rawValue }

    /// Scene ENU position (metres), true heading (degrees), height above ground (feet),
    /// airspeed (knots).
    public var placement: (position: SIMD3<Double>, heading: Double, heightFeet: Double, knots: Double) {
        let hdg = PhoenixSite.runwayHeading, half = PhoenixSite.runwayLength / 2
        switch self {
        case .kphxRunway08: return (PhoenixSite.centreline(-half + 51), hdg, 0, 0)
        case .kphxRunway26: return (PhoenixSite.centreline(half - 51), hdg + 180, 0, 0)
        // 3 nm (5,556 m) from the runway 08 threshold on a 3 degree glide path: about 950 ft.
        case .kphxFinal08: return (PhoenixSite.centreline(-half - 5_556), hdg, 950, 0)
        }
    }
}

/// Settings that persist across launches (UserDefaults, one JSON value).
@Observable
public final class AppSettings {
    public var aircraftID = "c172p" { didSet { save() } }
    public var start: StartPosition = .kphxRunway08 { didSet { save() } }
    /// nil: real time. Otherwise the UTC hour (0-23.99) pinned for the flight.
    public var fixedUTCHour: Double? = nil { didSet { save() } }
    public var controlMode: ControlMode = .tilt { didSet { save() } }
    /// Multiplies deflection: 0.5 gentle ... 2.0 sharp.
    public var sensitivity: Double = 1.0 { didSet { save() } }
    public var invertPitch = false { didSet { save() } }
    public var upscaler = "temporal" { didSet { save() } }
    public var showStats = false { didSet { save() } }

    private let defaults: UserDefaults
    private var loading = false
    static let key = "FlightSettings.v1"

    private struct Stored: Codable {
        var aircraftID: String
        var start: StartPosition
        var fixedUTCHour: Double?
        var controlMode: ControlMode
        var sensitivity: Double
        var invertPitch: Bool
        var upscaler: String
        var showStats: Bool
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            aircraftID = s.aircraftID
            start = s.start
            fixedUTCHour = s.fixedUTCHour
            controlMode = s.controlMode
            sensitivity = min(max(s.sensitivity, 0.5), 2)
            invertPitch = s.invertPitch
            upscaler = s.upscaler
            showStats = s.showStats
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Stored(aircraftID: aircraftID, start: start, fixedUTCHour: fixedUTCHour, controlMode: controlMode,
                       sensitivity: sensitivity, invertPitch: invertPitch, upscaler: upscaler, showStats: showStats)
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
