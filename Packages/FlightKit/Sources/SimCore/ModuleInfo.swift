/// Identifies an engine module and how complete it is, so placeholder code is labeled in code,
/// not just in PROGRESS.md.
public struct ModuleInfo: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        /// No functionality yet; the milestone that implements it.
        case stub(plannedFor: String)
        /// Partially implemented; what is missing.
        case partial(missing: String)
        case complete
    }

    public let name: String
    public let status: Status

    public init(name: String, status: Status) {
        self.name = name
        self.status = status
    }
}

public enum SimCoreModule {
    public static let info = ModuleInfo(name: "SimCore", status: .partial(missing: "SimState, time, signposts (M1, M2)"))
}
