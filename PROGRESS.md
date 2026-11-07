# Progress

What is done, what is a placeholder, and what is next. Honest status only: anything not verified says so.

Last updated: 2026-11-07.

## Current milestone: M0 Scaffolding

See `PLAN.md` section 13 for the acceptance criteria. Status per criterion is in the M0 report below.

## M0 report (2026-11-07): done

1. **Git and .gitignore: met.** Commit `707de8b`. The staged tree was audited before committing: no local config, profiles, certificates, keys, team IDs or email addresses are tracked.
2. **Project: met.** `project.yml` generates `Flight.xcodeproj`. Swift 6, strict concurrency complete, landscape only, iPhone and iPad. Bundle ID changed to `com.shreyas.flightsim` because `com.shreyas.flight` is held by the free team (PLAN.md section 1).
3. **Packages: met.** FlightKit has 12 module targets, each with a test target (17 tests). Tools has a stub CLI with 2 tests. Only SimCore geodesy is real code; everything else is a labeled stub.
4. **Simulators: met.** Launches on the iPhone 17 Pro and an iPad Pro 13-inch (M5) simulator and is still running 4 s later. Screenshots are in `artifacts/verify/20261107-150003/` (gitignored).
5. **verify.sh: met.** Shown to fail (exit 1, with the failing assertion printed) when one geodesy expectation was moved by 10 cm, and when a crash was injected at app launch ("app not running ... (crashed?)"). A first draft could exit silently with no message; it now has an error trap.
6. **Device: met.** Built, installed and launched on the iPhone 18 Pro Max over Wi-Fi (CoreDevice transport `localNetwork`) and confirmed running. Not captured: a screenshot from the phone, because `devicectl` cannot take one. Look at the phone itself.
7. **Docs: met.** `PROGRESS.md` and `ASSETS_NEEDED.md` are current. `ATTRIBUTIONS.md` was dropped at your request.

Build warnings: 1, the deprecated `UIRequiresFullScreen`, kept on purpose (see Known issues).

## Module status

| Module | Status |
|---|---|
| SimCore | **Partial.** WGS84 geodesy (geodetic to ECEF and back) implemented and tested against PROJ reference values. SimState, time and signposts not started. |
| CJSBSim | **Placeholder (M0 stub).** C API header with `jsb_version()` returning "stub"; compiled as C++17. JSBSim sources arrive in M2. |
| FlightModel | **Placeholder (M0 stub).** Links CJSBSim; no physics. |
| Weather, Nav, Autopilot, Airports, Terrain, Aircraft, Renderer, Traffic, ATC | **Placeholder (M0 stubs).** Module identity only. |
| UI | **Placeholder.** Main menu with inert buttons; final original HUD and menu design arrives in M3. |
| Tools (`flight-tools`) | **Placeholder (M0 stub).** Declares `nav-import`, `airport-import`, `terrain-bake`, `asset-cook`; each prints "not implemented". |

## Placeholders in the app today

Everything visible is a placeholder: the main menu is a plain list, labeled "Placeholder menu (M0)" on screen. No aircraft, terrain, airports or flight model exist yet.

## Known issues

- iPad landscape lock relies on `UIRequiresFullScreen`, deprecated since iOS 26 (one build warning). Verified on 2026-11-07 that iPadOS 27 still honors it: without it the iPad simulator rendered the app in portrait. When Apple stops honoring it, the iPad needs a different approach (likely a rotate-to-landscape prompt).

## Next

M1 Renderer core (criteria in `PLAN.md` section 13).
