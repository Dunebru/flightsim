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
    ("Airports", ["SimCore", "Nav"]),
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
    // C++ flight dynamics engine. M0: stub with the final C API shape; M2 adds the JSBSim sources.
    .target(name: "CJSBSim", path: "Sources/CJSBSim"),
]
for module in modules {
    // UI is the only UI-facing module: it gets main-actor-by-default isolation.
    // Engine modules stay nonisolated so callers choose where their work runs.
    let isUI = module.name == "UI"
    // Metal shader sources ship as resources and are compiled at load (ShaderLibrary), so the
    // same code path works under `swift test` on the Mac and in the iOS app.
    let resources: [Resource]? = module.name == "Renderer" ? [.copy("Shaders")] : nil
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
