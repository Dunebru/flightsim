// swift-tools-version: 6.2
// Offline macOS tools: nav-import, airport-import, terrain-bake, asset-cook (PLAN.md section 3.5).

import PackageDescription

let package = Package(
    name: "Tools",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "flight-tools", targets: ["flight-tools"]),
    ],
    dependencies: [
        .package(path: "../Packages/FlightKit"),
    ],
    targets: [
        .target(
            name: "FlightToolsCore",
            dependencies: [.product(name: "FlightKit", package: "FlightKit")]
        ),
        .executableTarget(name: "flight-tools", dependencies: ["FlightToolsCore"]),
        .testTarget(name: "FlightToolsTests", dependencies: ["FlightToolsCore"]),
    ]
)
