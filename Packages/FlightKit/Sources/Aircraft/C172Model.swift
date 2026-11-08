public import Foundation
import simd

/// The FlightGear c172p (GPL-2.0): which exterior objects to draw, and the cockpit assembled
/// from its panel, instruments, yoke and pedals with their animations.
public enum C172Model {
    public static func part(_ name: String) -> String {
        let lower = name.lowercased()
        // Click areas, tie-downs and plugs for the parked aircraft, the beams of the landing and
        // taxi lights (cones FlightGear draws only at night) and the boxes FlightGear uses to
        // hide the cockpit from the outside view: none are solid parts of the aeroplane.
        if lower.contains("hotspot") || lower.hasPrefix("tiedown") || name == "PropellerCowlPlugs"
            || name == "lightlanding" || name == "lighttaxi" || name == "landinglight" || name == "taxilight"
            || name.hasPrefix("courtesyon") || name == "BeaconOffX"
            || name == "panel_blocker" || name == "sun_and_view_blocker" { return "hidden" }
        if name == "Propeller.Fast" { return "prop-fast" }
        if name == "Propeller" { return "prop-slow" }
        return "airframe"
    }

    /// The cockpit: interior, panel and its instruments (from the panel's own model list),
    /// the yoke, and the pilot's pedals where the airframe model places them. All files flat in
    /// `directory`.
    public static func loadCockpit(directory: URL) throws -> AnimatedModel {
        var m = AnimatedModel()
        m.defaults = defaults
        m.hiddenObjects = ["glass_panel"]
        try m.load(xml: "c172p.xml", directory: directory,
                   excluding: ["/Effects/", "garmin", "gpsmodel", "-float", "fg1000", "control-lock", "elt"])
        var pedals = matrix_identity_double4x4
        pedals.columns.3 = SIMD4(FGAnimation.acFrame(SIMD3(-0.56, -0.24, -0.61)), 1)
        try m.load(xml: "pedals-pilot.xml", directory: directory, placement: pedals)
        return m
    }

    /// The whole aeroplane: FlightGear's airframe model file, which places the cockpit (panel,
    /// instruments, yokes, pedals) and animates the control surfaces, nose wheel and knobs.
    public static func loadAircraft(directory: URL) throws -> AnimatedModel {
        var m = AnimatedModel()
        m.defaults = defaults
        m.hiddenObjects = ["glass_panel"]
        try m.load(xml: "c172p-model.xml", directory: directory,
                   excluding: ["/Effects/", "garmin", "gpsmodel", "-float", "fg1000", "control-lock", "elt", "ski", "amphibious"],
                   staticPart: "airframe", special: { name in
                       let p = part(name)
                       return p == "airframe" ? nil : p
                   })
        return m
    }

    /// The FlightGear model's control-surface properties from JSBSim's normalized positions
    /// (fcs/*-pos-norm). FlightGear's own c172p flight model publishes the right aileron with the
    /// opposite sign to the JSBSim c172p we fly, so it is turned round here.
    public static func surfaceReadings(leftAileron: Double, rightAileron: Double, elevator: Double, rudder: Double) -> [String: Double] {
        [Property.leftAileron: leftAileron, Property.rightAileron: -rightAileron, Property.elevator: elevator, Property.rudder: rudder]
    }

    /// Readings for properties the flight does not model, so the needles sit where they would
    /// in a running aeroplane rather than on their stops.
    public static let defaults: [String: Double] = [
        "instrumentation/altimeter/setting-inhg": 29.92,
        "engines/active-engine/indicated-oil-final-temperature-degf": 185,
        "engines/active-engine/indicated-oil-pressure-psi": 62,
        "consumables/fuel/tank[0]/indicated-level-gal_us": 20,
        "consumables/fuel/tank[1]/indicated-level-gal_us": 20,
        "systems/vacuum/suction-inhg": 5,
        "systems/electrical/amps": 2,
        "systems/electrical/outputs/turn-coordinator": 28,
        "controls/engines/current-engine/mixture": 1,
        "controls/switches/master-bat": 1,
        "controls/switches/master-alt": 1,
        "controls/switches/master-avionics": 1,
    ].merging(["autopilot", "bcnlt", "flaps", "instr", "intlt", "landing", "master", "navlt", "pitot-heat", "radio1", "radio2",
               "radio3", "radio4", "radio5", "strobe", "turn-coordinator"].map { ("controls/circuit-breakers/\($0)", 1.0) }) { a, _ in a }

    /// The property names the flight supplies each frame.
    public enum Property {
        public static let airspeed = "fdm/jsbsim/velocities/vias-kts"
        public static let pitch = "instrumentation/attitude-indicator/indicated-pitch-deg"
        public static let roll = "instrumentation/attitude-indicator/indicated-roll-deg"
        public static let altitude = "instrumentation/altimeter/indicated-altitude-ft"
        public static let heading = "instrumentation/heading-indicator/indicated-heading-deg"
        public static let headingBug = "autopilot/settings/heading-bug-deg"
        public static let verticalSpeed = "instrumentation/vertical-speed-indicator/indicated-speed-fpm"
        public static let turnRate = "instrumentation/turn-indicator/indicated-turn-rate"
        public static let slipSkid = "instrumentation/slip-skid-ball/indicated-slip-skid"
        public static let rpm = "engines/engine[2]/rpm"
        public static let compass = "instrumentation/magnetic-compass/indicated-heading-deg-final"
        public static let flaps = "surface-positions/flap-pos-norm"
        public static let yokeAileron = "sim/model/c172p/cockpit/yoke-aileron"
        public static let yokeElevator = "sim/model/c172p/cockpit/yoke-elevator"
        public static let pedals = "sim/model/c172p/cockpit/pedals-rudder"
        public static let throttle = "controls/engines/current-engine/throttle"
        public static let clock = "sim/model/c172p/local-time-seconds"
        public static let navDeflection = "instrumentation/nav[0]/filtered-cdiNAV0-deflection"
        public static let glideslopeDeflection = "instrumentation/nav[0]/filtered-gsNAV0-deflection"
        public static let navRadial = "instrumentation/nav[0]/radials/selected-deg"
        public static let leftAileron = "surface-positions/left-aileron-pos-norm"
        public static let rightAileron = "surface-positions/right-aileron-pos-norm"
        public static let elevator = "surface-positions/elevator-pos-norm"
        public static let rudder = "surface-positions/rudder-pos-norm"
        public static let elevatorTrim = "controls/flight/elevator-trim"
        public static let noseSteering = "fdm/jsbsim/fcs/steer-pos-deg"
    }
}
