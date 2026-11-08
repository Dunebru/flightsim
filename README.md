# Flight

A flight simulator for iPhone and iPad. Swift, Metal, and JSBSim for the flight dynamics. Personal project, still in progress. [PLAN.md](PLAN.md) is the plan.

## Status

Runs at 60 fps on an iPhone 18 Pro Max. Phoenix (KPHX) and LA (KLAX) are built from OpenStreetMap. You can fly a Cessna 172P or an A320, both with FlightGear cockpits and JSBSim flight models. There's weather, an autopilot with ILS, AI traffic and ATC. Plenty is still rough; [PROGRESS.md](PROGRESS.md) has the details.

UI notes are in [DESIGN.md](DESIGN.md).

## Building

You need Xcode 27 with the iOS 27 SDK and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. `scripts/fetch-assets.sh` downloads the test aircraft model, pinned to an exact upstream commit and checked against SHA-256 hashes.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Apple Developer team ID. That file is gitignored.
3. `scripts/verify.sh` regenerates the Xcode project, runs every test, builds the app, and runs it on the iPhone and iPad simulators with screenshots. Add `--device` to also install and launch on a connected iPhone.

## Layout

`App/` is the thin app target. `Packages/FlightKit/` holds one target per engine module (SimCore, FlightModel, Renderer, UI and the rest). `Tools/` is for the offline data importers. `scripts/` has the build gate and the asset fetcher.

## Third-party components

[JSBSim](https://github.com/JSBSim-Team/jsbsim) v1.3.3 is vendored unmodified in `Packages/FlightKit/Sources/CJSBSim/jsbsim` under the LGPL-2.1 (license text alongside it in `COPYING.LGPL`). The JSBSim `c172p` and `A320` aircraft definitions, engines and systems ship in `Packages/FlightKit/Sources/FlightModel/Resources/JSBSim`; the A320 definition is modified, and every change is listed in its `TUNING.md`.

The FlightGear [Cessna 172P](https://github.com/c172p-team/c172p) and [A320 family](https://github.com/legoboyvdlp/A320-family) models, cockpits, animation files and the A320's CFM56 engine recordings (all GPL-2.0) are downloaded by `scripts/fetch-assets.sh`, pinned to exact commits and checked against SHA-256 hashes; they are not part of this repository. Airport and city data comes from OpenStreetMap (ODbL), navigation data from the FAA's NASR (public domain), the magnetic model from NOAA's WMM2025 (public domain) and the star catalogue from the Yale Bright Star Catalogue.

## License

GPL-2.0-or-later, see [LICENSE](LICENSE). Picked so it stays compatible with the GPL-2.0 FlightGear models and LGPL JSBSim. Third-party stuff keeps its own license (above).

This project is not affiliated with Infinite Flight, Microsoft Flight Simulator, FlightGear, Apple, Airbus or Textron Aviation.
