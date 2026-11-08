#if os(iOS)
import Aircraft
import Airports
import FlightModel
import Foundation
import Renderer
import SimCore
import Terrain
import Weather
import ATC
import Autopilot
import Nav
import Traffic

/// One flight: the physics loop for the chosen aircraft, its control inputs, and the mapping from
/// its state to the scene and the HUD. Lives on the main actor; physics runs on its own thread.
final class FlightSession {
    let profile: AircraftProfile
    private(set) var physics: PhysicsLoop?
    let autopilot: Autopilot
    /// ILS approaches at this airport (every runway end with one).
    let approaches: [ApproachPath]
    private var appliedAutopilot = AutopilotSettings()
    /// Magnetic declination here (degrees east): headings shown and selected are magnetic, as
    /// runways are numbered and pilots fly; the flight model works in true.
    private(set) var declination: Double
    /// AI traffic at the departure airport, once built (off the main thread: the taxiway graph
    /// and a warm-up take a moment).
    private var traffic: AirportTraffic?
    /// ATC at the departure airport, and the voice that speaks it.
    let atc: ATCController
    private let voice = ATCVoice()
    /// Engine, wind and rolling sound.
    private let audio = FlightAudio()
    private var wasOnGround = true
    /// Calls made by a launch argument (scripts), once traffic is ready.
    var scriptedATC: [ATCRequest] = []
    private var lastScripted = 0.0
    /// Where the aircraft is on the airport (airport frame), from the last frame.
    private var lastPosition = SIMD2<Double>.zero
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
    var weather: WeatherConditions = .clear {
        didSet {
            traffic?.setWind(fromDegrees: weather.windFromDegrees, knots: weather.windKnots)
            cloudLayers = weather.cloudVolumes(fieldElevationMetres: site.layout.elevation).map { v in
                let kind: CloudLayer.Kind = switch v.kind {
                case .stratus: .stratus
                case .cumulus: .cumulus
                case .cumulonimbus: .cumulonimbus
                case .cirrus: .cirrus
                }
                return CloudLayer(baseMetres: v.baseMetres, topMetres: v.topMetres, coverage: v.coverage, kind: kind)
            }
        }
    }
    private var cloudLayers: [CloudLayer] = []

    /// Builds the airport's traffic in the background, already under way.
    private func startTraffic() {
        let site = self.site
        let stand: String? = if case .stand(let ref) = spot { ref } else { nil }
        let wind = (weather.windFromDegrees, weather.windKnots)
        Task.detached(priority: .utility) {
            let t = AirportTraffic(site: site, excludingStand: stand, windFromDegrees: wind.0, windKnots: wind.1,
                                   seed: UInt64(Date().timeIntervalSince1970))
            t.warmUp(seconds: 900)
            await MainActor.run { [weak self] in self?.traffic = t }
        }
    }
    private var clock = 0.0
    private var lastState: FlightState?
    private var crash: CrashCheck?
    private var crashCheckAfter = 1.5

    /// What the C172's needles, yoke and pedals show, by FlightGear property.
    static func cockpitReadings(_ s: FlightState, inputs: ControlInputs, declination: Double, headingBug: Double) -> [String: Double] {
        typealias P = C172Model.Property
        let magnetic = (s.heading * 180 / .pi - declination + 360).truncatingRemainder(dividingBy: 360)
        let seconds = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date()))
        let surfaces = C172Model.surfaceReadings(leftAileron: s.leftAileron, rightAileron: s.rightAileron, elevator: s.elevator,
                                                 rudder: s.rudder)
        return surfaces.merging([
            P.airspeed: s.indicatedAirspeedKnots,
            P.pitch: s.pitch * 180 / .pi,
            P.roll: s.roll * 180 / .pi,
            P.altitude: s.altitudeFeet,
            P.heading: magnetic,
            P.compass: magnetic,
            P.headingBug: headingBug,
            P.verticalSpeed: s.verticalSpeedFPM,
            // Standard rate (3 degrees a second) is one unit.
            P.turnRate: s.yawRate * 180 / .pi / 3,
            // The ball follows the sideslip (FlightGear's is ten times lateral over normal acceleration).
            P.slipSkid: -s.sideslipDegrees * 0.6,
            P.rpm: s.engineIndication,
            P.flaps: s.flapPosition,
            P.yokeAileron: inputs.roll,
            P.yokeElevator: -inputs.pitch,
            P.pedals: inputs.yaw,
            P.throttle: inputs.throttle,
            P.clock: seconds,
            P.elevatorTrim: inputs.pitchTrim,
            P.noseSteering: s.noseSteeringDegrees,
            // FlightGear calls it compression-norm but feeds it feet.
            "gear/gear[0]/compression-norm": s.gearCompressionFeet[0],
            "gear/gear[1]/compression-norm": s.gearCompressionFeet[1],
            "gear/gear[2]/compression-norm": s.gearCompressionFeet[2],
        ]) { a, _ in a }
    }

    /// - Parameters:
    ///   - site: the departure airport; its frame is the scene frame.
    ///   - overrides: every airport's ground overrides in that frame (physics stands on them).
    init(profile: AircraftProfile, site: AirportSite, spot: StartSpot, settings: AppSettings, scenery: SceneryLibrary?,
         overrides: [GroundOverride]) {
        self.profile = profile
        self.site = site
        self.settings = settings
        autopilot = Autopilot(gains: .forModel(profile.id))
        declination = MagneticModel.declination(latitude: site.layout.reference.lat, longitude: site.layout.reference.lon,
                                                year: MagneticModel.year(of: Date()))
        approaches = ApproachCatalog.approaches(at: site)
        let names = Self.facilities(site.layout.icao)
        atc = ATCController(city: names.city, approachFacility: names.approach,
                            callsign: profile.isTurbine ? "Flight 214" : "N172SP",
                            spokenCallsign: profile.isTurbine ? "flight two one four" : "Cessna one seven two sierra papa")
        let first = site.startSpots.first ?? .runway("")
        self.spot = site.placement(spot) == nil ? first : spot
        placement = site.placement(spot) ?? site.placement(first) ?? StartPlacement(position: .zero, heading: 0, altitude: nil)
        frame = site.frame
        ground = GroundModel(scenery: scenery, frame: frame, flatten: overrides)
        do {
            physics = try PhysicsLoop(model: profile.id, initial: spawnConditions())
            physics?.setController(autopilot)
            startTraffic()
            audio.start()
        } catch {
            self.error = String(describing: error)
        }
        tilt.start()
    }

    isolated deinit {
        audio.stop()
        physics?.stop()
        tilt.stop()
    }

    var isAirborneStart: Bool { placement.altitude != nil }

    func spawnConditions() -> InitialConditions {
        let p = placement
        var at = p.position
        if case .stand = spot {
            // A stand's point is where the nose wheel stops (the end of the lead-in line); the
            // flight model's position is its centre of gravity, behind that.
            let h = p.heading * .pi / 180
            at -= SIMD3(sin(h), cos(h), 0) * profile.noseWheelAheadOfCG
        }
        let g = frame.geodetic(at)
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
        // Autopilot off, with targets that make sense for this start: the runway heading, a
        // pattern-ish altitude or the approach's, and the aircraft's usual speeds and rates.
        hud.apMaster = false
        hud.autothrottle = false
        hud.locArmed = false
        hud.approachArmed = false
        var heading = Int((placement.heading - declination).rounded()) % 360
        if heading <= 0 { heading += 360 }
        hud.targetHeading = heading
        let field = site.layout.elevation * 3.280_84
        let altitude = placement.altitude.map { $0 * 3.280_84 } ?? field + 3_000
        hud.targetAltitude = Int((altitude / 100).rounded()) * 100
        hud.targetSpeed = isAirborneStart ? Int(profile.approachKnots) : (profile.isTurbine ? 250 : 100)
        hud.targetVerticalSpeed = profile.isTurbine ? 1_800 : 700
    }

    func resetToStart(hud: HUDModel) {
        crash?.reset()
        hud.crashMessage = nil
        crashCheckAfter = clock + 1.5        // the reset reaches the physics thread a frame or two later
        physics?.send(.reset(spawnConditions()))
        if isAirborneStart { physics?.send(.trim) }
        configureHUD(hud)
        tilt.calibrate()
    }

    /// Weather for the flight model at a height above the ground: the profiled wind with gusts
    /// (a smooth random swing between the steady speed and the reported gust), turbulence when
    /// it is gusty or strong, and the temperature and pressure.
    func atmosphere(heightFeet: Double, altitudeFeet: Double) -> AtmosphereInputs {
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
        a.turbulenceSeverity = weather.turbulenceSeverity(altitudeMetres: altitudeFeet * 0.3048,
                                                          fieldElevationMetres: site.layout.elevation)
        a.deltaTCelsius = weather.isaDeviation(fieldElevationMetres: site.layout.elevation)
        a.seaLevelPressureHPa = weather.altimeterHPa
        return a
    }

    /// Called once per display frame, before rendering.
    func tick(dt: Double, hud: HUDModel, scene: inout SceneDescription, holdForScenery: Bool = false) {
        guard let physics else { return }
        scene.clouds = cloudLayers
        lastPosition = SIMD2(scene.aircraftPosition.x, scene.aircraftPosition.y)
        if let s = lastState {
            var sound = SoundParameters()
            sound.piston = !s.engineIsTurbine
            sound.rpm = s.engineIsTurbine ? 0 : s.engineIndication
            sound.n1 = s.engineIsTurbine ? s.engineIndication : 0
            sound.throttle = s.throttle
            sound.airspeedKnots = s.trueAirspeedKnots
            sound.groundSpeedKnots = s.groundSpeedKnots
            sound.onGround = s.onGround
            sound.stallWarning = hud.stallWarning
            sound.exterior = hud.camera != .cockpit
            sound.reverser = s.reverser
            audio.update(sound)
            if s.onGround && !wasOnGround && s.verticalSpeedFPM < -80 { audio.touchdown(-s.verticalSpeedFPM / 600) }
            wasOnGround = s.onGround
        }
        if let traffic, let s = lastState {
            traffic.player = (lastPosition, s.onGround)
            if let eye = scene.cameraPose?.position { traffic.viewer = SIMD2(eye.x, eye.y) }
            traffic.update(dt: min(dt, 0.1))
            var moving = TrafficInstances(narrow: [], wide: [])
            for a in traffic.snapshot {
                let v = SIMD8<Float>(Float(a.position.x), Float(a.position.y), Float(a.position.z), Float(a.heading),
                                     Float(a.seed), Float(a.pitch), Float(a.roll), Float(a.lights))
                if a.widebody { moving.wide.append(v) } else { moving.narrow.append(v) }
            }
            scene.traffic = [site.layout.icao: moving]
        }
        scene.cloudWind = weather.windVectorMetresPerSecond(atHeightFeet: 5_000)
        scene.visibilityMetres = weather.visibilityMetres
        scene.fogScaleHeight = weather.fogScaleHeightMetres
        scene.precipitation = weather.precipitation.map { p in
            Precipitation(kind: p.kind == .snow ? .snow : (p.kind == .drizzle ? .drizzle : .rain), intensity: p.intensity)
        }
        scene.wetness = scene.precipitation.map { $0.kind == .snow ? 0.3 : min(1, 0.5 + $0.intensity) } ?? 0

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
        // The rudder slider (a gamepad's own rudder wins).
        if gamepad.read() == nil { inputs.yaw = hud.rudder }
        // On the ground, tilt also steers the nosewheel (and rudder), fading out by 60 kt.
        if let last = lastState, last.onGround {
            let blend = max(0, 1 - last.groundSpeedKnots / 60)
            inputs.yaw = max(-1, min(1, inputs.yaw + inputs.roll * blend))
        }
        inputs.throttle = hud.throttle
        inputs.reverse = hud.reverse
        flyAutopilot(hud: hud)
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
        physics.setPaused(hud.paused || holdForScenery || hud.crashMessage != nil)
        clock += dt
        if let s = lastState { physics.setAtmosphere(atmosphere(heightFeet: s.heightAboveGroundFeet, altitudeFeet: s.altitudeFeet)) }

        let s = physics.state
        lastState = s
        if crash == nil, physics.restingHeightFeet > 0 { crash = CrashCheck(restingHeightFeet: physics.restingHeightFeet) }
        if hud.crashMessage == nil, clock > crashCheckAfter, let reason = crash?.update(s) { hud.crashMessage = reason }
        let warn = !s.onGround && s.angleOfAttackDegrees > profile.stallWarningAlpha && s.indicatedAirspeedKnots > 20
        if warn != hud.stallWarning { hud.stallWarning = warn }
        // The ground under the aircraft, from the scenery: physics treats it as solid, and the
        // aircraft is drawn at its height above it, so the wheels rest on the drawn surface.
        let groundHeight = ground.height(latitude: s.latitude, longitude: s.longitude)
        physics.setTerrainElevation(feet: groundHeight / 0.3048)
        let base = frame.enu(Geodetic(latitude: s.latitude, longitude: s.longitude, height: groundHeight))
        // Drawn from the centre of gravity down: the model's extended-gear ground plane sits
        // `cgAboveMainGear` below it, and the struts' compression lifts the wheels back onto
        // the surface (so they neither float nor sink).
        let pivot = profile.cgAboveMainGear
        scene.aircraftPivotHeight = pivot
        scene.aircraftPosition = SIMD3(base.x, base.y, base.z + s.heightAboveGroundFeet * 0.3048 - pivot)
        scene.aircraftHeading = s.heading
        scene.aircraftGearDown = s.gearPosition > 0.5
        scene.propellerSpinning = !s.engineIsTurbine && s.engineIndication > 400
        if s.engineIsTurbine {
            scene.instrumentValues = A320Model.readings(
                leftAileron: s.leftAileronDegrees, rightAileron: s.rightAileronDegrees, elevator: s.elevatorDegrees,
                rudder: s.rudderDegrees, flaps: s.flapPosition, speedbrake: s.speedbrake, steering: s.noseSteeringDegrees,
                gear: s.gearPosition, compression: s.gearCompressionFeet, wheelSpeed: s.wheelSpeed, n1: s.engineIndication,
                reverser: s.reverser)
        } else {
            scene.instrumentValues = Self.cockpitReadings(s, inputs: inputs, declination: declination, headingBug: Double(hud.targetHeading))
        }
        scene.aircraftRoll = s.roll
        scene.aircraftPitch = s.pitch

        let now = Date.timeIntervalSinceReferenceDate
        if now - lastHUDUpdate > 0.1 {
            lastHUDUpdate = now
            hud.indicatedAirspeed = Int(s.indicatedAirspeedKnots.rounded())
            hud.groundSpeed = Int(s.groundSpeedKnots.rounded())
            hud.altitude = Int((s.altitudeFeet / 10).rounded() * 10)
            hud.verticalSpeed = Int((s.verticalSpeedFPM / 10).rounded() * 10)
            declination = MagneticModel.declination(latitude: s.latitude, longitude: s.longitude,
                                                    year: MagneticModel.year(of: Date()))
            var hdg = Int((s.heading * 180 / .pi - declination).rounded()) % 360
            if hdg <= 0 { hdg += 360 }
            hud.heading = hdg
            hud.angleOfAttack = s.onGround ? 0 : s.angleOfAttackDegrees
            hud.n1 = s.engineIndication
            hud.windFrom = Int(weather.windFromDegrees.rounded())
            hud.windKnots = Int(weather.windKnots.rounded())
            hud.windGust = weather.gustKnots.map { Int($0.rounded()) }
            hud.windRelative = weather.windFromDegrees + 180 - s.heading * 180 / .pi
            hud.weatherSource = weather.source
            let st = autopilot.status
            hud.apLateral = st.lateral.rawValue
            hud.apVertical = st.vertical.rawValue
            hud.apApproach = appliedAutopilot.approach?.name
            hud.latitude = s.latitude
            hud.longitude = s.longitude
            hud.track = s.track * 180 / .pi
            hud.activeWaypoint = st.activeWaypoint
            hud.distanceToActive = st.distanceToActiveMetres
            // The thrust lever follows the autothrottle, as on the real aircraft, and stays where
            // it left it when the autothrottle is switched off.
            if st.autothrottle { hud.setThrottle(s.throttle) }
            if let traffic, let situation = atcSituation(s) {
                hud.atcRequests = atc.requests(situation, traffic: traffic)
                if let next = scriptedATC.first, clock - lastScripted > 2 {
                    scriptedATC.removeFirst()
                    lastScripted = clock
                    sayATC(next, hud: hud)
                }
            }
        }
    }

    /// Facility names: the city controllers use, and the approach control's.
    static func facilities(_ icao: String) -> (city: String, approach: String) {
        switch icao {
        case "KPHX": ("Phoenix", "Phoenix")
        case "KLAX": ("Los Angeles", "SoCal")
        default: (icao, icao)
        }
    }

    private func atcSituation(_ s: FlightState) -> ATCSituation? {
        let ahead = ApproachCatalog.approachAhead(approaches, state: s)?.name.replacingOccurrences(of: "ILS ", with: "")
        return ATCSituation(position: lastPosition, heightAboveGroundFeet: s.heightAboveGroundFeet, altitudeFeet: s.altitudeFeet,
                            groundSpeedKnots: s.groundSpeedKnots, onGround: s.onGround, approachRunway: ahead)
    }

    /// The METAR as the ATIS reads it.
    private var atisWeather: ATISWeather {
        let covers: [Metar.Cover: String] = [.few: "few", .scattered: "scattered", .broken: "broken", .overcast: "overcast",
                                             .verticalVisibility: "sky obscured"]
        return ATISWeather(windFrom: weather.windFromDegrees, windKnots: weather.windKnots, gust: weather.gustKnots,
                           visibilityMiles: weather.visibilityMetres / 1_609.344,
                           clouds: weather.clouds.map { (covers[$0.cover] ?? "few", $0.baseFeet) },
                           temperature: Int(weather.temperatureC.rounded()), dewpoint: weather.dewpointC.map { Int($0.rounded()) },
                           altimeterHPa: weather.altimeterHPa, observed: Date())
    }

    /// Makes a call to ATC: the answer goes in the log and the controller's words are spoken.
    func sayATC(_ request: ATCRequest, hud: HUDModel) {
        guard let traffic, let s = lastState, let situation = atcSituation(s) else { return }
        let messages = atc.say(request, situation, traffic: traffic, weather: atisWeather)
        hud.atcLog = atc.log
        for m in messages where !m.isPilot { voice.speak(m.spoken) }
        hud.atcRequests = atc.requests(situation, traffic: traffic)
    }

    /// Hands the glareshield's settings to the autopilot (on the physics thread), with the ILS
    /// ahead when LOC or APPR is armed.
    private func flyAutopilot(hud: HUDModel) {
        var a = AutopilotSettings()
        a.engaged = hud.apMaster
        a.autothrottle = hud.autothrottle
        a.localizerArmed = hud.locArmed
        a.approachArmed = hud.approachArmed
        a.headingDegrees = Double(hud.targetHeading) + declination
        a.altitudeFeet = Double(hud.targetAltitude)
        a.verticalSpeedFPM = Double(hud.targetVerticalSpeed)
        a.speedKnots = Double(hud.targetSpeed)
        a.navEngaged = hud.navEngaged
        a.route = hud.route
        if (a.localizerArmed || a.approachArmed), let s = lastState {
            // Keep the approach once it is being flown; otherwise pick the one ahead.
            let flying = autopilot.status.lateral == .localizer || autopilot.status.lateral == .localizerCapture
            a.approach = flying ? appliedAutopilot.approach : ApproachCatalog.approachAhead(approaches, state: s)
        }
        if a != appliedAutopilot {
            autopilot.update(a)
            appliedAutopilot = a
        }
    }
}
#endif
