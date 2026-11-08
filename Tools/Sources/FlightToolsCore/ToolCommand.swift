import Foundation
import Terrain

/// Subcommands of `flight-tools`. Commands not built yet say so and name their milestone.
public enum ToolCommand: String, CaseIterable, Sendable {
    case navImport = "nav-import"
    case airportImport = "airport-import"
    case terrainBake = "terrain-bake"
    case assetCook = "asset-cook"

    public var plannedFor: String? {
        switch self {
        case .navImport: "M5/M8"
        case .airportImport: "M5"
        case .terrainBake: nil
        case .assetCook: "M6"
        }
    }

    public static var usage: String {
        "usage: flight-tools <command>\n" + allCases.map { c in
            if let m = c.plannedFor { return "  \(c.rawValue)  (not implemented, planned for \(m))" }
            return "  \(c.rawValue)  " + (c == .terrainBake
                ? "--dem <raster.bin> --dem-info <gdalinfo.json> --center <lat,lon> --name <name> --out <dir> [--no-imagery]"
                : "")
        }.joined(separator: "\n")
    }
}

/// Runs the tool with command-line arguments (excluding the program name).
/// Returns the process exit code and the text to print.
public func runTool(_ arguments: [String], log: @Sendable @escaping (String) -> Void = { print($0) }) async -> (code: Int32, output: String) {
    guard let first = arguments.first, let command = ToolCommand(rawValue: first) else {
        return (64, ToolCommand.usage)
    }
    if let milestone = command.plannedFor {
        return (69, "\(command.rawValue): not implemented yet (planned for \(milestone))")
    }
    let options = Options(Array(arguments.dropFirst()))
    switch command {
    case .terrainBake:
        guard let dem = options["--dem"], let info = options["--dem-info"], let center = options["--center"],
              let name = options["--name"], let out = options["--out"] else {
            return (64, ToolCommand.usage)
        }
        let parts = center.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return (64, "--center must be lat,lon") }
        do {
            let raster = try DEMRaster(binary: URL(fileURLWithPath: dem), info: URL(fileURLWithPath: info))
            let tiles = BakePlan.airportRegion.tiles(latitude: parts[0], longitude: parts[1])
            log("plan: \(tiles.count) tiles")
            let baker = TerrainBaker(dem: raster, output: URL(fileURLWithPath: out), name: name,
                                     downloadImagery: !options.has("--no-imagery"))
            let index = try await baker.bake(tiles: tiles, log: log)
            return (0, "baked \(index.tiles.count) tiles, zoom \(index.minZoom)-\(index.maxZoom), into \(out)")
        } catch {
            return (1, "terrain-bake failed: \(error)")
        }
    default:
        return (69, "\(command.rawValue): not implemented")
    }
}

/// Minimal `--flag value` parser.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--"), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                values[a] = args[i + 1]
                i += 2
            } else {
                flags.insert(a)
                i += 1
            }
        }
    }

    subscript(_ key: String) -> String? { values[key] }
    func has(_ flag: String) -> Bool { flags.contains(flag) || values[flag] != nil }
}
