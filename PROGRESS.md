# Progress

What is done, what is a placeholder, and what is next. Honest status only: anything not verified says so.

Last updated: 2026-11-07.

## Current milestone: M0 Scaffolding

See `PLAN.md` section 13 for the acceptance criteria. Status per criterion is in the M0 report below.

## Module status

| Module | Status |
|---|---|
| SimCore | **Partial.** WGS84 geodesy (geodetic to ECEF and back) implemented and tested against PROJ reference values. SimState, time and signposts not started. |
| CJSBSim | **Placeholder (M0 stub).** C API header with `jsb_version()` returning "stub"; compiled as C++17. JSBSim sources arrive in M2. |
| FlightModel | **Placeholder (M0 stub).** Links CJSBSim; no physics. |
| Weather, Nav, Autopilot, Airports, Terrain, Aircraft, Renderer, Traffic, ATC | **Placeholder (M0 stubs).** Module identity only. |
| UI | **Placeholder.** Main menu with inert buttons; not yet the Infinite Flight layout (M3). |
| Tools (`flight-tools`) | **Placeholder (M0 stub).** Declares `nav-import`, `airport-import`, `terrain-bake`, `asset-cook`; each prints "not implemented". |

## Placeholders in the app today

Everything visible is a placeholder: the main menu is a plain list, labeled "Placeholder menu (M0)" on screen. No aircraft, terrain, airports or flight model exist yet.

## Known issues

- iPad landscape lock relies on `UIRequiresFullScreen`, deprecated since iOS 26 (one build warning). Verified on 2026-11-07 that iPadOS 27 still honors it: without it the iPad simulator rendered the app in portrait. When Apple stops honoring it, the iPad needs a different approach (likely a rotate-to-landscape prompt).

## Next

M1 Renderer core (criteria in `PLAN.md` section 13).
