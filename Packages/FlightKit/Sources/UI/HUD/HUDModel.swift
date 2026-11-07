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
    var throttle: Double = 0.72
    /// Reverse thrust armed: the same slider then commands reverse, shown in orange.
    var reverse = false

    let flapDetents = ["UP", "1", "2", "3", "FULL"]
    var flapIndex = 1
    let spoilerDetents = ["RET", "ARM", "½", "FULL"]
    var spoilerIndex = 0

    nonisolated enum Gear: Equatable { case up, transit(toDown: Bool), down }
    var gear: Gear = .down
    /// Time for the gear to travel, seconds.
    static let gearTravelTime: Duration = .seconds(6)
    private var gearTask: Task<Void, Never>?

    var parkingBrake = false
    /// Elevator trim, -1 (nose down) ... 1 (nose up).
    var trim: Double = 0.12
    var lights: Set<Light> = [.nav, .beacon]
    var camera: Camera = .chase
    var paused = false
    var openPanel: Panel?

    // MARK: Autopilot targets (pilot-selected, shown cyan)

    var apMaster = true
    var autothrottle = true
    var locArmed = false
    var approachArmed = false
    var targetSpeed = 250
    var targetHeading = 271
    var targetAltitude = 5_000
    var targetVerticalSpeed = 1_500

    // MARK: Demo flight data (prototype: fixed numbers, not simulated)

    var indicatedAirspeed = 142
    var groundSpeed = 151
    var altitude = 2_350
    var verticalSpeed = 1_200
    var heading = 271
    var angleOfAttack = 4.2
    var n1 = 84.2

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
