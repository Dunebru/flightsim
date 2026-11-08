# Progress

What is done, what is a placeholder, and what is next. Honest status only: anything not verified says so.

Last updated: 2026-11-07.

## Sound: started (2026-11-08)

The aircraft is heard, synthesized from the flight's numbers with no recorded audio: the C172's four cylinders firing twice a revolution (a note at rpm / 30 Hz with harmonics and exhaust rasp, louder with throttle; tested: 80 Hz at 2,400 rpm, 40 Hz at 1,200), the A320's fan whine and roar opening up with N1 and buzz-saw at high thrust (tested: eight times louder at takeoff N1 than idle), wind swelling and brightening with airspeed (tested), rumble rolling on the runway, a thud on touchdown scaled by the sink rate, and the stall horn. Quieter engine and more wind from the cockpit. Controllers' ATC replies are spoken. Checked by measurement and by the app running without audio errors, not yet by ear: the simulator here has no speakers I can hear.

## M9 Traffic: started (2026-11-07)

AI airliners at the departure airport, on the runways the wind favours (into the wind; the west-facing ends in light wind, as at both airports normally; tested). About an arrival and a departure every two minutes, around 60 movements an hour. Arrivals fly the 3 degree path from 15 km, flare, roll out and leave at the first exit they can make, then taxi over the mapped taxiway network (KPHX: 4,833 nodes, every free gate reaches every runway) to a free gate, where they stay 10 to 25 minutes before pushing back as departures. Departures push back, taxi to the threshold, hold until the runway and the final 5 km are clear, line up, roll and climb out. On the ground they look 60 m along their path: they stop behind anything ahead or standing still, take turns at crossings, and find another way round a head-on meeting; one still stuck after two minutes is withdrawn, never within 2 km of where you are watching. Tested over 40 simulated minutes at each airport: KPHX 14 landings, 18 takeoffs, 10 at gates, closest on the ground 59 m, 2 withdrawn; KLAX 13, 10, 10, 47 m, 3. Traffic stops for you on the ground, and an arrival goes around if you are on its runway (tested). Drawn with the generic narrowbody and widebody shapes, pitched on rotation and approach, with shadows; the airport is already busy when a flight starts.

Their lights follow what they are doing: navigation lights and red beacons whenever the engines run, white wingtip strobes on the runway and in the air, landing lights on approach, takeoff and rollout, the nose taxi light on the ground (render `kphx-traffic-night`). Not yet: landing gear on the shapes, traffic at the arrival airport.

**ATC.** The ATC panel offers the calls that make sense where you are: the ATIS any time (from the METAR and the runways in use: letter, time, wind, visibility, sky, temperature, altimeter); at a gate, a taxi request answered with the runway in use and a real route by taxiway names, preferring to stay on one taxiway ("runway 25L, taxi via H, H7, G7, hold short of runway 25L"); at the hold, ready for departure, cleared only when no AI arrival is within 5 km or on the runway ("hold short, traffic landing" otherwise; tested), after which AI departures wait for you; departure check-in with a climb; the ILS approach and the landing clearance, numbered behind AI traffic on final; clear of the runway and taxi to a free gate. Controllers speak, in FAA phraseology (digits with "niner", phonetic taxiways, runway sides, altitudes, altimeter; tested), through the system's US English voice; your calls are shown. Callsigns are generic (N172SP, Flight 214). Not yet: a radio-sounding voice, frequencies, readbacks checked, ATC that calls you unprompted (handoffs, traffic alerts), departure and arrival procedures.

## M8 Navigation and autopilot: started (2026-11-07)

1. **Autopilot.** Runs on the physics thread at 120 Hz and flies the JSBSim models through the pilot's own controls. Lateral: HDG (bank proportional to heading error, 20 degrees on the C172 and 25 on the A320), NAV and LOC. Vertical: V/S toward the selected altitude with a smooth capture (ALT*, then ALT), and G/S. A/THR holds the selected speed and moves the thrust lever with it. Tested in flight on both models: the C172 turns 90 degrees at 18.5 degrees of bank holding altitude within 6 ft, climbs at 620 fpm (600 selected) and captures 4,500 ft with an 8 ft overshoot; the A320 holds 248 to 250 kt through a 1,500 fpm descent to 7,000 ft; the A320 intercepts the ILS from 30 degrees below the glidepath and is 0.02 dots off both needles at 200 ft.
2. **ILS approaches** for every runway end NASR lists with one (KPHX 07L, 07R, 08, 25L, 26; KLAX's), built from the airport data: threshold past any displacement, the runway's true course, the published glidepath and crossing height, the localizer antenna 300 m past the far end (tested). LOC and APPR pick the approach the aircraft is lined up for, within 45 km.
3. **NAV and the map.** The map panel shows satellite imagery (Apple Maps) with the aircraft, the route in magenta and the point being flown to, with its distance and time, and, zoomed in, the region's VORs, NDBs and named fixes from the FAA (114 navaids, 5,626 fixes; tested against PXR 115.6 and LAX 113.6). Tap near a navaid or fix to add it by name, tap anywhere else to add a point, or add KPHX or KLAX; NAV flies it: direct to the first point, an anticipated turn onto each leg, then along it (tested: 56 m from the last point, under 100 m off a leg). Flying past the last point holds its course.
4. **Magnetic headings.** The HUD heading and the autopilot's selected heading are magnetic, from the World Magnetic Model 2025 (NOAA, public domain; tested against all 100 of NOAA's published test values within 0.01 degrees): runway 08 at KPHX reads 080. The flight model and the METAR wind stay true.
5. **On screen.** The autopilot panel has A/THR, NAV, LOC and APPR; the status under the flight data shows the active modes (HDG, NAV, LOC*, LOC; V/S, ALT*, ALT, G/S*, G/S), green.

Checked in the app on the simulator: an A320 started on a 3 nm final with APPR armed captures the localizer and glideslope by itself; with a route to KLAX and NAV, it turns west onto it. Not yet: no airways, SIDs or STARs (the FAA data is on disk); no tuning VOR radials; no flight plan beyond points on the map; tapping the map is untested on a real screen; no vertical navigation; no flight director or PFD.

## M7 Weather: in progress (2026-11-07)

Live weather from the departure airport's METAR (aviationweather.gov), parsed in the app (tested against live, thunderstorm, fractional-visibility and ICAO-format reports), or one of nine typical days chosen in Free Flight (clear, few, scattered, broken, overcast, mist, fog, rain, thunderstorms), each written as a METAR so it takes the same path as a real report.

1. **Flight model.** Wind growing with the 1/7 power law to 2,000 ft (winds aloft not used yet), smooth gusts between the steady and gust speeds, MIL-spec turbulence when gusty, the temperature offset from standard and the sea-level pressure (tested: a 20 kt headwind takes 20 kt off the groundspeed). The HUD shows the wind with an arrow relative to the nose.
2. **Volumetric clouds.** Each reported layer becomes a volume: few and scattered low layers are cumulus about 1.4 km deep, broken and overcast are stratus decks, CB towers to 11 km with an anvil, TCU to 4.5 km, anything above 20,000 ft is cirrus, VV is fog from the ground (tested). Raymarched at half the render resolution (0.4 on the phone) through a 128-cubed Perlin-Worley noise volume whose base channel is equalized, so a layer's coverage is the fraction of sky it hides (tested from 12 km over six places: FEW 0.16, SCT 0.40, BKN 0.69, OVC 1.00, none 0). Layers follow the Earth's curvature and reach the horizon; the field drifts with the wind. Lit by the sun with self-shadowing, multiple-scattering octaves and a diffuse-transmission term, so sunlit sides are white and bases grey; jittered and resolved over frames, composited behind anything nearer and through the atmosphere.
3. **Cloud shadows and overcast light.** A 256 by 256 shadow map over 24 km around the camera puts cloud shadows on the ground, buildings and aircraft (tested: overcast passes no sun, scattered shades 46% of the ground). Under cloud the ambient light turns into the grey sky's (about a third of a clear day's, without the blue), the haze dims and exposure adapts to it.
4. **Visibility.** Mist, fog and haze from the reported visibility (Koschmieder's 3.912 / V at the field), thinning with height (fog 120 m, mist 400 m, haze 1.5 km), on the ground, the sky, the clouds and the lights. Runway lights still carry past the visibility at night, as they do in real fog (tested: 400 m visibility removes 97% of the horizon's contrast).
5. **Rain, drizzle and snow.** From the present weather (light, moderate, heavy; showers in the vicinity are not overhead), drawn as drops in a box around the camera that stay put in the world and fall through it, streaked along their motion relative to the camera, shaded darker seen from below against the sky. Exaggerated past physics, as films and games do, since a real drop crosses a pixel too fast to register. Falling rain soaks the ground: pavement darker and glossy, with pooling in low spots; soil darker. Drawn after the clouds (tested: looking up into an overcast, snow changes 165 sky pixels; with the old pass order it changed none).
6. **Turbulence in cloud.** MIL-spec severity from the layers the aircraft is in: light in stratus and cirrus, moderate in cumulus, severe in a cumulonimbus; gust turbulence only in the lowest kilometre (tested).
7. **Cost (Mac GPU).** The cloud pass at 1920x884 with two layers: 1.55 ms. Not measured on the phone.

Renders in `artifacts/renders/clouds-kphx-*`. Not yet: lightning, reflections of runway lights on wet pavement, winds aloft, a moon and stars.

## Current milestone: M5 Airports, KPHX and KLAX only (in progress)

Scope set by you on 2026-11-07: KPHX and KLAX, made as good as possible, before any other airport.

### M5 status (2026-11-07)

Built and visually reviewed on the Mac GPU (renders in `artifacts/renders/kphx-*` and `klax-*`):

1. **Importer.** `flight-tools airport-import` reads FAA NASR (runway ends, elevations, displaced thresholds, TDZ, threshold crossing heights, PAPI, approach light type, centreline, TDZ and REIL flags, surface, edge light intensity) and OSM (taxiway centrelines and widths, aprons, stands with lead-in lines, hold positions with the runway side, buildings, boarding bridges, windsocks, aerodrome outline). KPHX: 3 runways, 556 taxiway segments, 19 aprons, 169 buildings, 253 stands, 226 holds, 22 bridges. KLAX: 4 runways, 382 taxiways, 26 aprons, 406 buildings, 400 stands, 194 holds, 117 bridges.
2. **One airport surface.** Interpolates the published runway-end elevations; runways, taxiways, aprons, paint, buildings, the flattened terrain and the physics ground all stand on it (tested: the surface passes through every published end elevation; the physics ground matches it on every runway).
3. **Runways and markings.** Concrete or asphalt per NASR, FAA precision markings with side letters and displaced thresholds. Checked against the draft AC 150/5340-1M: threshold stripe size, spacing and count, the threshold bar's side, numeral height, aiming point position and size, touchdown zone lengths and grouping, centreline stripes. Arrowhead and touchdown bar widths are still as recalled.
4. **Taxiways, aprons, paint.** Taxiway ribbons with round joins, concrete slabs, yellow centrelines stopping at runway edges, runway holding position markings with enhanced centrelines, stand lead-in lines and stop bars.
5. **Lighting (candela, physically scaled).** HIRL with the yellow caution zone, threshold and end lights, centreline and TDZ lights, MALSR/MALSF/ALSF-2 with sequenced flashers, PAPI that turns red and white with the viewer's angle (tested: two white and two red on a 3 degree path), REIL, blue taxiway edges, runway guard wig-wags, 25 m apron floodlight masts (night only).
6. **Signs.** Holding position signs ordered by which threshold is on the pilot's left, taxiway location signs, distance-remaining signs; lit at night.
7. **Buildings.** Extruded from OSM with procedural facades (terminal glass, hangar cladding, generic windows, parking decks), a glazed cab on the mapped tower (PHX Tower 99 m, LAX 86 m), boarding bridges (mapped plus generated for terminal stands without one), windsocks, lit windows at night.
8. **Night.** City lights from NASA Black Marble, drawn as street-grid and lot lights near the camera and a glow farther out.
9. **In the app.** Choose KPHX or KLAX; start on any runway end, a 3 nm final on the published path, or any named gate; the tower camera sits in the real tower cab.
10. **Ground (after your note that it didn't look good, 2026-11-07).** NAIP aerial photography at zoom 17 and 18 (about 1 m and 0.5 m per pixel) around both airports and along every approach (6 km out), USGS 2 to 4 m imagery to 10 and 14 km out; colour anchored on the aerial photography instead of the saturated Sentinel-2 mosaic, which had given everything an orange cast; an unsharp mask and fine grain in the terrain shader.
11. **City and shadows.** OSM buildings around each airport and along every approach corridor (KPHX 25,552, KLAX 80,101), drawn in 500 m chunks with membrane and tile roofs; a second sun shadow map so buildings, bridges and the tower cast shadows on the ground and each other.
12. **Taxiway direction signs and water.** Before each taxiway junction, on the left: the location sign and black-on-yellow direction signs with arrows for each branch (left turns to the left of the location sign). Open sea (where the elevation data sits at sea level) is drawn as water: dark and glossy, with wave normals that reflect the sky and carry the sun's glint, calming with distance. NAIP has no imagery over the sea; those tiles are filled from their parent tile.
13. **Trees.** Found in the NAIP imagery (dark green canopy, gathered in 4 m cells) when a zoom 17 or 18 tile loads, never on airport grounds; drawn as instanced low-poly trees (a quarter of them palms) within 2.5 km, casting shadows.
14. **The A320 is drawn as the generic narrowbody** (it was drawn with the C172), with its reference point near the wing, and the cockpit, wing and chase views set for an airliner. Still a stand-in: no gear, flaps or cockpit; real models are M6.
15. **Parked airliners.** Generic parametric narrowbody and widebody shapes (lofted fuselage, swept wings, fin, tailplane, engines; not models of any real type) parked nose-in at about three in four terminal stands, widebodies where stands are spaced for them, never at the stand the flight starts at. Generic liveries: white body, window line lit at night, grey belly, fin and engines in one of eight colours, no real airline marks. Instanced and shadow-casting. Real aircraft models and moving traffic belong to M6 and M9.
16. **A bake bug found and fixed.** Terrain-tile heights for zoom 16 to 18 (finer than the source's zoom 15) sampled the world's corner, so KLAX's finest levels were 0 m; the flattened airport hid it until the water shading showed the ground beside 25R as sea. A regression test and a pack gate (every fine level's height at each field must match the field elevation within 20 m) now cover it.
17. **Cost (Mac GPU, not the phone).** KLAX 24R final at 1920x884 with terrain, airport, 108 city chunks and both shadow maps: 3.5 ms per frame; 4.4 ms with trees. The phone ran the M1 scene about 2.6 times slower than this Mac's post stage, which suggests about 9 ms here; unmeasured until the phone is back.

Not yet: stop bars, terminal shapes beyond extruded footprints (no curved roofs, no detail), sloped runway profiles beyond the two published end elevations, terrain casting shadows (mountains), grass and low vegetation. Not measured: frame time on the phone with airports and lights (the phone is away).

## M4 Terrain streaming: met on the Mac and simulators; device timing owed

### M4 report (2026-11-07), against PLAN.md section 13

1. **Quadtree tiles with crack-free level of detail: met.** Web Mercator tiles of 65 x 65 height samples, built through real WGS84 geodesy (Earth's curvature is exact), streamed off the main thread with at most six GPU uploads a frame. Neighbours at the same level share their edge samples exactly (tested); between levels, skirts hide the gaps. A tile splits only when all four children are loaded, so the drawn set never has holes or overlaps (tested). Out of view, refinement is three times coarser.
2. **Ground to FL450 without holes: met.** From 13,716 m over KPHX, looking 20 degrees down in eight directions with the sky and the fallback ground switched off, no pixel below the horizon is empty. Negative control: the same views with the coarse levels removed show holes, so the check can fail. Aerial perspective now reaches 80 km plus the distance to the horizon (up to 450 km), so distant terrain fades into the sky.
3. **Pops above a stated threshold: met.** Threshold: when tiles switch level, the frame changes by less than 3 of 255 on average. Measured by rendering each view with tiles split at the normal distance and at twice it: final approach 0.21 (99th percentile 5.5), pattern altitude 0.49 (7.6), climb at 3,000 m 0.90 (10.1), cruise at 10,000 m 1.43 (19.9). There is no geomorphing, so a switch is a cut, just a small one.
4. **Memory budget enforced and logged: met.** 256 MB by default. Least recently used tiles are evicted; tiles in use (drawn, their ancestors, children being waited on) never are. When a view needs more than the budget, refinement backs off until it fits. Test: a five-point tour with a 64 MB budget stays at 64 MB (detail backed off 6x); the same tour without a budget reaches 314 MB. `-FlightLogStats YES` prints a `TERRAINSTATS` line (selected, drawn, resident, budget, pending, back-off) every two seconds. Two churn bugs were found by these gates and fixed: evicting a drawn tile's ancestors made the subtree reload forever, as did evicting children a parent was waiting on.
5. **KPHX and KLAX baked: met (KLAX as data only).** KPHX: 1,325 tiles, zoom 6 to 16, 58 MB (Copernicus 30 m heights near the field). KLAX: 1,346 tiles, zoom 6 to 16, 45 MB (heights from AWS Terrain Tiles throughout, which carry USGS 10 m data in the US; no local DEM needed). A render over LAX from the Phoenix scene frame, 590 km away, checks both the second region and the floating origin at that distance. Flying at KLAX needs per-airport scene origins, which arrive with airports in M5.
6. **Global base layer: met.** 1,365 tiles, zoom 0 to 5, 27 MB, from AWS Terrain Tiles and Sentinel-2. Coarse (about 20 km between height samples at zoom 5), so it is a backstop past the regions, not scenery.

Also in M4: physics stands on the same ground the renderer draws (JSBSim's terrain elevation is set from the scenery every frame; the runway areas are flattened identically for both). The scene origin moved to the published runway 8/26 midpoint: the old origin was 740 m south of the real runway, which showed once satellite imagery was under it. The runway is drawn at its true heading (090.17) and 6.7 m slope. Imagery near the airport is USGS orthophotography (about 2 m per pixel), colour-matched to the Sentinel-2 mosaic used farther out. A "Loading scenery" hold keeps the flight paused until the ground around the camera has streamed in. Terrain vertices are 20 bytes and every tile shares one index buffer (about 0.42 MB per tile, mostly the texture).

Not yet verified: frame time on the phone with terrain (the phone is away). Close to the ground the 2 m imagery is still soft compared with MSFS's 30 cm aerial photos and 3D ground cover; finer imagery (NAIP at 0.6 m) is a bake-time option once its export service responds.

## M3 HUD and controls: largely met (2026-11-07)

### M3 report (2026-11-07), against PLAN.md section 13

1. **HUD elements: met for everything this milestone owns.** Metrics bar (IAS, GS, altitude, vertical speed, heading, RPM or N1), thrust lever with idle and reverse, flaps with the aircraft's own detents, spoilers, gear (fixed on the C172), parking brake, hold-to-brake, trim, stall warning, camera, lights and settings panels, pause. Elements that belong to later milestones are present but say so on screen instead of pretending: the map ("No map yet", M5/M8), ATC (M9) and the autopilot panel ("Autopilot logic arrives in M8").
2. **Input with calibration: met.** Tilt (the primary mode, with Level to recalibrate, dead zone and expo), an on-screen stick, and game controllers; sensitivity and pitch inversion in Settings. Nosewheel steering follows the roll input on the ground and fades out by 60 kt.
3. **Five cameras with transitions: met.** Cockpit, chase, tower, wing and free orbit, blended over 0.6 s; drag and pinch adjust the current view. The cockpit view hides the exterior model because the C172 panel is not imported yet (M6).
4. **Settings persisted: met.** Aircraft, start position, time of day, control mode, sensitivity, inversion, upscaler and the stats overlay survive relaunch (tested).
5. **Side-by-side screenshot review: done once (the Apple-style redesign of 2026-11-07, reviewed against `DESIGN.md`).** Not repeated against Infinite Flight screenshots; the design direction is now Apple's platform language, not a copy.

Not verified on the phone this milestone (it was away): tilt feel, the stick, and controller input on device.

## M2 Flight dynamics: met except the on-device flight recording

### M2 report (2026-11-07), against PLAN.md section 13

1. **JSBSim builds for iOS device, simulator and macOS: met.** v1.3.3 vendored unmodified and compiled by SwiftPM exactly as JSBSim's CMake does. Every C entry point takes one process-wide lock: JSBSim has static state, and two instances stepping on different threads crashed the test process.
2. **Fixed 120 Hz physics thread, independent of rendering: met.** Step count within 1% of wall time over 3 s; simulation time does not depend on how often the state is read.
3. **C172P published numbers: met after one tuning change.** Sources verified 2026-11-07: 1981 Cessna 172P POH Figure 5-3 (stall), Figures 5-5 and 5-6 (takeoff, climb). At 2,400 lb: stall 52.1 KCAS flaps up and 46.8 KCAS flaps 30 against 51 and 46 (minimum-speed method, the CAR 3 basis of the POH); climb 794 fpm at Vy against ~700 (+13%, tolerance 15%); takeoff ground roll 992 ft against 890 (+11%, tolerance 20%, flaps 10, short field); trim at 5,000 ft and 100 KIAS holds within 50 ft for 30 s. Tuning C1 (`aircraft/c172p/TUNING.md`): the shipped propeller let the engine turn 2,735 RPM at full throttle in the climb and climbed 25% too well. A negative control (the untuned propeller) fails the climb test.
4. **A320 published numbers: met for what has a citable source, after four tuning changes (`aircraft/A320/TUNING.md`).** The shipped generic model could not rotate (static margin ~75%, no ground effect, no slats): its "stall" was 198 KCAS clean and its takeoff roll 10,683 ft. After T1-T4: VS1g CONF FULL 106.9 kt at 64 t against ~108.6 derived from Airbus's published 136 kt approach speed; approach attitude 2.5 degrees nose up at 136 kt on a 3 degree glide (real: about 2.5); trims at FL350, Mach 0.789; stable hands-off. No citable CONF 0 stall speed was found, so none is asserted. The app labels it "generic JSBSim A320, tuned".
5. **Both aircraft fly in the app: built, not yet verified on the phone.** The app runs JSBSim with tilt steering (calibrated, dead zone, expo), game controllers, the HUD levers, live instruments, stall warning, and five camera views; the test pilot flies stalls, climbs and takeoffs headlessly. A screen recording of a hand-flown circuit on the phone is still owed (the phone is away; it also needs a human pilot).
6. **Ground handling: partial.** Nosewheel steering follows tilt on the ground, fading out by 60 kt; ground effect is present and tested on both aircraft (factor above 1.05 at 0.2 spans, 1.0 at 2 spans). Not yet: toe brakes and differential braking (only the parking brake), crosswind on the ground (there is no wind until M7).

## M1 Renderer core: done (2026-11-07)

### M1 report (2026-11-07), against PLAN.md section 13

1. **Metal renderer, HDR, reverse-Z, floating origin: met.** `CAMetalLayer` driven by `CAMetalDisplayLink` behind the HUD; HDR `rgba16Float`; reverse-Z infinite projection; Double world positions drawn camera-relative. Automated test: a comb of 2 cm slats renders pixel-identical (under 0.1% of pixels changed) at 50 km and 5,000 km from the origin, and the same scene with the floating origin disabled breaks (proves the test can fail). Runs on the iPhone 17 Pro and iPad simulators and on the iPhone 18 Pro Max.
2. **Sky and sun: met, with one substitution.** Sun position tested against NREL SPA (stronger than the NOAA calculator named in the plan) within 0.1 degrees at six places and times. Hillaire 2020 atmosphere. Renders at morning, noon, sunset, dusk and night are in `artifacts/renders/scene-*.png` (Mac GPU, same renderer code as the app). Not yet: stars and moon (night sky is black), planned for M7.
3. **Aerial perspective, ground, runway markings: met.** Ground is procedural Sonoran desert (no imagery until M4). KPHX 8/26 with precision-runway markings; dimensions follow FAA AC 150/5340-1 **as recalled**, to be checked against the circular in M5. A top-down render caught and fixed vertically flipped numerals.
4. **Test aircraft: met, placeholder quality.** FlightGear C172P (GPL-2.0), textured, GGX shading, sky reflections, glass pass, sun shadow map. Placeholder: no normal maps, no control-surface animation, no livery system (M6).
5. **MetalFX: met.** Temporal (jittered, depth and motion vectors), spatial, and bilinear fallback, switchable in Settings. Mac GPU test: temporal upscaling of a static scene lands closer to the native image than bilinear (error 1.09 vs 1.40), and the flipped jitter sign is clearly worse (1.89), so the sign is right. On the iPhone 18 Pro Max all three modes run (launch argument `-FlightUpscaler`, or Settings). The iOS Simulator SDK has no MetalFX, so the simulator always uses the bilinear path.
6. **Frame-time overlay: met. Device numbers (iPhone 18 Pro Max, 2026-11-07, thermal state nominal, steady 60 fps):** MetalFX temporal, 1922x884 to 2868x1320: GPU 5.5 to 6.0 ms per frame, CPU 0.8 ms. Spatial: 5.4 ms. Native 2868x1320 without MetalFX: 5.5 ms. "GPU per frame" is the span from the first to the last stage of a frame; the per-stage sum overstates cost because stages of consecutive frames overlap and the GPU clock drops when there is slack (an early run showed the sum rising from 8 to 18 ms at a constant 60 fps). Under the M1 target of 6 ms. At this scene complexity MetalFX does not save time yet; the post stage (about 4.4 ms) is the next optimization (write the upscaler output straight to the drawable).
7. **Signposts: met.** `OSSignposter` intervals for the frame and each encode stage. An 8 s Instruments "Logging" trace recorded on the phone with `xctrace` contains 490 intervals of each of Frame, Encode atmosphere, Encode scene and Encode post (one per frame at 60 fps), verified by exporting the os-signpost table. Trace: `artifacts/m1/flight.trace` (gitignored; open in Instruments).

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
| SimCore | **Working.** WGS84 geodesy (tested against PROJ), local ENU frames, solar ephemeris (tested against NREL SPA). |
| CJSBSim | **Working.** JSBSim 1.3.3 vendored unmodified, C wrapper with a process-wide lock. |
| FlightModel | **Working.** 120 Hz physics thread; C172P (one tuning change) and a tuned generic A320 pass their published-number tests; the ground under the aircraft comes from the scenery every frame. |
| Terrain | **Working.** Web Mercator tiles, scenery packs layered into a library, crack-hiding skirts, quadtree selection, flattened runway areas, a ground model for physics and cameras. |
| Aircraft | **Partial.** AC3D loader for the C172P. No asset pipeline, liveries or animation (M6). |
| Renderer | **Working.** Physically based sky and aerial perspective, streamed satellite terrain, the KPHX 8/26 runway with markings, the aircraft with a sun shadow, MetalFX. No night lighting, stars, clouds or water yet. |
| UI | **Working.** Apple-style HUD with live data, free-flight setup, persisted settings, five cameras, tilt, stick and controller input. |
| Tools (`flight-tools`) | **Partial.** `terrain-bake` works (DEM, AWS terrain tiles, Sentinel-2 and USGS imagery with colour matching); `nav-import`, `airport-import` and `asset-cook` say "not implemented" and name their milestone. |
| Airports | **Working (KPHX, KLAX).** Cooked layouts, airport surface, generated runways, markings, taxiways, aprons, buildings, lights and signs, start positions. |
| Weather | **Partial.** METAR parsing and live fetch, wind, gusts, turbulence, temperature and pressure into the flight model. No clouds yet. |
| Autopilot | **Partial (M8).** HDG, NAV, LOC, V/S with altitude capture, G/S, A/THR; tested in flight on both models. |
| Nav | **Placeholder.** ILS approaches come from the airport data (UI's ApproachCatalog); navaids and procedures not yet. |
| Traffic | **Partial (M9).** Arrivals, departures and taxiing over the real taxiway network at the departure airport; tested. |
| ATC | **Partial (M9).** ATIS, ground, tower, departure and approach on request, aware of the traffic; spoken. |

## Placeholders in the app today

Airports are generated, not modelled: terminals are extruded footprints with procedural glass, not the real architecture. Airliners, parked and moving, are generic shapes in generic liveries. The HUD carries a small "Prototype" tag.  The tower camera position is a guess, not the real tower.

## Known issues

- Night is near black: no stars, moon or city lights yet (stars and moon M7, night lighting M10).
- Imagery comes from two sources (Sentinel-2 below zoom 12, USGS from zoom 12). Colour is matched statistically at bake time, so a faint tone change can remain where the levels meet.
- The sea is satellite imagery on flat ground at sea level: no reflections, waves or shoreline foam (water rendering, M10). Terrain-tile heights are clamped at sea level to remove ocean depths, which also raises land below sea level (Death Valley, the Salton Sea) to sea level where no local DEM is used.

- iPad landscape lock relies on `UIRequiresFullScreen`, deprecated since iOS 26 (one build warning). Verified on 2026-11-07 that iPadOS 27 still honors it: without it the iPad simulator rendered the app in portrait. When Apple stops honoring it, the iPad needs a different approach (likely a rotate-to-landscape prompt).

## Next

Finish M4 (gates on the final packs, KLAX region, device timing when the phone is back), then M5 Airports: runways, taxiways, lighting and buildings generated from OSM and FAA data, starting with KPHX and KLAX. Owed from earlier milestones when the phone is back: `scripts/verify.sh --device`, a hand-flown circuit recording (M2), and on-device input checks (M3).
