#if os(iOS)
import FlightModel
import Foundation
import Renderer
import SimCore

/// One flight: the physics loop for the chosen aircraft, its control inputs, and the mapping from
/// its state to the scene and the HUD. Lives on the main actor; physics runs on its own thread.
final class FlightSession {
    let profile: AircraftProfile
    private(set) var physics: PhysicsLoop?
    private(set) var error: String?
    let frame: LocalFrame
    let tilt = TiltInput()
    let gamepad = GamepadInput()

    /// Spawn point: runway 8 threshold area at KPHX, in the scene's ENU frame (metres).
    static let spawn = SIMD3<Double>(-1_700, 0, 0)
    static let spawnHeading = 90.0
    private var lastHUDUpdate: TimeInterval = 0

    init(profile: AircraftProfile, origin: Geodetic) {
        self.profile = profile
        frame = LocalFrame(origin: origin)
        do {
            physics = try PhysicsLoop(model: profile.id, initial: spawnConditions())
        } catch {
            self.error = String(describing: error)
        }
        tilt.start()
    }

    isolated deinit {
        physics?.stop()
        tilt.stop()
    }

    func spawnConditions() -> InitialConditions {
        let g = frame.geodetic(Self.spawn)
        return InitialConditions(latitude: g.latitude, longitude: g.longitude,
                                 terrainElevationFeet: frame.origin.height / 0.3048,
                                 heightAboveGroundFeet: 0, headingDegrees: Self.spawnHeading, airspeedKnots: 0)
    }

    func resetToRunway(hud: HUDModel) {
        physics?.send(.reset(spawnConditions()))
        hud.setThrottle(0)
        hud.parkingBrake = true
        tilt.calibrate()
    }

    /// Called once per display frame, before rendering.
    func tick(dt: Double, hud: HUDModel, scene: inout SceneDescription) {
        guard let physics else { return }

        var inputs = ControlInputs()
        if let pad = gamepad.read() {
            inputs.pitch = pad.pitch
            inputs.roll = pad.roll
            inputs.yaw = pad.yaw
            if pad.throttleRate != 0 { hud.setThrottle(hud.throttle + pad.throttleRate * dt) }
        } else if let t = tilt.read() {
            inputs.pitch = t.pitch
            inputs.roll = t.roll
        }
        inputs.throttle = hud.throttle
        inputs.reverse = hud.reverse
        inputs.flaps = profile.flapCommands[min(hud.flapIndex, profile.flapCommands.count - 1)]
        inputs.spoilers = profile.hasSpoilers ? [0, 0, 0.5, 1][min(hud.spoilerIndex, 3)] : 0
        switch hud.gear {
        case .down: inputs.gearDown = true
        case .up: inputs.gearDown = false
        case .transit(let toDown): inputs.gearDown = toDown
        }
        if !profile.retractableGear { inputs.gearDown = true }
        inputs.parkingBrake = hud.parkingBrake
        inputs.pitchTrim = hud.trim
        physics.setInputs(inputs)
        physics.setPaused(hud.paused)

        let s = physics.state
        // Position: ENU from latitude/longitude; height from the ground so the wheels rest on
        // the drawn runway when the aircraft is on its gear.
        let enu = frame.enu(Geodetic(latitude: s.latitude, longitude: s.longitude, height: frame.origin.height))
        let height = max(0, (s.heightAboveGroundFeet - physics.restingHeightFeet) * 0.3048)
        scene.aircraftPosition = SIMD3(enu.x, enu.y, height)
        scene.aircraftHeading = s.heading
        scene.aircraftRoll = s.roll
        scene.aircraftPitch = s.pitch

        let now = Date.timeIntervalSinceReferenceDate
        if now - lastHUDUpdate > 0.1 {
            lastHUDUpdate = now
            hud.indicatedAirspeed = Int(s.indicatedAirspeedKnots.rounded())
            hud.groundSpeed = Int(s.groundSpeedKnots.rounded())
            hud.altitude = Int((s.altitudeFeet / 10).rounded() * 10)
            hud.verticalSpeed = Int((s.verticalSpeedFPM / 10).rounded() * 10)
            var hdg = Int((s.heading * 180 / .pi).rounded()) % 360
            if hdg <= 0 { hdg += 360 }
            hud.heading = hdg
            hud.angleOfAttack = s.onGround ? 0 : s.angleOfAttackDegrees
            hud.n1 = s.engineIndication
        }
    }
}
#endif
