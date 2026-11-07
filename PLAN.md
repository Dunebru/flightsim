# Flight: Plan

Personal iOS/iPadOS flight simulator. Infinite Flight is the UX blueprint; Microsoft Flight Simulator is the visual ceiling we measure against, not one we can reach. This file holds architecture, decisions, honest quality ceilings, risks and milestone acceptance criteria. Status lives in `PROGRESS.md`.

Last updated: 2026-11-07 (pre-approval draft).

---

## 1. Environment, as inspected

| Item | Finding |
|---|---|
| Mac | Apple M5 Max, 36 GB RAM, macOS 27.0 |
| Xcode | 27.0 (27A266a), iOS SDK 27.0, Swift 6.4 |
| Simulators | iPhone 17 Pro, iPhone SE (3rd gen), iOS 27.0. An iPad simulator will be created with `simctl create` in M0. |
| Physical device | **iPhone 18 Pro Max** (iPhone19,3), iOS 27.0.1, 256 GB, Developer Mode on. Connected and verified 2026-11-07: a signed test app built, installed and launched via `xcrun devicectl`. (An older iPhone 15 Pro Max pairing record also exists on this Mac; it is not the target.) RAM and GPU core count are not reported by `devicectl`; the frame budget is measured in M1 rather than assumed. |
| Signing | **Working on the paid team `7SQH…`** (verified 2026-11-07 after the Program License Agreement was accepted): device build signed with an Apple Development certificate, one-year profile. Bundle ID is **`com.shreyas.flightsim`**, because `com.shreyas.flight` was registered to the free Personal Team `377T…` during an earlier signing test and bundle IDs are unique across teams. |
| Tools present | `xcodegen`, `git`, `brew`, `python3` |
| Tools missing | `cmake` (not needed, see 4.3), `gdal` (needed by offline tools, M4), `git-lfs` (not needed, see 9), Blender (needed for model conversion, M6) |
| The `iOS app` folder | Does not exist on the Desktop. Nothing is needed from it: automatic signing with your signed-in Apple ID is enough. |

The team ID goes in `Config/Local.xcconfig`, which is gitignored. No certificate, profile, key or token is ever copied into the repo.

---

## 2. What "as close to Infinite Flight" and "MSFS ceiling" mean in practice

Being direct about the gap up front, so nothing later reads as a surprise.

**Achievable, with free data, on an iPhone 18 Pro Max:**
UI, layout, controls and flow that feel like Infinite Flight. Flight models that are genuinely physics-based (JSBSim), with the C172 close to published numbers and the airliners tuned to published stall, climb and approach numbers. A physically based sky (Hillaire-style atmosphere) and volumetric clouds that look better than Infinite Flight's. Global terrain with 30 m elevation and 10 m satellite color that looks good from about 3,000 ft and up. Sharp 60 cm aerial imagery in the US. Procedurally generated airports from real layout data that are correct in geometry, markings and lighting, with generic (not lookalike) terminals. A US nav database with real SIDs, STARs and approaches.

**Not achievable with free data, and not hidden:**
Photogrammetry cities and terrain (MSFS uses petabytes of Bing/Azure data; nothing comparable is licensable for a personal offline app). Low-altitude photoreal imagery outside the US (10 m Sentinel-2 is blurry below about 2,000 ft). Worldwide SIDs, STARs and approaches (see 7.4: Navigraph will not license data for a home-built app). Type-accurate 777 or 747-8 flight models (none exist in JSBSim form). Hand-modeled lookalike terminals for all 20 airports at MSFS quality (that is months of 3D art per airport).

**iPhone ceiling**, independent of data: the iPhone 18 Pro Max has roughly two generations more GPU than the A17 Pro this plan first assumed, but phones still throttle. Planning budget until M1 measures it: about 10 to 12 ms of sustained GPU time per 60 fps frame. That pays for one high-detail aircraft, terrain, atmosphere, half-resolution clouds and a light post stack, rendered at about 65 to 75 percent of native resolution and upscaled with MetalFX. It does not pay for MSFS-style full-resolution ray-marched clouds, screen-space global illumination, or dense 3D cities. Sustained play will thermally throttle within 10 to 20 minutes; dynamic resolution and a 30 fps mode are core features, not afterthoughts. 120 Hz ProMotion is available but is not a target for the 3D view.

---

## 3. Architecture

### 3.1 Repository layout

```
flightsim/
  project.yml                 XcodeGen spec (the .xcodeproj is generated, not committed)
  Config/Base.xcconfig        shared build settings
  Config/Local.xcconfig       DEVELOPMENT_TEAM etc. (gitignored; template committed as Local.xcconfig.example)
  App/                        thin app target: entry point, Info.plist, asset catalog, launch screen
  Packages/FlightKit/         one local Swift package, one library target per module (3.2)
  Vendor/JSBSim/              JSBSim v1.3.3 source, pinned, unmodified except a documented patch list
  Tools/                      separate Swift package of macOS command-line tools (3.5)
  Resources/                  small cooked assets that ship in the bundle (base aircraft, base nav DB)
  Data/                       raw downloads and cooked scenery packs (gitignored, reproducible by Tools)
  scripts/verify.sh           build, test, run, screenshot
  PLAN.md PROGRESS.md ASSETS_NEEDED.md
```

**Change from the brief:** one local package with eleven targets instead of eleven packages. Same module boundaries and access control, one `Package.swift`, one dependency graph, far less boilerplate. Targets can be split into separate packages later with no code change.

### 3.2 Modules (FlightKit targets)

Dependencies only point downward in this list.

| Target | Responsibility |
|---|---|
| `CJSBSim` | C++ target: JSBSim sources plus a small `extern "C"` wrapper (`jsb_create`, `jsb_load_aircraft`, `jsb_set/get_property`, `jsb_step`). A C API rather than Swift C++ interop keeps Swift 6 strict concurrency and build times simple. |
| `SimCore` | Shared math (double-precision geodesy: WGS84, ECEF, ENU, great circle), units, time, the `SimState` snapshot type, signposts. |
| `FlightModel` | Swift wrapper around `CJSBSim`. Owns the 120 Hz physics thread, control inputs, ground reactions, failures, published-number tests. |
| `Weather` | METAR/TAF fetch and parse, GFS winds via Open-Meteo, interpolation to aircraft position, turbulence and gust model feeding `FlightModel`, cloud layer description feeding `Renderer`. |
| `Nav` | Nav database (GRDB/SQLite), fixes, navaids, airways, procedures, flight plan model, route math, holds. |
| `Autopilot` | Mode logic (AP, FD, HDG, ALT, VS, SPD, LNAV, VNAV, LOC/GS/APPR, A/THR, autoland), PID loops on top of `FlightModel`. Pure Swift, fully unit-tested. |
| `Airports` | Airport database, runtime airport mesh generation from cooked layout data, lighting definitions, gates. |
| `Terrain` | Tile quadtree, streaming, decode, memory budget, height queries for physics and ground collision. |
| `Aircraft` | Cooked model loading, animation rig (control surfaces, gear, flaps, spoilers, reversers, fans/props), lights, livery system, cockpit instrument anchors. |
| `Renderer` | Metal frame graph, atmosphere, clouds, terrain, aircraft, airport, lights, post processing, MetalFX, frame-time overlay. |
| `ATC` | Offline ATC state machine, phraseology generator, AVSpeechSynthesizer. Behind a `TrafficSource` / `ATCSession` protocol so a future multiplayer backend can slot in. |
| `Traffic` | AI traffic scheduling, taxi routing on the airport graph, simplified kinematic flight paths (not JSBSim per aircraft). |
| `UI` | All SwiftUI: menus, Free Flight setup, HUD, panels, settings, logbook. Talks to the sim through one `@Observable` `FlightSession` on the main actor. |

`ATC` and `Traffic` are separate because traffic is needed by the map and renderer even with ATC off.

### 3.3 Threading and Swift 6 concurrency

- **Main actor:** SwiftUI, input gathering (touch, CoreMotion, GameController), `FlightSession`.
- **Physics thread:** one dedicated `Thread` at user-interactive QoS running JSBSim at a fixed 120 Hz with an accumulator. JSBSim is not thread-safe, so the `FDMExec` instance is confined to this thread. Inputs come in and `SimState` snapshots go out through a `Mutex` (Synchronization framework) protected double buffer. This is a deliberate non-actor design: an actor hop per physics step costs more than the step itself.
- **Render:** `CAMetalLayer` driven by `CAMetalDisplayLink` (lets us choose 60, 30 or ProMotion 120 and observe deadlines). Renderer interpolates between the two newest physics snapshots so motion is smooth at any frame rate.
- **Streaming:** Swift concurrency tasks for tile I/O and decode, with a fixed concurrency width; GPU uploads via a shared-storage staging ring, no per-frame allocation.
- **Strict concurrency:** Swift 6 language mode everywhere. Types crossing threads are `Sendable` value types. The few `@unchecked Sendable` boxes (physics core, GPU resource pools) are listed in `PLAN.md` with the invariant that makes them safe.

### 3.4 Rendering design

- **Precision:** Earth-scale coordinates in double (ECEF), rendered camera-relative in float ("floating origin"), reverse-Z infinite projection. Without this, jitter appears at a few km from origin.
- **API:** Metal 3 baseline. Metal 4 and the iOS 26 MetalFX additions (frame interpolation, temporal denoised scaler) are used only where `supportsDevice` / `supportsMetal4FX` return true on the phone, checked at runtime and recorded in M1.
- **Frame:** depth prepass for terrain and aircraft, forward+ shading with clustered lights (runway and approach lights are thousands of point sprites, the aircraft's landing lights are real spot lights), HDR `rgba16Float`, then atmosphere/aerial perspective, clouds composite, bloom, tone map (AgX or ACES fit), MetalFX temporal upscale, UI.
- **Atmosphere:** Hillaire 2020 LUTs (transmittance, multi-scattering, sky-view, aerial perspective volume). Sun and moon from date, time, lat, lon (NOAA solar algorithm, Meeus lunar). Stars from a small bundled catalog (Yale Bright Star, public domain).
- **Clouds:** ray-marched volumetric layers parameterized by METAR layers (coverage, base, type), rendered at quarter resolution with temporal reprojection and upsampling. Cirrus as textured layers. God rays as a screen-space radial pass.
- **Upscaling:** MetalFX temporal scaler (in iOS since iOS 16) with jittered projection; spatial scaler as a cheaper fallback; dynamic resolution driven by GPU frame time and `ProcessInfo.thermalState`. MetalFX is not available in the iOS Simulator, so the simulator path uses a bilinear upscale and simulator frame times are never reported as performance numbers.
- **Profiling:** `os_signpost` intervals per pass and per physics step, `MTLCounterSampleBuffer` GPU timings shown in the on-screen overlay.

### 3.5 Offline tools (Tools package, runs on the Mac)

| Tool | Input | Output |
|---|---|---|
| `nav-import` | OurAirports CSV, FAA NASR CSV, FAA CIFP ARINC 424 | `nav.sqlite` (GRDB schema shared with the app) |
| `airport-import` | OSM `aeroway` via Overpass, plus OurAirports/NASR runways | cooked airport layout packs (runway/taxiway polygons, markings, light positions, gate positions, taxi graph) |
| `terrain-bake` | Copernicus GLO-30, EOX/NAIP imagery, ESA WorldCover, NASA Black Marble | tiled scenery packs (height + ASTC color + land class + night lights) |
| `asset-cook` | glTF/GLB (FBX and AC3D converted to glTF via Blender CLI first) | `.flm` model: interleaved meshes, 3+ LODs (meshoptimizer, MIT), ASTC textures, named animation nodes, light and instrument anchors |

Cooking into our own binary format also satisfies the paid-model licenses that forbid shipping raw extractable model files.

### 3.6 Data storage on device

Scenery is not "global on device". Base layer bundled or downloaded once: global elevation and imagery at coarse levels (roughly 300 to 600 MB). Detail comes as region packs baked on the Mac (for example "Southwest US" for KPHX and KLAX) and copied to the app container with `xcrun devicectl device copy to` or the Files app. Roughly 1 to 4 GB per large region at full detail. The app works offline with whatever packs are installed and falls back to the base layer elsewhere. Your iPhone's free storage decides how many regions fit.

---

## 4. Key technical decisions

### 4.1 Project generation
XcodeGen, because a hand-edited `.pbxproj` is unreviewable. `project.yml` is committed; the generated project is not.

### 4.2 Deployment target
iOS 27.0 (the phone runs 27.0.1), built with the iOS 27 SDK. Landscape only, iPhone and iPad.

### 4.3 JSBSim integration (verified feasible)
The research agent built JSBSim v1.3.3 for iOS arm64 as a static library (about 4.6 MB) and ran JSBSim's own scripted C172 test in the iPhone 17 Pro simulator; it completed the 180 s climb (about 1,443 ft, about 52 KIAS at the end). That validates the plan. Integration detail:
- Compile the sources directly as a SwiftPM C++17 target (no CMake needed). JSBSim bundles expat, has no other dependencies, and does not use `std::filesystem` or threads.
- Aircraft, engine and system XML files ship in the app bundle; root path set at runtime.
- License: LGPL-2.1 (engine) and GPL (some aircraft files). Obligations trigger only on distribution; this app is never distributed.

### 4.4 Persistence
GRDB 7.x (Swift 6 compatible, verified) for nav and airport databases, because the importer and the app share one schema and SQL queries such as "fixes within 50 nm" matter. SwiftData only for the logbook and settings, if anything; plain `Codable` files may be enough.

### 4.5 Graphics tiers
Low (30 fps, 50 percent render scale, no volumetric clouds), Medium, High (default on iPhone 18 Pro Max), Ultra (iPad/M-series). Auto-downgrade one tier on `thermalState == .serious`.

---

## 5. Aircraft: fleet mapping, sources and honest fidelity

| Slot | Flight model (JSBSim) | Visual model (free first) | Honest fidelity note |
|---|---|---|---|
| Cessna 172 | `c172p` / `c172x` from the JSBSim repo (best-tested aircraft in JSBSim) | FlightGear c172p (GPL, full 3D cockpit, 31 liveries) or Sketchfab "FREE Cessna 172SP" (CC-BY, 187k faces) | Flight model: good. Visual: good with FlightGear cockpit after conversion. |
| A320 | M2: JSBSim repo `A320` (generic 2002-era model, author unknown), tuned to published numbers. Later: evaluate porting the FlightGear A320-family JSBSim FDM (GPL, high fidelity, but depends on FlightGear Nasal scripts, so systems need stubs). | FlightGear A320-family (GPL, cockpit) or Sketchfab "A320-200 with cockpit" (CC-BY, 51k faces) | M2 version is an approximation, labeled as such. Fly-by-wire control laws (normal law) are our own Swift layer, not JSBSim. |
| 737-800 | JSBSim repo `737` (Dave Culp, Aeromatic-based, with test scripts) or FlightGear 737-800YV (GPL) | Sketchfab 737-800 (CC-BY, 42k faces, provenance to verify) | Decent generic jet; tuned to 737-800 numbers. |
| Widebody (747-8 or 777) | **No JSBSim 777 or 747-8 exists.** FlightGear's are YASim, unusable. Only the generic JSBSim `B747` (747-400-class) exists. | Sketchfab "Boeing 747-8i" (66k faces) | Will fly like a generic 747, re-tuned to 747-8 weights and thrust. Labeled approximate. |
| Regional jet | FlightGear E-Jet family (JSBSim, GPL, E170 to E195) **or** JSBSim repo `fokker100` | Sketchfab "Embraer 175/195" (227k faces) | E175 recommended. |
| Turboprop | JSBSim repo `fokker50` (PW125B) or `DHC6`. No ATR or Q400 JSBSim model in the repo; FlightGear ATR72 is JSBSim but has no license file. | Sketchfab "Dash-8 Q400 (with cockpit)" (68k faces) | Recommend ATR 72 or Q400 visuals on an adapted Fokker 50 FDM (similar class), labeled approximate. |

Free Sketchfab airliners are mid quality (40k to 300k faces, few with proper PBR, some likely re-uploads of other people's work). They are good enough to build the pipeline, animation rig and livery system, but not "target quality". The paid shortlist (section 10) is where target quality comes from. Fully modeled cockpits with working gauges are realistic for the C172 and A320 from FlightGear sources; for the others it depends on what you buy.

---

## 6. Visual quality: ceiling per area

| Area | Target | Free data reaches | Gap and what closes it |
|---|---|---|---|
| Sky, sun, moon, stars | Physically based, correct ephemeris | Fully achievable | None. This can beat Infinite Flight. |
| Clouds | Volumetric, METAR-driven | Achievable at quarter res | Full-res MSFS-style clouds exceed the GPU budget. |
| Terrain shape | 30 m global | Copernicus GLO-30 everywhere except gaps over Armenia/Azerbaijan in the AWS copy (fetch those from Copernicus Data Space) | None for a flight sim. |
| Terrain color | Photoreal | 10 m Sentinel-2 cloudless worldwide (EOX, CC BY-NC-SA, fine for non-commercial personal use), 0.6 m NAIP in the US (public domain) | Outside the US, blurry below about 2,000 ft. Closing it needs paid imagery or Google Photorealistic 3D Tiles (online only, see 10.2). Detail textures from land cover hide some blur. |
| Water | Reflective, shoreline | Achievable (land/water mask from WorldCover) | No wave simulation beyond a normal-map ocean. |
| Buildings and roads | 3D near airports and cities | OSM / Overture footprints, procedurally extruded with generic facades | Lookalike landmarks need hand modeling or photogrammetry. |
| Night lighting | City lights | NASA Black Marble (public domain) as an emissive layer, plus OSM road lights near airports | Good from altitude; generic up close. |
| Airports | Correct markings, lighting, signs, gates | Geometry, markings, lighting, signs fully generated from OSM + FAA data | Terminals generic. "Hand-authored top 20" means hand-corrected layouts, gates and lighting plus better generic buildings, not lookalike terminals, unless you buy or commission models. |
| Aircraft | PBR, animations, lights, cockpits | Mid quality free models, good C172 and A320 cockpits | Target quality for the airliners needs purchased models (section 10). |

---

## 7. Data sources (verified 2026-11-07)

License facts that drive decisions are kept here. At your request (2026-11-07) there is no separate `ATTRIBUTIONS.md`.

### 7.1 Airports and nav
- **OurAirports** (public domain): `https://davidmegginson.github.io/ourairports-data/{airports,runways,navaids}.csv`. Updated daily. Worldwide airports, runways and navaids.
- **FAA NASR** (US government work): current cycle 2026-10-29 to 2026-11-26, `https://nfdc.faa.gov/webContent/28DaySub/extra/29_Oct_2026_CSV.zip`. Runways are `APT_RWY.csv` / `APT_RWY_END.csv` inside the APT set.
- **FAA CIFP** (US government work, click-through says "not for aeronautical navigation", which a sim satisfies): `https://aeronav.faa.gov/Upload_313-d/cifp/CIFP_261029.zip`, ARINC 424 v18.
- **OpenStreetMap** (ODbL; obligations only apply to public use or conveyance): Overpass API for airport areas (policy roughly 10k requests/day, under 1 GB/day), Geofabrik extracts for regions. **Overture** buildings (ODbL plus CC BY sources) as a richer footprint set.

### 7.2 Terrain, imagery, land cover
- **Copernicus GLO-30**: `s3://copernicus-dem-30m/` (public, no sign-in), 1x1 degree COGs. Required attribution text recorded.
- **EOX Sentinel-2 cloudless**: WMTS `https://tiles.maps.eox.at/wmts/1.0.0/WMTSCapabilities.xml`, layer `s2cloudless-2025_3857`. 2018+ mosaics are CC BY-NC-SA 4.0; 2016/2017 are CC BY 4.0. **Bulk caching terms are not stated**; EOX asks bulk users to contact cloudless@eox.at. Plan: email them before baking more than a test region (listed in `ASSETS_NEEDED.md` as an action for you, since it should come from you).
- **NAIP**: `s3://naip-visualization` (requester pays, a few dollars per state on your AWS account) or Microsoft Planetary Computer (free). Public domain with attribution.
- **ESA WorldCover** 10 m (CC BY 4.0): `s3://esa-worldcover/v200/2021/map`.
- **NASA Black Marble** night lights (public domain / CC0).
- Ruled out: **Esri World Imagery** and **Mapbox Satellite** both forbid offline export and caching.

### 7.3 Weather
- **aviationweather.gov Data API**: `/api/data/metar?ids=...&format=json`, `/api/data/taf`, bulk `/data/cache/metars.cache.csv.gz`. Tested live. Limit 100 requests/minute.
- **Winds aloft:** the NWS FD/FB text product and `/api/data/windtemp` were **discontinued on 2026-11-03** (NAM retirement). Replacement: **Open-Meteo** JSON (pressure-level winds and temperatures, CC BY 4.0 data, free for non-commercial use) as the default, with NOAA GFS GRIB2 via NOMADS as a fallback if Open-Meteo is unavailable.

### 7.4 Worldwide procedures: a real gap
Navigraph's developer terms say they cannot license nav data to a developer, only to end users, and explicitly prohibit using it for "home projects". So buying a Navigraph subscription does **not** legally give this app worldwide SIDs, STARs and approaches. Options:
1. **US only procedures** from FAA CIFP (free). Outside the US: airports, runways and navaids from OurAirports; flight plans are direct, navaid-to-navaid, with a generated ILS where a runway has a published ILS frequency. **Recommended for v1.**
2. Email Navigraph (dev@navigraph.com) asking for written permission for a single-user private build. Cost about €82/year for Navigraph Unlimited (price from a search snippet, unverified). Low odds but free to ask.
3. Hand-enter procedures for the handful of non-US airports in the top 20 from public AIP charts (published by each country's aviation authority). Hours per airport; feasible for 5 or 6 airports.

---

## 8. Infinite Flight style UI

Recreated from scratch in SwiftUI, from memory of how Infinite Flight behaves; no assets taken from it. Dark translucent panels (`.ultraThinMaterial` over black at about 60 percent), SF Symbols, SF Pro Rounded numerals.

- **Left edge:** vertical throttle slider with a detent and a reverse thrust zone below idle; trim wheel next to it.
- **Right edge:** control cluster: gear, flaps (detented slider with labels), spoilers, brakes, lights.
- **Bottom bar:** tappable, configurable info boxes (IAS, GS, ALT, VS, HDG, AoA, N1, fuel) and the bottom row of buttons: pause, camera, map, autopilot, flight plan, ATC, settings. Panels slide up from the bottom (AP, ATC) or in from the side (map, flight plan), as in Infinite Flight.
- **Controls:** tilt (CoreMotion, calibrate-to-current-attitude), on-screen yoke, virtual joystick; GameController framework for MFi, PlayStation and Xbox controllers; per-axis sensitivity, dead zone and curve.
- **Cameras:** cockpit, chase (spring-damped), tower (nearest tower or airport reference point), wing, free orbit; critically damped transitions between them.

---

## 9. Source control and assets

- `git init` in M0, commit at each milestone and at smaller logical steps.
- Strict `.gitignore`: `Config/Local.xcconfig`, `*.mobileprovision`, `*.p12`, `*.cer`, `*.p8`, `*.pem`, `*.key`, `.env*`, `xcuserdata/`, `DerivedData/`, `build/`, `*.xcodeproj` (generated), `Data/`, `artifacts/`.
- Large binaries (raw downloads, scenery packs, purchased models) never go in git; they are reproducible from Tools plus `ASSETS_NEEDED.md`. Purchased models also stay out of git because their licenses forbid redistribution. No git-lfs needed.
- No remote is configured. If you want one, it should be private; I will not create it without asking.

---

## 10. Hard limits: options and recommendations

### 10.1 Aircraft model quality
1. **Free only** (FlightGear GPL + Sketchfab CC-BY). Cost $0. C172 and A320 good, others mid quality. 
2. **Buy airliner models after M6 shows the free gap.** Shortlist (prices verified on vendor pages): CGTrader 737-800 with interior $299; TurboSquid 777-300ER with cockpit and cabin $479; CGTrader A320 $59 to $79 (some editorial-only); RenderHub 737 MAX $195. Fleet total roughly $600 to $1,200 for exteriors, more with cockpits.
3. Commission custom models. Thousands of dollars. Not recommended.

**Recommendation: option 1 through M6, then decide per aircraft with side-by-side screenshots.**

### 10.2 Photoreal ground
1. **EOX Sentinel-2 + NAIP (free).** Good from altitude everywhere, good close up in the US.
2. **Google Photorealistic 3D Tiles** (Map Tiles API). Real photogrammetry for many cities. Requires network (offline caching is forbidden by the terms), an API key with billing, and per-request costs past the free tier (current pricing unverified). Heavy for an iPhone.
3. Buy commercial imagery (Vantor/Airbus). Far too expensive for personal use.

**Recommendation: option 1.** Revisit option 2 for a city-approach "online mode" after M10 if you want it.

### 10.3 Worldwide procedures
See 7.4. **Recommendation: US procedures from CIFP plus hand-entered procedures for the non-US top 20 airports.**

---

## 11. Signing

Verified 2026-11-07: automatic signing on paid team `7SQH…` produces an Apple Development certificate and a one-year profile; a test device build of `com.shreyas.flightsim` succeeded. The team ID lives only in the gitignored `Config/Local.xcconfig`.

Device install verified 2026-11-07 over cable on the iPhone 18 Pro Max (device registered to the team by `-allowProvisioningDeviceRegistration`). For cable-free installs, tick **Connect via network** for the phone once in Xcode, Window, Devices and Simulators; afterwards it works whenever the phone is unlocked on the same Wi-Fi as the Mac.

---

## 12. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Scope: this brief is several person-years of work for a studio | Certain | Milestones M6 to M10 will land at lower fidelity than the brief | Strict milestone gates; honest placeholder labeling; you choose where depth goes |
| Thermal throttling on the phone | High | Frame drops after 10 to 20 min | Dynamic resolution, tiers, 30 fps mode, measured on device |
| Airliner FDMs are generic | High | Airliners fly "plausibly", not type-accurately | Tune to published numbers with tests; A320 FBW in Swift; mark approximate |
| FlightGear FDM ports need Nasal stubs | Medium | A320-family/E-Jet ports take longer | Start with repo models; port only after M2 tests exist to catch regressions |
| Free model provenance (Sketchfab re-uploads) | Medium | License may not hold | Record source and uploader; prefer FlightGear or paid for anything kept |
| EOX bulk caching terms unknown | Medium | Need permission or smaller cache | Email EOX early; NAIP covers US meanwhile |
| Storage on iPhone | Medium | Fewer regions offline | Region packs, base layer, pack manager in Settings |
| Memory (jetsam) | Medium | Crashes when streaming | Hard budgets, `os_proc_available_memory` checks, increased-memory-limit entitlement (paid team) |
| Swift 6 strictness vs Metal and C++ | Low | Friction | C wrapper for JSBSim; documented `@unchecked Sendable` boxes |
| Phone reachable only by cable until network pairing is enabled | Low | Slower iteration | Section 11 |

---

## 13. Milestones and acceptance criteria

Criteria for M3 to M10 are written in full before each starts; outlines are here so the shape is visible. Each milestone ends with `./scripts/verify.sh` green, screenshots in `artifacts/`, `PROGRESS.md` updated, and a commit.

### M0: Scaffolding
1. `git init`, strict `.gitignore` (section 9); `git status` shows no credential or local-config file after a full build.
2. `project.yml` generates `Flight.xcodeproj`; app target `Flight`, bundle ID `com.shreyas.flightsim`, Swift 6 language mode, strict concurrency complete, landscape only, iPhone and iPad.
3. `Packages/FlightKit` with all module targets from 3.2 (empty stubs allowed, each with one passing test); `Tools` package with a stub CLI.
4. App builds and launches on the iPhone 17 Pro simulator and an iPad simulator, showing a placeholder main menu (labeled placeholder).
5. `./scripts/verify.sh` regenerates the project, builds, runs all tests, installs and launches on the simulator, saves a screenshot, and exits non-zero on any failure. Proven to fail by temporarily breaking a test.
6. Device: `./scripts/verify.sh --device` builds, installs and launches on the iPhone 18 Pro Max via `xcrun devicectl` and confirms the process is running.
7. `PROGRESS.md` and `ASSETS_NEEDED.md` exist and are accurate.

### M1: Renderer core
1. Metal renderer on `CAMetalLayer` + `CAMetalDisplayLink`, HDR, reverse-Z, floating origin; no visible jitter with the camera 50 km from origin (automated check: render a test object at 50 km offset, compare to 0 km render).
2. Physically based sky with correct sun position: unit test of sun azimuth/elevation against NOAA solar calculator values for 3 locations and times within 0.1 degrees; screenshots at dawn, noon, sunset, night.
3. Aerial perspective on a flat textured ground plane and one 6 km runway with correct markings.
4. One test aircraft (C172, from a free licensed glTF, labeled placeholder quality until M6) with PBR shading, rendered on the runway.
5. MetalFX temporal upscaling on device with a runtime toggle; spatial and bilinear fallbacks.
6. Frame-time overlay showing CPU and GPU ms per pass. Report device numbers at native and upscaled resolution; target under 6 ms GPU for this simple scene on the iPhone 18 Pro Max. Simulator numbers not reported as performance.
7. Signposts visible in an Instruments trace (screenshot of the trace).

### M2: Flight dynamics
1. JSBSim v1.3.3 compiled as a SwiftPM target for iOS device, iOS simulator and macOS (tests run on the Mac host for speed).
2. Physics thread at a fixed 120 Hz, decoupled from rendering; test shows step count over 10 s wall time within 1 percent of 1,200, and rendering at 30, 60 and 120 fps changes nothing in the physics output.
3. C172 (`c172p`) published-number tests, tolerances stated in each test with the source cited:
   - Trim converges in straight and level flight at 5,000 ft, 100 KIAS.
   - Stall speed clean and with full flaps within 4 kt of the POH values at the matching weight.
   - Sea-level rate of climb at Vy within 15 percent of the POH value.
   - Takeoff ground roll within 20 percent of the POH value.
4. A320 (repo FDM, tuned) tests: trim at FL350 Mach 0.78; clean and landing-configuration stall speeds within 8 kt of published values at a given weight; initial climb rate at typical weight within 20 percent; approach at Vapp with a 3 degree glide path stable. Tuning changes recorded as a patch list. The model is labeled "generic A320 FDM, tuned" in the app.
5. In the app (still basic, pre-M3 controls): both aircraft take off from the test runway, climb, turn, stall with a recoverable break, and land, using on-screen debug sliders and a game controller. Recorded as a short screen recording on device (or simulator if device is blocked).
6. Ground handling: nosewheel steering, brakes, crosswind on the ground, ground effect present (JSBSim models it; test compares lift coefficient at 0.2 and 2 wingspans of height).

### M3 to M10 (outlines)
- **M3 HUD and controls:** every HUD element in section 8 functional, tilt and on-screen and controller input with calibration, five cameras with transitions, pause, settings persisted; side-by-side screenshot review against the layout spec.
- **M4 Terrain streaming:** quadtree tiles with crack-free LOD, ground to FL450 without holes or pops above a stated threshold, memory budget enforced and logged, KPHX and KLAX regions baked, base layer global.
- **M5 Airports:** importer from OSM + FAA, generated runways with correct markings and lighting systems, taxiways with signs and lights, gates, generic buildings; KPHX and KLAX first, then the remaining 18 of the top 20 (proposed: KATL, KORD, KDFW, KDEN, KJFK, KSFO, KSEA, KLAS, KMCO, KMIA, KBOS, EGLL, EHAM, LFPG, EDDF, OMDB, RJTT, VHHH).
- **M6 Fleet:** asset-cook pipeline, all six slots with animations, lights, liveries; cockpits for C172 and A320; per-aircraft honest quality note.
- **M7 Weather and time:** live METAR, Open-Meteo winds, clouds from layers, turbulence and gusts in physics, rain/snow, wet runways, seasons.
- **M8 Navigation and autopilot:** FMC-style editor, CIFP procedures, LNAV/VNAV, ILS autoland on KPHX/KLAX with touchdown dispersion tests, moving map.
- **M9 ATC and traffic:** ground, tower, departure, approach phraseology with TTS; AI traffic at gates, taxiing, arriving.
- **M10 Polish:** thermal tuning with 30-minute device runs, memory, load time targets, graphics tiers, logbook.

---

## 14. Product decisions for you

Defaults are chosen so work can proceed; change any of them at approval.

1. **Widebody slot:** 747-8 visuals on the generic JSBSim B747 FDM (default), or 777 visuals on the same FDM re-tuned (less honest, since the 777 is a twin).
2. **Regional jet:** E175 on the FlightGear E-Jet JSBSim FDM (default) or Fokker 100 (repo FDM, older airliner).
3. **Turboprop:** ATR 72 or Dash 8 Q400 visuals on an adapted Fokker 50 FDM (default Q400, which has the better free model), or Fokker 50 / DHC-6 as they are.
4. **Worldwide procedures:** accept the US-only CIFP default from 7.4, or try the Navigraph email.
