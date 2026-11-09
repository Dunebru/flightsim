#if os(iOS)
import Aircraft
import Airports
import FlightModel
import Foundation
import Synchronization
import Renderer
import SimCore
import Terrain
import Weather
import ATC
import Nav
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
            radarCells = Self.radarCells(weather, around: frame.geodetic(SIMD3(0, 0, 0)))
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
    /// The pushback tug while one is attached.
    private var tug: PushbackTug?
    /// Watches for touchdowns and reports them.
    private lazy var landing = LandingMonitor(site: site)
    private var callouts = CalloutMonitor()
    private var replay = ReplayBuffer()
    private var replayActive = false, replayTime = 0.0
    /// Weather radar returns: (latitude, longitude, radius nm, level 0 ... 1).
    private var radarCells: [(Double, Double, Double, Double)] = []

    /// Returns for the weather radar from the METAR at the field. The report says what falls and
    /// how hard, not where: the cells are placed (repeatably, from the report) within 20 nm of
    /// the field, more and stronger for heavier rain, with red cores in thunderstorms.
    static func radarCells(_ w: WeatherConditions, around field: Geodetic) -> [(Double, Double, Double, Double)] {
        let intensity = w.precipitation.flatMap { $0.kind == .snow ? nil : $0.intensity } ?? 0
        guard intensity > 0 || w.thunderstorm else { return [] }
        // FNV-1a of the report's weather groups (String.hashValue changes every launch).
        var rng: UInt64 = w.weather.joined(separator: " ").utf8.reduce(14_695_981_039_346_656_037) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } | 1
        func next() -> Double {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(rng >> 11) / Double(1 << 53)
        }
        let count = Int(6 + 14 * max(intensity, w.thunderstorm ? 0.8 : 0))
        var cells: [(Double, Double, Double, Double)] = []
        for _ in 0..<count {
            let bearing = next() * 2 * .pi, dist = 2 + next() * 18
            let lat = field.latitude + dist / 60 * cos(bearing)
            let lon = field.longitude + dist / 60 * sin(bearing) / cos(field.latitude * .pi / 180)
            let level = min(1, intensity * (0.4 + 0.6 * next()) + (w.thunderstorm ? 0.3 * next() : 0))
            cells.append((lat, lon, 1.5 + next() * 3, level * 0.5))       // the outer, weaker part
            cells.append((lat, lon, 0.8 + next() * 1.2, level))           // its core
        }
        return cells
    }
    private var nextLightning = 5.0, flashStart: Double?, thunderAt: Double?
    /// A push has been completed and the aircraft has not taxied since (no second push offered).
    private var pushedBack = false
    private var crash: CrashCheck?
    private var crashCheckAfter = 1.5

    /// The A320's screens, drawn off the main thread about 15 times a second while the
    /// flight deck is in view.
    nonisolated final class DisplayBox: Sendable {
        let pages = Mutex<(images: [String: DisplayImage], version: Int, busy: Bool)>(([:], 0, false))
    }
    private let displayBox = DisplayBox()
    private var displayFrame = 0

    private func updateDisplays(_ s: FlightState, hud: HUDModel, scene: inout SceneDescription) {
        displayFrame += 1
        let latest = displayBox.pages.withLock { $0 }
        if latest.version > 0 {
            var screens = [("pfd1", "pfd"), ("pfd2", "pfd"), ("nd1", "nd"), ("nd2", "nd"), ("ewd", "ewd"), ("sd", "sd"),
                           ("mcdu", "mcdu"), ("dcdu", "dcdu"), ("isis", "isis"), ("clock", "clock"), ("atc", "atc"),
                           ("batt1", "batt"), ("batt2", "batt")]
            screens += latest.images.keys.filter { $0.hasPrefix("text:") }.map { ($0, $0) }
            for (screen, page) in screens {
                if var image = latest.images[page], scene.displays[screen]?.version != latest.version {
                    image.version = latest.version
                    scene.displays[screen] = image
                }
            }
        }
        guard displayFrame % 4 == 0, !latest.busy else { return }
        var d = DisplayInputs()
        d.ias = s.indicatedAirspeedKnots
        d.altitude = s.altitudeFeet
        d.verticalSpeed = s.verticalSpeedFPM
        d.heading = (s.heading * 180 / .pi - declination + 360).truncatingRemainder(dividingBy: 360)
        d.track = (s.track * 180 / .pi - declination + 360).truncatingRemainder(dividingBy: 360)
        d.pitch = s.pitch * 180 / .pi
        d.roll = s.roll * 180 / .pi
        d.groundSpeed = s.groundSpeedKnots
        d.trueAirspeed = s.trueAirspeedKnots
        d.n1 = s.engineIndication
        d.throttle = s.throttle
        d.flaps = s.flapPosition
        d.gearDown = s.gearPosition
        d.onGround = s.onGround
        d.windFrom = Double(hud.windFrom)
        d.windKnots = Double(hud.windKnots)
        d.selectedAltitude = Double(hud.targetAltitude)
        // Bearing (magnetic) and distance (nm) from the aircraft to a point, flat-earth (fine
        // within a few hundred miles).
        func relative(_ lat: Double, _ lon: Double) -> (Double, Double) {
            let north = (lat - s.latitude) * 60, east = (lon - s.longitude) * 60 * cos(s.latitude * .pi / 180)
            let bearing = (atan2(east, north) * 180 / .pi - declination + 720).truncatingRemainder(dividingBy: 360)
            return (bearing, (north * north + east * east).squareRoot())
        }
        d.origin = site.layout.icao
        d.route = hud.route.map { p in let r = relative(p.latitude, p.longitude); return (p.name, r.0, r.1) }
        d.activeWaypoint = hud.navEngaged ? (hud.activeWaypoint ?? hud.route.count) : 0
        d.weather = radarCells.map { c in let r = relative(c.0, c.1); return (r.0, r.1, c.2, c.3) }
        let agl = s.heightAboveGroundFeet
        d.rangeNM = s.onGround ? 10 : (agl < 5_000 ? 20 : (s.altitudeFeet < 20_000 ? 40 : 80))
        d.fma = [hud.autothrottle ? "SPEED" : "", hud.apVertical, hud.apLateral, hud.apApproach == nil ? "" : "CAT 1",
                 hud.apMaster ? "AP1" : ""]
        // The digital readouts: their values, formatted as the model's XML says.
        let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: Date())
        let readoutValues: [String: Double] = [
            "it-autoflight/input/kts-display": Double(hud.targetSpeed), "it-autoflight/input/hdg": Double(hud.targetHeading),
            "it-autoflight/input/alt": Double(hud.targetAltitude),
            "instrumentation/altimeter/setting-hpa": weather.altimeterHPa.rounded(),
        ]
        let vsText = hud.targetVerticalSpeed == 0 ? "00" : String(format: "%+03d", hud.targetVerticalSpeed / 100)
        let readoutText: [String: String] = [
            "it-autoflight/output/vs-fcu-display": vsText,
            "controls/radio/rmp[0]/active-display": "118.700", "controls/radio/rmp[0]/standby-display": "121.900",
            "controls/radio/rmp[1]/active-display": "118.700", "controls/radio/rmp[1]/standby-display": "119.750",
            "/systems/atc/transponder-code": "2000", "systems/atc/transponder-code": "2000",
            "instrumentation/clock/indicated-hours": String(format: "%02d", utc.hour ?? 0),
            "instrumentation/clock/indicated-minutes": String(format: "%02d", utc.minute ?? 0),
            "instrumentation/clock/indicated-seconds": String(format: "%02d", utc.second ?? 0),
            "instrumentation/clock/et/indicated-hours": "00", "instrumentation/clock/et/indicated-min": "00",
            "controls/flight/rudder-trim-display": "0.0",
        ]
        var readouts: [String: String] = [:]
        for (name, label) in scene.textLabels {
            if let literal = label.literal { readouts[name] = literal; continue }
            if let t = readoutText[label.property] { readouts[name] = t; continue }
            if let v = readoutValues[label.property] { readouts[name] = String(format: label.format.replacingOccurrences(of: "%s", with: "%.0f"), v) }
        }
        let labels = scene.textLabels
        displayBox.pages.withLock { $0.busy = true }
        let box = displayBox
        DispatchQueue.global(qos: .userInitiated).async {
            var images: [String: DisplayImage] = [:]
            let n = CockpitDisplays.size
            for page in ["pfd", "nd", "ewd", "sd", "mcdu", "dcdu", "isis", "clock", "atc", "batt"] {
                images[page] = DisplayImage(pixels: CockpitDisplays.draw(page, d), size: n, version: 0)
            }
            for (name, text) in readouts {
                let aspect = labels[name]?.aspect ?? 3
                let h = 40, w = min(512, Int((Double(h) * aspect).rounded()))
                images["text:" + name] = DisplayImage(pixels: CockpitDisplays.readout(text, width: w, height: h), width: w, height: h, version: 0)
            }
            box.pages.withLock { $0 = (images, $0.version + 1, false) }
        }
    }

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

        // Replay: the flight model holds while the recording plays into the scene.
        if hud.replaying {
            if !replayActive {
                replayActive = true
                replayTime = max(replay.start, replay.start + replay.duration - 120)
                hud.replayPlaying = true
            }
            physics.setPaused(true)
            if let seek = hud.replaySeek { replayTime = replay.start + seek; hud.replaySeek = nil }
            if hud.replayPlaying { replayTime += dt }
            if replayTime >= replay.start + replay.duration { replayTime = replay.start + replay.duration; hud.replayPlaying = false }
            if let f = replay.frame(at: replayTime) {
                scene.aircraftPosition = f.position
                scene.aircraftHeading = f.heading
                scene.aircraftPitch = f.pitch
                scene.aircraftRoll = f.roll
                scene.aircraftGearDown = f.gearDown
                scene.instrumentValues = f.values
                scene.playerLights = f.lights
                scene.tugPose = nil
            }
            hud.replayPosition = replayTime - replay.start
            hud.replayDuration = replay.duration
            audio.update(SoundParameters())
            return
        }
        replayActive = false

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
        // Nose wheel steering from the same input. The A320's tiller turns the wheel 75 degrees
        // at taxi speeds; above 20 kt only the pedals steer it, 6 degrees, gone by 130 kt. The
        // C172's pedals steer it 10 degrees at any speed on the ground.
        if profile.isTurbine {
            let gs = lastState?.groundSpeedKnots ?? 0
            let pedals = 6.0 / 75 * max(0, min(1, (130 - gs) / 60))
            let authority = gs < 20 ? 1 : max(pedals, 1 - (gs - 20) / 50)
            inputs.steering = inputs.yaw * authority
        } else {
            inputs.steering = inputs.yaw
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
        // Pushback: the tug takes the nose wheel, releases the parking brake to start and sets
        // it when the push is done; the pilot's steering and thrust are set aside meanwhile.
        if let direction = hud.pushbackRequest {
            hud.pushbackRequest = nil
            if hud.canPushBack {
                tug = PushbackTug(direction: direction)
                hud.parkingBrake = false
                hud.setThrottle(0)
                hud.reverse = false
            }
        }
        if hud.pushbackStopRequested { hud.pushbackStopRequested = false; tug?.stop() }
        var tugBrakes = 0.0
        if var t = tug, let s = lastState {
            let cmd = t.update(dt: min(dt, 0.1), heading: s.heading, forwardKnots: s.forwardSpeedKnots, weightPounds: s.weightPounds)
            inputs.pushbackPounds = cmd.pounds
            inputs.steering = cmd.steering
            inputs.throttle = 0
            tugBrakes = cmd.brakes
            if t.phase == .done { tug = nil; hud.parkingBrake = true; pushedBack = true } else { tug = t }
        }
        if let s = lastState {
            if s.groundSpeedKnots > 5 { pushedBack = false }
            let ready = tug == nil && !pushedBack && profile.isTurbine && s.onGround && s.groundSpeedKnots < 1
            if hud.canPushBack != ready { hud.canPushBack = ready }
        }
        if hud.pushingBack != (tug != nil) { hud.pushingBack = tug != nil }
        inputs.parkingBrake = hud.parkingBrake
        inputs.brakes = max(hud.wheelBrakes ? 1 : 0, tugBrakes)
        inputs.pitchTrim = hud.trim
        physics.setInputs(inputs)
        physics.setPaused(hud.paused || holdForScenery || hud.crashMessage != nil)
        clock += dt
        if let s = lastState { physics.setAtmosphere(atmosphere(heightFeet: s.heightAboveGroundFeet, altitudeFeet: s.altitudeFeet)) }

        let s = physics.state
        lastState = s
        if hud.crashMessage == nil, let report = landing.update(LandingMonitor.Sample(
            time: clock, position: lastPosition, heightAboveGroundFeet: s.heightAboveGroundFeet, verticalSpeedFPM: s.verticalSpeedFPM,
            onGround: s.onGround, groundSpeedKnots: s.groundSpeedKnots, airspeedKnots: s.indicatedAirspeedKnots, loadFactor: s.loadFactor,
            pitch: s.pitch, roll: s.roll, heading: s.heading, track: s.track)) {
            hud.showLanding(report)
        }
        // Callouts and alerts (the A320's), rain on the windscreen, the tug's engine.
        let inside = hud.camera == .cockpit
        if s.engineIsTurbine {
            let gearDown: Bool = { if case .down = hud.gear { return true }; return false }()
            for cue in callouts.update(.init(radioHeightFeet: s.heightAboveGroundFeet - profile.cgAboveMainGear / 0.3048,
                                             verticalSpeedFPM: s.verticalSpeedFPM, onGround: s.onGround, gearDown: gearDown,
                                             throttle: hud.throttle, autopilot: hud.apMaster, altitudeFeet: s.altitudeFeet,
                                             selectedAltitudeFeet: Double(hud.targetAltitude))) {
                audio.play(cue, volume: inside ? 1 : 0.45)
            }
        }
        let rain = scene.precipitation.flatMap { $0.kind == .snow ? nil : $0.intensity } ?? 0
        audio.setLoop("rain-windshield", volume: Float(rain * (inside ? 0.9 : 0.35)))
        audio.setLoop("pushback", volume: tug == nil ? 0 : (inside ? 0.25 : 0.7))
        scene.windscreenRain = inside ? Float(rain) : 0
        scene.airspeedKnots = Float(s.trueAirspeedKnots)
        // Thunderstorms: a flash every 8 to 30 seconds (a double pulse), its thunder 1 to 7
        // seconds later, as far off as the strike.
        if weather.thunderstorm {
            if clock > nextLightning {
                flashStart = clock
                thunderAt = clock + Double.random(in: 1...7)
                nextLightning = clock + Double.random(in: 8...30)
            }
        }
        if let f = flashStart {
            let t = clock - f
            let pulse = t < 0.08 ? 1.0 : (t > 0.18 && t < 0.26 ? 0.7 : 0)
            scene.lightningFlash = Float(pulse)
            if t > 0.3 { flashStart = nil; scene.lightningFlash = 0 }
        }
        if let at = thunderAt, clock >= at {
            thunderAt = nil
            audio.play(["thunder1", "thunder2", "thunder3"].randomElement()!, volume: Float.random(in: 0.5...1) * (inside ? 0.7 : 1))
        }
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
        // The tug faces the aircraft from ahead of the nose wheel, lined up with it, its tow bar
        // on the wheel.
        if tug != nil {
            let wheel = s.heading + s.noseSteeringDegrees * .pi / 180
            let nose = SIMD2(base.x, base.y) + SIMD2(sin(s.heading), cos(s.heading)) * profile.noseWheelAheadOfCG
            let at = nose + SIMD2(sin(wheel), cos(wheel)) * 7.5
            scene.tugPose = SIMD4(at.x, at.y, base.z, wheel + .pi)
        } else {
            scene.tugPose = nil
        }
        scene.aircraftGearDown = s.gearPosition > 0.97
        scene.propellerSpinning = !s.engineIsTurbine && s.engineIndication > 400
        if s.engineIsTurbine && hud.camera == .cockpit {
            updateDisplays(s, hud: hud, scene: &scene)
        }
        if s.engineIsTurbine {
            scene.instrumentValues = A320Model.readings(
                leftAileron: s.leftAileronDegrees, rightAileron: s.rightAileronDegrees, elevator: s.elevatorDegrees,
                rudder: s.rudderDegrees, flaps: s.flapPosition, speedbrake: s.speedbrake, steering: s.noseSteeringDegrees,
                gear: s.gearPosition, compression: s.gearCompressionFeet, wheelSpeed: s.wheelSpeed, n1: s.engineIndication,
                reverser: s.reverser)
            // The levers and controls the pilot moves, in FlightGear's ranges: the sidestick
            // (+1 forward), tiller and pedals, thrust and reverse levers, gear lever (0 up,
            // 3 down), flap lever detents, speedbrake lever (raised when armed).
            typealias D = A320Model.DeckControl
            let gearUp: Bool = { if case .up = hud.gear { return true }; if case .transit(let down) = hud.gear { return !down }; return false }()
            let deck: [String: Double] = [
                D.sidestickPitch: -inputs.pitch, D.sidestickRoll: inputs.roll,
                D.tiller: (lastState?.groundSpeedKnots ?? 0) < 20 ? inputs.steering : 0, D.pedals: inputs.yaw,
                D.throttle[0]: hud.reverse ? 0 : inputs.throttle, D.throttle[1]: hud.reverse ? 0 : inputs.throttle,
                D.reverse[0]: hud.reverse ? max(0.25, inputs.throttle) : 0, D.reverse[1]: hud.reverse ? max(0.25, inputs.throttle) : 0,
                D.gear: gearUp ? 0 : 3, D.flaps: Double(hud.flapIndex),
                D.speedbrake: [0, 0, 0.5, 1][min(hud.spoilerIndex, 3)],
                "controls/cockpit/spoilers-lever-translate": hud.spoilerIndex == 1 ? 1 : 0,
            ]
            scene.instrumentValues.merge(deck) { _, new in new }
        } else {
            scene.instrumentValues = Self.cockpitReadings(s, inputs: inputs, declination: declination, headingBug: Double(hud.targetHeading))
        }
        scene.aircraftRoll = s.roll
        scene.aircraftPitch = s.pitch
        // Exterior lights from the lights panel, at the nose wheel (where the light layouts are
        // measured from).
        var flags = 0
        if hud.lights.contains(.nav) || hud.lights.contains(.beacon) { flags |= 8 }
        if hud.lights.contains(.strobe) { flags |= 4 }
        if hud.lights.contains(.landing) { flags |= 1 }
        if hud.lights.contains(.taxi) { flags |= 2 }
        let nose = scene.aircraftPosition + SIMD3(sin(s.heading), cos(s.heading), 0) * profile.noseWheelAheadOfCG
        let lightHeading = Float(s.heading)
        scene.playerLights = flags == 0 ? nil : SIMD8<Float>(Float(nose.x), Float(nose.y), Float(nose.z), lightHeading, 0.37,
                                                             Float(s.pitch), Float(s.roll), Float(flags))
        scene.playerLightsSmall = !s.engineIsTurbine
        if !hud.paused && hud.crashMessage == nil { replay.record(time: clock, scene) }

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
        hud.taxiRoute = atc.taxiPath.enumerated().map { i, p in
            let g = frame.geodetic(SIMD3(p.x, p.y, 0))
            return NavPoint(name: "TAXI\(i)", latitude: g.latitude, longitude: g.longitude)
        }
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
