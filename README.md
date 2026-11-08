# Flight

A flight simulator for iPhone and iPad, written in Swift with a Metal renderer and JSBSim flight dynamics. It is a personal project and a work in progress: the plan, the honest quality ceiling for each area, and the milestone acceptance criteria are in [PLAN.md](PLAN.md), and what is actually done (and what is still a placeholder) is in [PROGRESS.md](PROGRESS.md).

## Status

Scaffolding (M0) and the renderer core (M1) are done and measured on an iPhone 18 Pro Max: a physically based sky and atmosphere, a marked runway, a test Cessna 172 with sun shadows, a floating origin, and MetalFX upscaling at 60 fps. Flight dynamics (M2) is in progress: JSBSim runs on its own 120 Hz thread and the Cessna 172P and a tuned generic A320 can be flown with tilt or a game controller. Terrain, airports, the aircraft fleet, weather, navigation, ATC and traffic are later milestones.

The in-flight interface follows Apple's platform design language (Liquid Glass, SF Pro, Control Center style controls) arranged the way mobile flight sims are usually laid out. See [DESIGN.md](DESIGN.md).

## Building

You need Xcode 27 with the iOS 27 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. `scripts/fetch-assets.sh` downloads the test aircraft model, pinned to an exact upstream commit and checked against SHA-256 hashes.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Apple Developer team ID. That file is gitignored.
3. `scripts/verify.sh` regenerates the Xcode project, runs every test, builds the app, and runs it on the iPhone and iPad simulators with screenshots. Add `--device` to also install and launch on a connected iPhone.

## Layout

`App/` is the thin app target. `Packages/FlightKit/` holds one target per engine module (SimCore, FlightModel, Renderer, UI and the rest). `Tools/` is for the offline data importers. `scripts/` has the build gate and the asset fetcher.

## Third-party components

[JSBSim](https://github.com/JSBSim-Team/jsbsim) v1.3.3 is vendored unmodified in `Packages/FlightKit/Sources/CJSBSim/jsbsim` under the LGPL-2.1 (license text alongside it in `COPYING.LGPL`). The JSBSim `c172p` and `A320` aircraft definitions, engines and systems ship in `Packages/FlightKit/Sources/FlightModel/Resources/JSBSim`; the A320 definition is modified, and every change is listed in its `TUNING.md`.

The FlightGear [Cessna 172P](https://github.com/c172p-team/c172p) 3D model (GPL-2.0) is downloaded by `scripts/fetch-assets.sh` and is not part of this repository.

## License

The project's own code does not carry an open-source license yet, so all rights are reserved by default. This project is not affiliated with Infinite Flight, Microsoft Flight Simulator, Apple, Airbus or Textron Aviation.
