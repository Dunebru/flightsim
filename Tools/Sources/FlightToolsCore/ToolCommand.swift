/// Subcommands of `flight-tools`. Placeholder (M0 stub): each command is declared but not
/// implemented; the milestone that implements it is listed.
public enum ToolCommand: String, CaseIterable, Sendable {
    case navImport = "nav-import"
    case airportImport = "airport-import"
    case terrainBake = "terrain-bake"
    case assetCook = "asset-cook"

    public var plannedFor: String {
        switch self {
        case .navImport: "M5/M8"
        case .airportImport: "M5"
        case .terrainBake: "M4"
        case .assetCook: "M6"
        }
    }

    public static var usage: String {
        "usage: flight-tools <command>\n" + allCases
            .map { "  \($0.rawValue)  (not implemented, planned for \($0.plannedFor))" }
            .joined(separator: "\n")
    }
}

/// Runs the tool with command-line arguments (excluding the program name).
/// Returns the process exit code and the text to print.
public func runTool(_ arguments: [String]) -> (code: Int32, output: String) {
    guard let first = arguments.first, let command = ToolCommand(rawValue: first) else {
        return (64, ToolCommand.usage)
    }
    return (69, "\(command.rawValue): not implemented yet (planned for \(command.plannedFor))")
}
