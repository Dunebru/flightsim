import ATC
import Autopilot
import Nav
import FlightModel
import Foundation
import Observation

/// State behind the in-flight HUD.
///
/// Prototype: the flight values are fixed demo data, not a simulation. Controls change this model
/// only. M2 connects it to the flight model and M3 replaces the demo values with live ones.
@Observable
final class HUDModel {
    nonisolated enum Panel: String, CaseIterable, Identifiable {
        case autopilot, lights, map, atc, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .autopilot: "Autopilot"
            case .lights: "Lights"
            case .map: "Map"
            case .atc: "ATC"
            case .settings: "Settings"
            }
        }
    }

    nonisolated enum Camera: String, CaseIterable, Identifiable {
        case cockpit = "Cockpit", chase = "Chase", tower = "Tower", wing = "Wing", orbit = "Free orbit"
        var id: String { rawValue }
    }

    nonisolated enum Light: String, CaseIterable, Identifiable {
        case nav = "NAV", beacon = "BCN", strobe = "STRB", landing = "LAND", taxi = "TAXI", logo = "LOGO"
        var id: String { rawValue }
    }

    // MARK: Controls

    /// Thrust lever, 0 (idle) ... 1 (max). With `reverse` on, it sets reverse thrust instead.
    var throttle: Double = 0
    /// Reverse thrust armed: the same slider then commands reverse, shown in orange.
    var reverse = false

    /// The aircraft being flown; its levers and gauges follow.
    var profile: AircraftProfile = .c172 {
        didSet {
            flapIndex = 0
            spoilerIndex = 0
        }
    }
    var flapDetents: [String] { profile.flapLabels }
    var flapIndex = 0
    /// "RPM" for piston engines, "N1" for turbines.
    var engineLabel: String { profile.isTurbine ? "N1" : "RPM" }
    let spoilerDetents = ["RET", "ARM", "½", "FULL"]
    var spoilerIndex = 0

    nonisolated enum Gear: Equatable { case up, transit(toDown: Bool), down }
    var gear: Gear = .down
    /// Time for the gear to travel, seconds.
    static let gearTravelTime: Duration = .seconds(6)
    private var gearTask: Task<Void, Never>?

    var parkingBrake = true
    /// Elevator trim, -1 (nose down) ... 1 (nose up).
    var trim: Double = 0
    var lights: Set<Light> = [.nav, .beacon]
    var camera: Camera = .chase
    var paused = false
    var openPanel: Panel?

    // MARK: Autopilot targets (pilot-selected, shown cyan)

    var apMaster = false
    var autothrottle = false
    var locArmed = false
    var approachArmed = false
    var targetSpeed = 250
    var targetHeading = 271
    var targetAltitude = 5_000
    var targetVerticalSpeed = 1_500
    /// What the autopilot is doing (flight mode annunciations) and the approach it would fly.
    var apLateral = ""
    var apVertical = ""
    var apApproach: String?

    // MARK: Navigation (the map and NAV)

    /// Aircraft position and ground track (degrees true), updated ten times a second.
    var latitude = 0.0
    var longitude = 0.0
    var track = 0.0
    /// The route the pilot drew on the map, and whether NAV flies it.
    var route: [NavPoint] = []
    var navEngaged = false
    /// The point NAV is flying to and how far it is (metres); nil past the end of the route.
    var activeWaypoint: Int?
    var distanceToActive: Double?
    /// Airports to fly direct to.
    var airports: [NavPoint] = []
    /// Navaids and fixes for the map.
    var navData: NavData?

    // MARK: ATC

    /// The calls that make sense now, what has been said, and how to say one.
    var atcRequests: [ATCRequest] = []
    var atcLog: [ATCMessage] = []
    var onATC: ((ATCRequest) -> Void)?

    // MARK: Flight data (live from the flight model on iOS; zero elsewhere)

    var indicatedAirspeed = 0
    var groundSpeed = 0
    var altitude = 0
    var verticalSpeed = 0
    var heading = 90
    var angleOfAttack = 0.0
    var n1 = 0.0
    var stallWarning = false
    /// Wind at the aircraft: from (degrees true), speed and gust (knots), and the direction it
    /// blows relative to the nose (degrees, for the HUD arrow).
    var windFrom = 0
    var windKnots = 0
    var windGust: Int?
    var windRelative = 0.0
    var weatherSource = "Clear skies"

    // MARK: Pilot inputs from on-screen controls

    /// On-screen stick, -1...1 (pitch + is nose up).
    var stickPitch = 0.0
    var stickRoll = 0.0
    /// Wheel brakes held.
    var wheelBrakes = false

    // MARK: Behavior

    func setThrottle(_ value: Double) {
        throttle = min(max(value, 0), 1)
    }

    /// Arming or disarming reverse brings the lever to idle first, as on the real aircraft.
    func toggleReverse() {
        throttle = 0
        reverse.toggle()
    }

    func toggleGear() {
        guard profile.retractableGear else { return }
        let toDown: Bool
        switch gear {
        case .up: toDown = true
        case .down: toDown = false
        case .transit(let wasDown): toDown = !wasDown
        }
        gear = .transit(toDown: toDown)
        gearTask?.cancel()
        gearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.gearTravelTime)
            guard !Task.isCancelled, let self else { return }
            self.gear = toDown ? .down : .up
        }
    }

    func toggle(_ panel: Panel) {
        openPanel = openPanel == panel ? nil : panel
    }

    func toggle(_ light: Light) {
        if lights.contains(light) { lights.remove(light) } else { lights.insert(light) }
    }

    func nudgeTrim(_ delta: Double) {
        trim = min(max(trim + delta, -1), 1)
    }
}
