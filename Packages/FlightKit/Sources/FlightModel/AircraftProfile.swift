/// What the cockpit controls look like for one aircraft, and how they map onto its JSBSim model.
public struct AircraftProfile: Sendable, Hashable, Identifiable {
    /// JSBSim model name (aircraft/<id>/<id>.xml).
    public let id: String
    public let name: String
    /// Flap lever detents, labelled as on the real lever, and the flap command each sends.
    public let flapLabels: [String]
    public let flapCommands: [Double]
    public let hasSpoilers: Bool
    public let retractableGear: Bool
    public let isTurbine: Bool
    /// True while the drawn aircraft is a stand-in (the A320 is a generic narrowbody shape until M6).
    public let visualIsStandIn: Bool
    /// Honest note about the flight model's fidelity, shown in settings.
    public let fidelityNote: String
    /// Angle of attack (degrees) where the stall warning sounds: about 3 degrees below the
    /// model's lift peak (measured by the test pilot: C172P 16.0, A320 17.2).
    public let stallWarningAlpha: Double
    /// Airborne starts on final: calibrated airspeed (knots) and flap lever detent.
    public let approachKnots: Double
    public let approachFlapIndex: Int

    public static let c172 = AircraftProfile(
        id: "c172p", name: "Cessna 172P",
        flapLabels: ["UP", "10", "20", "30"], flapCommands: [0, 1.0 / 3, 2.0 / 3, 1],
        hasSpoilers: false, retractableGear: false, isTurbine: false, visualIsStandIn: false,
        fidelityNote: "JSBSim's reference C172P: the best-validated model in the JSBSim library.",
        stallWarningAlpha: 13,
        approachKnots: 65, approachFlapIndex: 2
    )

    /// The JSBSim library A320 is a generic 2002-era model: flaps 0 to 40 degrees and no slats,
    /// so CONF 1, 2, 3 and FULL map to flaps 10, 15, 20 and 40 degrees. No fly-by-wire laws.
    public static let a320 = AircraftProfile(
        id: "A320", name: "Airbus A320",
        flapLabels: ["0", "1", "2", "3", "FULL"], flapCommands: [0, 10.0 / 40, 15.0 / 40, 20.0 / 40, 1],
        hasSpoilers: true, retractableGear: true, isTurbine: true, visualIsStandIn: true,
        fidelityNote: "Generic JSBSim A320, tuned (see TUNING.md): no slats, no fly-by-wire. Drawn as a generic narrowbody shape until the fleet arrives in M6.",
        stallWarningAlpha: 14,
        approachKnots: 140, approachFlapIndex: 4
    )

    public static let all: [AircraftProfile] = [.c172, .a320]
}
