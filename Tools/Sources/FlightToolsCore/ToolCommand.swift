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
        case .airportImport: nil
        case .terrainBake: nil
        case .assetCook: "M6"
        }
    }

    public static var usage: String {
        "usage: flight-tools <command>\n" + allCases.map { c in
            if let m = c.plannedFor { return "  \(c.rawValue)  (not implemented, planned for \(m))" }
            if c == .airportImport { return "  \(c.rawValue)  --icao <ICAO> --nasr <dir> --osm-cache <dir> --out <file.json>" }
            return "  \(c.rawValue)  " + (c == .terrainBake
                ? "(--center <lat,lon> | --world <max zoom>) --name <name> --out <dir> [--dem <raster.bin> --dem-info <gdalinfo.json>]\n"
                  + "      [--terrarium-cache <dir> [--terrarium-max-zoom 11]] [--imagery-cache <dir> [--usgs-from-zoom 12]]"
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
        // An option the tool does not know is a mistake, not something to ignore: a mistyped
        // cache path once produced a pack with no imagery and no regional heights.
        let known: Set<String> = ["--dem", "--dem-info", "--center", "--world", "--name", "--out", "--terrarium-cache",
                                  "--terrarium-max-zoom", "--imagery-cache", "--usgs-from-zoom"]
        if let unknown = options.names.first(where: { !known.contains($0) }) {
            return (64, "terrain-bake: unknown option \(unknown)\n" + ToolCommand.usage)
        }
        guard let name = options["--name"], let out = options["--out"] else { return (64, ToolCommand.usage) }
        let tiles: [TileKey]
        if let world = options["--world"].flatMap(Int.init) {
            tiles = BakePlan.world(maxZoom: world)
        } else if let center = options["--center"] {
            let parts = center.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return (64, "--center must be lat,lon") }
            tiles = BakePlan.airportRegion.tiles(latitude: parts[0], longitude: parts[1])
        } else {
            return (64, ToolCommand.usage)
        }
        do {
            var raster: DEMRaster?
            if let dem = options["--dem"], let info = options["--dem-info"] {
                raster = try DEMRaster(binary: URL(fileURLWithPath: dem), info: URL(fileURLWithPath: info))
            }
            log("plan: \(tiles.count) tiles")
            let terrarium = options["--terrarium-cache"].map { TerrariumSource(cache: URL(fileURLWithPath: $0)) }
            let baker = TerrainBaker(dem: raster, terrarium: terrarium,
                                     terrariumMaxZoom: options["--terrarium-max-zoom"].flatMap(Int.init) ?? 11,
                                     output: URL(fileURLWithPath: out), name: name,
                                     imageryCache: options["--imagery-cache"].map { URL(fileURLWithPath: $0) },
                                     usgsFromZoom: options["--usgs-from-zoom"].flatMap(Int.init))
            let index = try await baker.bake(tiles: tiles, log: log)
            return (0, "baked \(index.tiles.count) tiles, zoom \(index.minZoom)-\(index.maxZoom), into \(out)")
        } catch {
            return (1, "terrain-bake failed: \(error)")
        }
    case .airportImport:
        let known: Set<String> = ["--icao", "--nasr", "--osm-cache", "--out"]
        if let unknown = options.names.first(where: { !known.contains($0) }) {
            return (64, "airport-import: unknown option \(unknown)\n" + ToolCommand.usage)
        }
        guard let icao = options["--icao"], let nasr = options["--nasr"], let cache = options["--osm-cache"],
              let out = options["--out"] else { return (64, ToolCommand.usage) }
        do {
            let layout = try await AirportImporter(nasrDirectory: URL(fileURLWithPath: nasr), osmCache: URL(fileURLWithPath: cache))
                .run(icao: icao, log: log)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let url = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(layout).write(to: url)
            return (0, "wrote \(out)")
        } catch {
            return (1, "airport-import failed: \(error)")
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
    /// Every option name given, with or without a value.
    var names: [String] { Array(values.keys) + Array(flags) }
    func has(_ flag: String) -> Bool { flags.contains(flag) || values[flag] != nil }
}
