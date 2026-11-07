# Progress

What is done, what is a placeholder, and what is next. Honest status only: anything not verified says so.

Last updated: 2026-11-07.

## Current milestone: M1 Renderer core (code complete; device measurements outstanding)

### M1 report (2026-11-07), against PLAN.md section 13

1. **Metal renderer, HDR, reverse-Z, floating origin: met.** `CAMetalLayer` driven by `CAMetalDisplayLink` behind the HUD; HDR `rgba16Float`; reverse-Z infinite projection; Double world positions drawn camera-relative. Automated test: a comb of 2 cm slats renders pixel-identical (under 0.1% of pixels changed) at 50 km and 5,000 km from the origin, and the same scene with the floating origin disabled breaks (proves the test can fail). Runs on the iPhone 17 Pro and iPad simulators; on the phone the build installs but has **not run yet** (phone locked).
2. **Sky and sun: met, with one substitution.** Sun position tested against NREL SPA (stronger than the NOAA calculator named in the plan) within 0.1 degrees at six places and times. Hillaire 2020 atmosphere. Renders at morning, noon, sunset, dusk and night are in `artifacts/renders/scene-*.png` (Mac GPU, same renderer code as the app). Not yet: stars and moon (night sky is black), planned for M7.
3. **Aerial perspective, ground, runway markings: met.** Ground is procedural Sonoran desert (no imagery until M4). KPHX 8/26 with precision-runway markings; dimensions follow FAA AC 150/5340-1 **as recalled**, to be checked against the circular in M5. A top-down render caught and fixed vertically flipped numerals.
4. **Test aircraft: met, placeholder quality.** FlightGear C172P (GPL-2.0), textured, GGX shading, sky reflections, glass pass, sun shadow map. Placeholder: no normal maps, no control-surface animation, no livery system (M6).
5. **MetalFX: implemented, verified on the Mac, not yet on the phone.** Temporal (jittered, depth and motion vectors), spatial, and bilinear fallback, switchable in Settings. Mac GPU test: temporal upscaling of a static scene lands closer to the native image than bilinear (error 1.09 vs 1.40), and the flipped jitter sign is clearly worse (1.89), so the sign is right. The iOS Simulator SDK has no MetalFX, so the simulator always uses the bilinear path.
6. **Frame-time overlay: implemented; device numbers not measured yet.** Shows fps, GPU time per stage, CPU encode time, render and output resolution, upscaler. The simulator reports GPU times near zero (no real GPU timestamps there). `-FlightLogStats YES` prints the same numbers to the device console.
7. **Signposts: implemented; Instruments trace not captured yet.** `OSSignposter` intervals for the frame and each encode stage.

Deferred from the plan's renderer section: bloom (not in the M1 criteria), stars and moon (M7).

## M0 report (2026-11-07): done

1. **Git and .gitignore: met.** Commit `707de8b`. The staged tree was audited before committing: no local config, profiles, certificates, keys, team IDs or email addresses are tracked.
2. **Project: met.** `project.yml` generates `Flight.xcodeproj`. Swift 6, strict concurrency complete, landscape only, iPhone and iPad. Bundle ID changed to `com.shreyas.flightsim` because `com.shreyas.flight` is held by the free team (PLAN.md section 1).
3. **Packages: met.** FlightKit has 12 module targets, each with a test target (17 tests). Tools has a stub CLI with 2 tests. Only SimCore geodesy is real code; everything else is a labeled stub.
4. **Simulators: met.** Launches on the iPhone 17 Pro and an iPad Pro 13-inch (M5) simulator and is still running 4 s later. Screenshots are in `artifacts/verify/20261107-150003/` (gitignored).
5. **verify.sh: met.** Shown to fail (exit 1, with the failing assertion printed) when one geodesy expectation was moved by 10 cm, and when a crash was injected at app launch ("app not running ... (crashed?)"). A first draft could exit silently with no message; it now has an error trap.
6. **Device: corrected 2026-11-07.** The original M0 claim ("installed and launched on the iPhone 18 Pro Max over Wi-Fi") was wrong for the gate: `verify.sh` picked the first "connected" iPhone from `devicectl`, which was the booted iPhone 17 Pro *simulator*, so its device step built and installed onto the simulator. The app did reach the real phone twice, both times through manual `devicectl` commands with the phone's exact ID. Fixed: the gate now selects physical devices only and refuses a stale or non-device binary. First genuine gate run on the phone: `artifacts/verify/20261107-160347` (built, installed, launched, running).
7. **Docs: met.** `PROGRESS.md` and `ASSETS_NEEDED.md` are current. `ATTRIBUTIONS.md` was dropped at your request.

Build warnings: 1, the deprecated `UIRequiresFullScreen`, kept on purpose (see Known issues).

## Module status

| Module | Status |
|---|---|
| SimCore | **Partial.** WGS84 geodesy (geodetic to ECEF and back) implemented and tested against PROJ reference values. SimState, time and signposts not started. |
| CJSBSim | **Placeholder (M0 stub).** C API header with `jsb_version()` returning "stub"; compiled as C++17. JSBSim sources arrive in M2. |
| FlightModel | **Placeholder (M0 stub).** Links CJSBSim; no physics. |
| Weather, Nav, Autopilot, Airports, Terrain, Aircraft, Renderer, Traffic, ATC | **Placeholder (M0 stubs).** Module identity only. |
| UI | **Prototype.** Original "glass cockpit" design language (PLAN.md section 8). In-flight HUD with working touch controls: thrust lever with idle/reverse gate, trim, detented flaps and spoilers, gear with a 6 s transit and position lights, parking brake, mode annunciator, autopilot panel with steppable targets, lights and camera panels. All values are **demo data**; the world behind is a flat gradient stand-in. Map, ATC and Settings panels say "not built yet". Main menu restyled; only Free Flight is active. |
| Tools (`flight-tools`) | **Placeholder (M0 stub).** Declares `nav-import`, `airport-import`, `terrain-bake`, `asset-cook`; each prints "not implemented". |

## Placeholders in the app today

The HUD is labeled on screen "PROTOTYPE · DEMO DATA · 3D VIEW ARRIVES IN M1": its numbers are fixed demo values and the sky and ground are a flat gradient. The main menu is labeled "PLACEHOLDER MENU · M0". No aircraft, terrain, airports or flight model exist yet.

## Known issues

- iPad landscape lock relies on `UIRequiresFullScreen`, deprecated since iOS 26 (one build warning). Verified on 2026-11-07 that iPadOS 27 still honors it: without it the iPad simulator rendered the app in portrait. When Apple stops honoring it, the iPad needs a different approach (likely a rotate-to-landscape prompt).

## Next

M1 Renderer core (criteria in `PLAN.md` section 13).
