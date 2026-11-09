public import Foundation

/// The airliner types drawn as traffic. Widebody stands get the 777; about a third of the other
/// stands get the regional jet; the rest the A320.
public enum TrafficType: Int, Sendable, CaseIterable {
    case narrowbody, widebody, regional

    /// The type for an instance from the narrowbody or widebody list, by its seed. A hash of the
    /// seed, not the seed itself, so type and livery are independent.
    public static func of(seed: Float, widebody: Bool) -> TrafficType {
        if widebody { return .widebody }
        let h = (seed * 977.31).truncatingRemainder(dividingBy: 1)
        return h < 0.3 ? .regional : .narrowbody
    }
}

/// A traffic model: its file, how its objects map to parts, and its liveries (base texture name
/// to the livery's file, one map per livery).
public struct TrafficModel: Sendable {
    public let type: TrafficType
    public let file: String
    public let part: @Sendable (String) -> String
    public let liveries: [[String: String]]

    public func load(from directory: URL) throws -> AC3DModel {
        try AC3DParser.parse(try String(contentsOf: directory.appendingPathComponent(file), encoding: .isoLatin1), part: part)
    }

    /// FlightGear's Embraer 175 (E-jet family, GPL-2.0). "nosewheel" marks the nose tyre, whose
    /// centre is the instance origin.
    public static let e175 = TrafficModel(type: .regional, file: "erj175.ac", part: { name in
        if name == "tire.n" { return "nosewheel" }
        if name.hasPrefix("tire") || name.hasPrefix("gear.") { return "gear" }
        return "airframe"
    }, liveries: ["Delta", "UnitedExpress", "AirCanada"].map { ["blank175.png": "\($0).png"] })

    /// FlightGear's Boeing 777-200ER (Syd Adams and others, FGAddon, GPL-2.0). Light cones,
    /// flares and lamp lenses are hidden (the renderer draws its own lights).
    public static let b777 = TrafficModel(type: .widebody, file: "777-200ER.ac", part: { name in
        if name == "FrtWheel" { return "nosewheel" }
        let lamps = [".spot", ".flare", "flash", "nav"]
        if lamps.contains(where: name.hasSuffix) || name.hasPrefix("Beacon") || name.hasPrefix("Strobe")
            || ["navlights", "cabinlighting", "taxiL-on", "Llight0", "Lils", "LandingLights"].contains(name) { return "hidden" }
        return "airframe"
    }, liveries: ["AAL", "UAL", "DAL", "ANA"].map { ["Liveries-200/paint1.png": "\($0).png"] })
}
