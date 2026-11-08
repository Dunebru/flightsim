import CJSBSim
public import Foundation

/// Pilot inputs, all normalised.
public struct ControlInputs: Sendable, Equatable {
    /// Pitch: -1 full forward (nose down) ... +1 full aft (nose up).
    public var pitch: Double = 0
    /// Roll: -1 full left ... +1 full right.
    public var roll: Double = 0
    /// Yaw / rudder pedals: -1 left ... +1 right.
    public var yaw: Double = 0
    /// Thrust lever, 0 idle ... 1 full.
    public var throttle: Double = 0
    /// Reverse thrust engaged (jets): the lever then commands reverse.
    public var reverse = false
    /// Flap lever, 0 up ... 1 full.
    public var flaps: Double = 0
    /// Speedbrake / spoilers, 0 retracted ... 1 full.
    public var spoilers: Double = 0
    public var gearDown = true
    /// Wheel brakes, 0 ... 1.
    public var brakes: Double = 0
    public var parkingBrake = false
    /// Elevator trim, -1 nose down ... +1 nose up.
    public var pitchTrim: Double = 0

    public init() {}
}

/// Where and how the aircraft starts.
public struct InitialConditions: Sendable {
    public var latitude: Double
    public var longitude: Double
    /// Ground elevation under the aircraft, feet above mean sea level.
    public var terrainElevationFeet: Double
    /// Height above the ground, feet. Zero starts on the ground.
    public var heightAboveGroundFeet: Double
    /// True heading, degrees.
    public var headingDegrees: Double
    /// Calibrated airspeed, knots.
    public var airspeedKnots: Double
    public var flaps: Double = 0
    public var gearDown = true

    public init(latitude: Double, longitude: Double, terrainElevationFeet: Double, heightAboveGroundFeet: Double,
                headingDegrees: Double, airspeedKnots: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.terrainElevationFeet = terrainElevationFeet
        self.heightAboveGroundFeet = heightAboveGroundFeet
        self.headingDegrees = headingDegrees
        self.airspeedKnots = airspeedKnots
    }
}

/// A snapshot of the aircraft, in the units pilots read.
public struct FlightState: Sendable, Equatable {
    public var time: Double = 0
    public var latitude: Double = 0
    public var longitude: Double = 0
    public var altitudeFeet: Double = 0           // above mean sea level
    public var heightAboveGroundFeet: Double = 0
    public var roll: Double = 0                   // radians, right wing down positive
    public var pitch: Double = 0                  // radians, nose up positive
    public var heading: Double = 0                // radians true, 0 = north
    public var indicatedAirspeedKnots: Double = 0 // calibrated airspeed (no instrument error modelled)
    public var trueAirspeedKnots: Double = 0
    public var groundSpeedKnots: Double = 0
    public var verticalSpeedFPM: Double = 0
    public var angleOfAttackDegrees: Double = 0
    public var sideslipDegrees: Double = 0
    public var mach: Double = 0
    /// Engine power indication: N1 % for turbines, RPM for pistons.
    public var engineIndication: Double = 0
    public var engineIsTurbine = false
    public var flapPosition: Double = 0           // 0...1
    public var gearPosition: Double = 1           // 0 up ... 1 down
    public var onGround = true
    public var stallWarning = false
    /// Body-axis load factor (g), positive up.
    public var loadFactor: Double = 1

    public init() {}
}

public enum FlightModelError: Error, CustomStringConvertible {
    case engine(String)
    case trim(String)
    public var description: String {
        switch self {
        case .engine(let m): "Flight model: \(m)"
        case .trim(let m): "Trim failed: \(m)"
        }
    }
}

/// One JSBSim aircraft. Not thread-safe: create it on, and use it only from, one thread (the
/// physics thread). JSBSim itself is not re-entrant.
public final class FlightDynamics {
    public let model: String
    private let handle: OpaquePointer
    public private(set) var stepSize: Double
    private let isTurbine: Bool

    /// The bundled JSBSim data (aircraft/, engine/, systems/).
    public static var bundledRoot: URL? {
        Bundle.module.url(forResource: "JSBSim", withExtension: nil)
    }

    public static var engineVersion: String { String(cString: jsb_version()) }

    public init(model: String, root: URL? = FlightDynamics.bundledRoot, rate: Double = 120) throws {
        guard let root else { throw FlightModelError.engine("JSBSim data not found in the bundle") }
        var error = [CChar](repeating: 0, count: 512)
        guard let h = jsb_create(root.path, &error, Int32(error.count)) else {
            throw FlightModelError.engine(Self.message(error))
        }
        guard jsb_load_model(h, model, &error, Int32(error.count)) == 1 else {
            jsb_destroy(h)
            throw FlightModelError.engine(Self.message(error))
        }
        handle = h
        self.model = model
        stepSize = 1 / rate
        jsb_set_dt(h, stepSize)
        isTurbine = jsb_has(h, "propulsion/engine/n1") == 1
    }

    deinit { jsb_destroy(handle) }

    // MARK: Properties

    public func get(_ property: String) -> Double { jsb_get(handle, property) }

    @discardableResult
    public func set(_ property: String, _ value: Double) -> Bool { jsb_set(handle, property, value) == 1 }

    public func has(_ property: String) -> Bool { jsb_has(handle, property) == 1 }

    public var simulationTime: Double { jsb_sim_time(handle) }

    // MARK: Setup

    /// Places the aircraft, applies initial conditions, and starts its engines.
    public func initialize(_ ic: InitialConditions, enginesRunning: Bool = true) throws {
        set("ic/lat-geod-deg", ic.latitude)
        set("ic/long-gc-deg", ic.longitude)
        set("ic/terrain-elevation-ft", ic.terrainElevationFeet)
        // On the ground: start the reference point a little above the gear (never buried, which
        // launches and tips the aircraft), then let JSBSim's ground trim settle it.
        let onGround = ic.heightAboveGroundFeet <= 0
        set("ic/h-agl-ft", onGround ? Self.groundStartHeightFeet : ic.heightAboveGroundFeet)
        set("ic/psi-true-deg", ic.headingDegrees)
        set("ic/vc-kts", ic.airspeedKnots)
        set("ic/gamma-deg", 0)
        set("fcs/flap-cmd-norm", ic.flaps)
        set("gear/gear-cmd-norm", ic.gearDown ? 1 : 0)
        var error = [CChar](repeating: 0, count: 512)
        guard jsb_run_ic(handle, &error, Int32(error.count)) == 1 else {
            throw FlightModelError.engine("RunIC: \(Self.message(error))")
        }
        if onGround {
            try? trim(.ground)
        }
        if enginesRunning { startEngines() }
    }

    /// Initial height of the reference point for an on-ground start, feet: above any of the
    /// library aircraft's gear legs so nothing starts buried.
    static let groundStartHeightFeet = 12.0

    public func startEngines() {
        set("propulsion/magneto_cmd", 3)
        set("fcs/mixture-cmd-norm", 1)
        for i in 0..<engineCount {
            set("fcs/mixture-cmd-norm[\(i)]", 1)
            set("propulsion/engine[\(i)]/set-running", 1)
        }
        set("propulsion/set-running", -1)
    }

    public var engineCount: Int {
        var n = 0
        while has("propulsion/engine[\(n)]/thrust-lbs") { n += 1 }
        return max(n, 1)
    }

    public enum TrimMode: Int32 {
        case longitudinal = 0, full = 1, ground = 2
    }

    public func trim(_ mode: TrimMode = .full) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard jsb_trim(handle, mode.rawValue, &error, Int32(error.count)) == 1 else {
            throw FlightModelError.trim(Self.message(error))
        }
    }

    // MARK: Run

    public func apply(_ c: ControlInputs) {
        // JSBSim: positive elevator command is trailing edge down (nose down).
        set("fcs/elevator-cmd-norm", -c.pitch)
        set("fcs/aileron-cmd-norm", c.roll)
        set("fcs/rudder-cmd-norm", c.yaw)
        set("fcs/pitch-trim-cmd-norm", c.pitchTrim)
        for i in 0..<engineCount {
            set("fcs/throttle-cmd-norm[\(i)]", c.throttle)
            if isTurbine { set("propulsion/engine[\(i)]/reverser-angle-rad", c.reverse ? .pi / 2 : 0) }
        }
        set("fcs/flap-cmd-norm", c.flaps)
        set("fcs/speedbrake-cmd-norm", c.spoilers)
        set("fcs/spoiler-cmd-norm", c.spoilers)
        set("gear/gear-cmd-norm", c.gearDown ? 1 : 0)
        let brake = c.parkingBrake ? 1 : c.brakes
        set("fcs/left-brake-cmd-norm", brake)
        set("fcs/right-brake-cmd-norm", brake)
        set("fcs/center-brake-cmd-norm", brake)
    }

    /// Ground height under the aircraft, feet above mean sea level. JSBSim treats the ground
    /// as level at this height around the aircraft; update it as the aircraft moves.
    public func setTerrainElevation(feet: Double) {
        set("position/terrain-elevation-asl-ft", feet)
    }

    /// A NUL-terminated C error buffer as text.
    static func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public var terrainElevationFeet: Double { self.get("position/terrain-elevation-asl-ft") }

    /// Advances `count` fixed steps.
    public func step(_ count: Int = 1) {
        for _ in 0..<count { _ = jsb_step(handle) }
    }

    public var state: FlightState {
        var s = FlightState()
        s.time = simulationTime
        s.latitude = get("position/lat-geod-deg")
        s.longitude = get("position/long-gc-deg")
        s.altitudeFeet = get("position/h-sl-ft")
        s.heightAboveGroundFeet = get("position/h-agl-ft")
        s.roll = get("attitude/phi-rad")
        s.pitch = get("attitude/theta-rad")
        s.heading = get("attitude/psi-rad")
        s.indicatedAirspeedKnots = get("velocities/vc-kts")
        s.trueAirspeedKnots = get("velocities/vtrue-kts")
        s.groundSpeedKnots = get("velocities/vg-fps") * 0.592_484
        s.verticalSpeedFPM = get("velocities/h-dot-fps") * 60
        s.angleOfAttackDegrees = get("aero/alpha-deg")
        s.sideslipDegrees = get("aero/beta-deg")
        s.mach = get("velocities/mach")
        s.engineIsTurbine = isTurbine
        s.engineIndication = isTurbine ? get("propulsion/engine/n1") : get("propulsion/engine/engine-rpm")
        s.flapPosition = get("fcs/flap-pos-norm")
        s.gearPosition = get("gear/gear-pos-norm")
        s.onGround = get("gear/unit[0]/WOW") > 0.5 || get("gear/unit[1]/WOW") > 0.5 || get("gear/unit[2]/WOW") > 0.5
        s.loadFactor = -get("accelerations/Nz")
        if s.loadFactor.isNaN { s.loadFactor = 1 }
        return s
    }
}
