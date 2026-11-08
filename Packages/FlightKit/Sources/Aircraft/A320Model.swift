public import Foundation

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

    /// Reads the airframe and the engines from a folder and joins them (they share an origin).
    public static func load(from directory: URL) throws -> AC3DModel {
        func read(_ name: String) throws -> AC3DModel {
            try AC3DParser.parse(try String(contentsOf: directory.appendingPathComponent(name), encoding: .isoLatin1), part: part)
        }
        return try read("A320-216.ac").merged(with: try read("CFM56.ac"))
    }
}
