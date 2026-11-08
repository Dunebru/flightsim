public import Foundation
public import simd

/// The FlightGear A320 family model (legoboyvdlp and Octal450, GPL-2.0): which of its named
/// objects are what, and its liveries.
public enum A320Model {
    /// The part an object belongs to: "gear" retracts with the gear lever; "hidden" is never
    /// drawn (the deployed ram air turbine, a cargo container in the hold, the sharklets this
    /// wingtip-fence aircraft does not have); everything else is the airframe.
    public static func part(_ name: String) -> String {
        if name == "Rat" || name.hasPrefix("ULD") || name.hasPrefix("Sharklet") || name == "navglass.sharklet"
            || name.hasPrefix("NurbsPath") { return "hidden" }
        // Gear doors stay: without them the bays would show as holes.
        if name.contains("Door") { return "airframe" }
        if name.hasPrefix("MLG") || name.hasPrefix("NLG") || name.hasPrefix("SideStay") { return "gear" }
        return "airframe"
    }

    /// A paint scheme: the fuselage and engine sheets that replace the base model's.
    public struct Livery: Sendable, Hashable {
        public let code: String
        public let fuselage: String
        public let engine: String

        /// Base texture name to this livery's texture.
        public var textures: [String: String] { ["Fuse-Main.png": fuselage, "engine-CFM56.png": engine] }
    }

    public static let liveries: [Livery] = [
        Livery(code: "AAL", fuselage: "AAL-fuselage.png", engine: "AAL-engine.png"),
        Livery(code: "DAL", fuselage: "DAL-fuselage.png", engine: "DAL-engine.png"),
        Livery(code: "SWR", fuselage: "SWR-fuselage.png", engine: "SWR-engine.png"),
        Livery(code: "AUA", fuselage: "AUA-fuselage.png", engine: "CFM56-white.png"),
    ]

    /// Where FlightGear hangs the engines on the airframe (A320-200-CFM.xml: z +0.83109 m),
    /// in the AC3D file's frame (y up).
    public static let engineOffset = SIMD3<Float>(0, 0.83109, 0)

    /// Reads the airframe and the engines from a folder and joins them, the engines raised to
    /// where FlightGear places them. For the traffic: no animation.
    public static func load(from directory: URL) throws -> AC3DModel {
        func read(_ name: String) throws -> AC3DModel {
            try AC3DParser.parse(try String(contentsOf: directory.appendingPathComponent(name), encoding: .isoLatin1), part: part)
        }
        var engines = try read("CFM56.ac")
        for i in engines.groups.indices { engines.groups[i].positions = engines.groups[i].positions.map { $0 + engineOffset } }
        engines.boundsMin += engineOffset
        engines.boundsMax += engineOffset
        return try read("A320-216.ac").merged(with: engines)
    }

    /// The flyable aircraft: airframe and engines with FlightGear's animations (gear and its
    /// doors, struts, wheels, fans, flight controls, spoilers, slats, flaps, reversers).
    public static func loadAnimated(from directory: URL) throws -> AnimatedModel {
        var m = AnimatedModel()
        let special: (String) -> String? = { part($0) == "hidden" ? "hidden" : nil }
        try m.load(xml: "fuselage.xml", directory: directory, staticPart: "airframe", special: special)
        var engines = matrix_identity_double4x4
        engines.columns.3 = SIMD4(SIMD3<Double>(engineOffset), 1)
        try m.load(xml: "a320.cfm.xml", directory: directory, placement: engines, staticPart: "airframe", special: special)
        return m
    }

    /// FlightGear's names for what the flight supplies, from JSBSim's surface angles (degrees),
    /// the gear and the engines.
    public enum Property {
        public static let gear = (0..<3).map { "gear/gear[\($0)]/position-norm" }
        public static let compression = (0..<3).map { "gear/gear[\($0)]/compression-norm" }
        public static let wheelSpeed = (0..<3).map { "gear/gear[\($0)]/rollspeed-ms" }
        public static let n1 = ["engines/engine[3]/n1", "engines/engine[4]/n1"]
        public static let reverser = ["engines/engine[0]/reverser-pos-norm", "engines/engine[1]/reverser-pos-norm"]
        public static let elevator = ["sim/multiplay/generic/float[4]", "sim/multiplay/generic/float[5]"]
        public static let aileronLeft = "sim/multiplay/generic/float[6]"
        public static let aileronRight = "sim/multiplay/generic/float[7]"
        public static let rudder = "sim/multiplay/generic/float[8]"
        public static let stabilizer = "sim/multiplay/generic/float[9]"
        public static let slats = "sim/multiplay/generic/float[11]"
        public static let flaps = "sim/multiplay/generic/float[12]"
        public static let steering = "sim/multiplay/generic/float[1]"
        public static let spoilers = (1...5).flatMap { ["systems/fcs/spoiler-l\($0)/final-deg", "systems/fcs/spoiler-r\($0)/final-deg"] }
    }

    /// The flight's state as the model's properties. Surface angles are JSBSim's (degrees, its
    /// signs); flaps 0...1; steering degrees; gear 0 up ... 1 down; compression feet; wheel
    /// speed m/s; N1 percent; speedbrake and reverser 0...1.
    public static func readings(leftAileron: Double, rightAileron: Double, elevator: Double, rudder: Double, flaps: Double,
                                speedbrake: Double, steering: Double, gear: Double, compression: SIMD3<Double>,
                                wheelSpeed: SIMD3<Double>, n1: Double, reverser: Double) -> [String: Double] {
        var r: [String: Double] = [
            Property.aileronLeft: leftAileron, Property.aileronRight: rightAileron, Property.rudder: rudder,
            Property.flaps: flaps,
            // Slats run out with the first flap setting: 18 degrees, then 22, 27 at full.
            Property.slats: flaps > 0.01 ? min(1, 0.67 + flaps * 0.33) : 0,
            Property.steering: steering / 75,
        ]
        for p in Property.elevator { r[p] = elevator }
        for (i, p) in Property.gear.enumerated() { r[p] = gear; r[Property.compression[i]] = compression[i]; r[Property.wheelSpeed[i]] = wheelSpeed[i] }
        for p in Property.n1 { r[p] = n1 }
        for p in Property.reverser { r[p] = reverser }
        for p in Property.spoilers { r[p] = speedbrake * 40 }
        return r
    }
}
