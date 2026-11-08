// swift-tools-version: 6.2
// FlightKit: every engine module of the simulator, one library target per module.
// See PLAN.md section 3.2 for responsibilities. Dependencies only point "down" the list.

import PackageDescription

/// Swift modules and their in-package dependencies, in dependency order.
let modules: [(name: String, deps: [String])] = [
    ("SimCore", []),
    ("FlightModel", ["SimCore", "CJSBSim"]),
    ("Weather", ["SimCore"]),
    ("Nav", ["SimCore"]),
    ("Autopilot", ["SimCore", "FlightModel", "Nav"]),
    ("Airports", ["SimCore", "Nav", "Terrain"]),
    ("Terrain", ["SimCore"]),
    ("Aircraft", ["SimCore"]),
    ("Renderer", ["SimCore", "Terrain", "Airports", "Aircraft", "Weather"]),
    ("Traffic", ["SimCore", "Nav", "Airports"]),
    ("ATC", ["SimCore", "Nav", "Airports", "Traffic"]),
    ("UI", ["SimCore", "FlightModel", "Weather", "Nav", "Autopilot", "Airports",
            "Terrain", "Aircraft", "Renderer", "Traffic", "ATC"]),
]

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

var targets: [Target] = [
    // JSBSim v1.3.3 (LGPL-2.1, vendored unmodified in Sources/CJSBSim/jsbsim) plus a C wrapper.
    // Compiled exactly as JSBSim's CMake does: everything in src/ except the command-line
    // program, with the bundled expat.
    .target(
        name: "CJSBSim",
        path: "Sources/CJSBSim",
        exclude: [
            "jsbsim/COPYING.LGPL", "jsbsim/JSBSIM_RELEASE.txt",
            "jsbsim/GeographicLib/LICENSE.txt", "jsbsim/models/atmosphere/MSIS/DOCUMENTATION", "jsbsim/simgear/xml/COPYING",
            "jsbsim/simgear/xml/xmltok_impl.c", "jsbsim/simgear/xml/xmltok_ns.c",
            // Not built by JSBSim's CMake either (optional simplex trim).
            "jsbsim/initialization/FGSimplexTrim.cpp", "jsbsim/initialization/FGTrimAnalysis.cpp",
            "jsbsim/initialization/FGTrimAnalysisControl.cpp", "jsbsim/initialization/FGTrimmer.cpp",
            "jsbsim/math/FGNelderMead.cpp",
            // Standalone test program for the MSIS atmosphere (defines main).
            "jsbsim/models/atmosphere/MSIS/nrlmsise-00_test.c",
        ],
        sources: ["jsbsim", "wrapper"],
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("jsbsim"),
            .headerSearchPath("jsbsim/simgear/xml"),
            .define("HAVE_EXPAT_CONFIG_H"),
            .unsafeFlags(["-w"]),
        ],
        cxxSettings: [
            .headerSearchPath("jsbsim"),
            .define("JSBSIM_VERSION", to: "\"1.3.3\""),
            .define("JSBSIM_STATIC_LINK"),
            // SwiftPM defines DEBUG=1 in debug builds; JSBSim has an enum case named DEBUG.
            .unsafeFlags(["-w", "-UDEBUG"]),
        ]
    ),
]
for module in modules {
    // UI is the only UI-facing module: it gets main-actor-by-default isolation.
    // Engine modules stay nonisolated so callers choose where their work runs.
    let isUI = module.name == "UI"
    // Metal shader sources ship as resources and are compiled at load (ShaderLibrary), so the
    // same code path works under `swift test` on the Mac and in the iOS app.
    let resources: [Resource]? = switch module.name {
    case "Renderer": [.copy("Shaders")]
    case "FlightModel": [.copy("Resources/JSBSim")]
    default: nil
    }
    targets.append(.target(
        name: module.name,
        dependencies: module.deps.map { .target(name: $0) },
        resources: resources,
        swiftSettings: isUI ? swiftSettings + [.defaultIsolation(MainActor.self)] : swiftSettings
    ))
    targets.append(.testTarget(
        name: "\(module.name)Tests",
        dependencies: [.target(name: module.name)],
        swiftSettings: swiftSettings
    ))
}

let package = Package(
    name: "FlightKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "FlightKit", targets: modules.map(\.name)),
    ],
    targets: targets,
    cxxLanguageStandard: .cxx17
)
