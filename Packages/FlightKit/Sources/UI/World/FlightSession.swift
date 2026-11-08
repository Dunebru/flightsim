#if os(iOS)
import Airports
import FlightModel
import Foundation
import Renderer
import SimCore
import Terrain
import Weather

/// One flight: the physics loop for the chosen aircraft, its control inputs, and the mapping from
/// its state to the scene and the HUD. Lives on the main actor; physics runs on its own thread.
final class FlightSession {
    let profile: AircraftProfile
    private(set) var physics: PhysicsLoop?
    private(set) var error: String?
    let frame: LocalFrame
    let tilt = TiltInput()
    let gamepad = GamepadInput()

    let site: AirportSite
    let spot: StartSpot
    let placement: StartPlacement
    let settings: AppSettings
    /// Solid ground under the aircraft, from the same scenery the renderer draws.
    private var ground: GroundModel
    private var lastHUDUpdate: TimeInterval = 0
    /// The weather the flight uses (clear until a METAR arrives).
    var weather: WeatherConditions = .clear
    private var clock = 0.0
    private var lastState: FlightState?

    /// - Parameters:
    ///   - site: the departure airport; its frame is the scene frame.
    ///   - overrides: every airport's ground overrides in that frame (physics stands on them).
    init(profile: AircraftProfile, site: AirportSite, spot: StartSpot, settings: AppSettings, scenery: SceneryLibrary?,
         overrides: [GroundOverride]) {
        self.profile = profile
        self.site = site
        self.settings = settings
        let first = site.startSpots.first ?? .runway("")
        self.spot = site.placement(spot) == nil ? first : spot
        placement = site.placement(spot) ?? site.placement(first) ?? StartPlacement(position: .zero, heading: 0, altitude: nil)
        frame = site.frame
        ground = GroundModel(scenery: scenery, frame: frame, flatten: overrides)
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

    var isAirborneStart: Bool { placement.altitude != nil }

    func spawnConditions() -> InitialConditions {
        let p = placement
        let g = frame.geodetic(p.position)
        let terrain = ground.height(latitude: g.latitude, longitude: g.longitude)
        let agl = p.altitude.map { max(($0 - terrain) / 0.3048, 50) } ?? 0
        var ic = InitialConditions(latitude: g.latitude, longitude: g.longitude,
                                   terrainElevationFeet: terrain / 0.3048,
                                   heightAboveGroundFeet: agl, headingDegrees: p.heading,
                                   airspeedKnots: isAirborneStart ? profile.approachKnots : 0)
        if isAirborneStart {
            ic.flaps = profile.flapCommands[min(profile.approachFlapIndex, profile.flapCommands.count - 1)]
            ic.gearDown = true
        }
        return ic
    }

    /// Sets the HUD levers to match the start: idle and parked on the runway, or configured
    /// for the approach on final.
    func configureHUD(_ hud: HUDModel) {
        hud.reverse = false
        if isAirborneStart {
            hud.setThrottle(profile.isTurbine ? 0.45 : 0.45)
            hud.parkingBrake = false
            hud.flapIndex = min(profile.approachFlapIndex, profile.flapCommands.count - 1)
        } else {
            hud.setThrottle(0)
            hud.parkingBrake = true
            hud.flapIndex = 0
        }
        hud.gear = .down
    }

    func resetToStart(hud: HUDModel) {
        physics?.send(.reset(spawnConditions()))
        if isAirborneStart { physics?.send(.trim) }
        configureHUD(hud)
        tilt.calibrate()
    }

    /// Weather for the flight model at a height above the ground: the profiled wind with gusts
    /// (a smooth random swing between the steady speed and the reported gust), turbulence when
    /// it is gusty or strong, and the temperature and pressure.
    func atmosphere(heightFeet: Double) -> AtmosphereInputs {
        var a = AtmosphereInputs()
        var wind = weather.wind(atHeightFeet: heightFeet)
        if let gust = weather.gustKnots, weather.windKnots > 0 {
            let t = clock
            let swing = 0.5 + 0.25 * sin(t * 0.71) + 0.15 * sin(t * 1.93 + 1.1) + 0.1 * sin(t * 3.7 + 2.3)
            wind *= 1 + (gust / weather.windKnots - 1) * max(0, min(1, swing))
        }
        a.windNorthKnots = wind.x
        a.windEastKnots = wind.y
        a.surfaceWindKnots = weather.windKnots
        let spread = (weather.gustKnots ?? weather.windKnots) - weather.windKnots
        a.turbulenceSeverity = spread >= 10 ? 4 : (spread >= 5 || weather.windKnots >= 15 ? 3 : (weather.windKnots >= 8 ? 2 : 0))
        a.deltaTCelsius = weather.isaDeviation(fieldElevationMetres: site.layout.elevation)
        a.seaLevelPressureHPa = weather.altimeterHPa
        return a
    }

    /// Called once per display frame, before rendering.
    func tick(dt: Double, hud: HUDModel, scene: inout SceneDescription, holdForScenery: Bool = false) {
        guard let physics else { return }

        var inputs = ControlInputs()
        if let pad = gamepad.read() {
            inputs.pitch = pad.pitch
            inputs.roll = pad.roll
            inputs.yaw = pad.yaw
            if pad.throttleRate != 0 { hud.setThrottle(hud.throttle + pad.throttleRate * dt) }
        } else if settings.controlMode == .stick {
            inputs.pitch = hud.stickPitch
            inputs.roll = hud.stickRoll
        } else if let t = tilt.read() {
            inputs.pitch = t.pitch
            inputs.roll = t.roll
        }
        // Pilot preferences: sensitivity scales deflection; invert flips pitch.
        inputs.pitch = max(-1, min(1, inputs.pitch * settings.sensitivity * (settings.invertPitch ? -1 : 1)))
        inputs.roll = max(-1, min(1, inputs.roll * settings.sensitivity))
        // On the ground, tilt also steers the nosewheel (and rudder), fading out by 60 kt.
        if let last = lastState, last.onGround {
            let blend = max(0, 1 - last.groundSpeedKnots / 60)
            inputs.yaw = max(-1, min(1, inputs.yaw + inputs.roll * blend))
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
        inputs.brakes = hud.wheelBrakes ? 1 : 0
        inputs.pitchTrim = hud.trim
        physics.setInputs(inputs)
        physics.setPaused(hud.paused || holdForScenery)
        clock += dt
        if let s = lastState { physics.setAtmosphere(atmosphere(heightFeet: s.heightAboveGroundFeet)) }

        let s = physics.state
        lastState = s
        let warn = !s.onGround && s.angleOfAttackDegrees > profile.stallWarningAlpha && s.indicatedAirspeedKnots > 20
        if warn != hud.stallWarning { hud.stallWarning = warn }
        // The ground under the aircraft, from the scenery: physics treats it as solid, and the
        // aircraft is drawn at its height above it, so the wheels rest on the drawn surface.
        let groundHeight = ground.height(latitude: s.latitude, longitude: s.longitude)
        physics.setTerrainElevation(feet: groundHeight / 0.3048)
        let base = frame.enu(Geodetic(latitude: s.latitude, longitude: s.longitude, height: groundHeight))
        let height = max(0, (s.heightAboveGroundFeet - physics.restingHeightFeet) * 0.3048)
        scene.aircraftPosition = SIMD3(base.x, base.y, base.z + height)
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
            hud.windFrom = Int(weather.windFromDegrees.rounded())
            hud.windKnots = Int(weather.windKnots.rounded())
            hud.windGust = weather.gustKnots.map { Int($0.rounded()) }
            hud.windRelative = weather.windFromDegrees + 180 - s.heading * 180 / .pi
            hud.weatherSource = weather.source
        }
    }
}
#endif
