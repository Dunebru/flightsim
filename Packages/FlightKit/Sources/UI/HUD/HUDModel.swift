import Foundation
import Observation

/// State behind the in-flight HUD.
///
/// Prototype: the flight values are fixed demo data, not a simulation. Controls change this model
/// only. M2 connects it to the flight model and M3 replaces the demo values with live ones.
@Observable
final class HUDModel {
    enum Panel: String, CaseIterable, Identifiable {
        case autopilot = "AP"
        case map = "MAP"
        case atc = "ATC"
        case camera = "CAM"
        case lights = "LTS"
        case settings = "SET"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .autopilot: "Autopilot"
            case .map: "Map"
            case .atc: "ATC"
            case .camera: "Camera"
            case .lights: "Lights"
            case .settings: "Settings"
            }
        }
    }

    enum Camera: String, CaseIterable, Identifiable {
        case cockpit = "Cockpit", chase = "Chase", tower = "Tower", wing = "Wing", orbit = "Free orbit"
        var id: String { rawValue }
    }

    enum Light: String, CaseIterable, Identifiable {
        case nav = "NAV", beacon = "BCN", strobe = "STRB", landing = "LAND", taxi = "TAXI", logo = "LOGO"
        var id: String { rawValue }
    }

    // MARK: Controls

    /// Thrust lever, -0.25 (full reverse) ... 0 (idle) ... 1 (max).
    var throttle: Double = 0.72
    static let throttleRange: ClosedRange<Double> = -0.25...1
    /// Below idle, how far the lever must be pulled before reverse engages (the idle gate).
    static let reverseGate: Double = 0.06

    let flapDetents = ["UP", "1", "2", "3", "FULL"]
    var flapIndex = 1
    let spoilerDetents = ["RET", "ARM", "½", "FULL"]
    var spoilerIndex = 0

    enum Gear: Equatable { case up, transit(toDown: Bool), down }
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

    /// Applies a lever position from a drag, enforcing the idle gate: from forward thrust the
    /// lever stops at idle unless pulled past the gate into reverse.
    func setThrottle(_ proposed: Double) {
        let clamped = min(max(proposed, Self.throttleRange.lowerBound), Self.throttleRange.upperBound)
        if throttle >= 0, clamped < 0, clamped > -Self.reverseGate {
            throttle = 0
        } else {
            throttle = clamped
        }
    }

    var isReverse: Bool { throttle < 0 }

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
