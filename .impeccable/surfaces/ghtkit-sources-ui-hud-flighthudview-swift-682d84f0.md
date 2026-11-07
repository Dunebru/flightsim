---
version: 1
slug: "ghtkit-sources-ui-hud-flighthudview-swift-682d84f0"
primary_target: "Packages/FlightKit/Sources/UI/HUD/FlightHUDView.swift"
related_targets: ["Packages/FlightKit/Sources/UI/HUD"]
---

# In-flight HUD

Scope: the in-flight screen (FlightHUDView and its controls/panels). Mode: Operate.
Audience and job: the owner, phone held in landscape, steering by tilt, both thumbs on the edges, flying full airliner trips. Busy during takeoff and landing, idle in cruise.
Constraints: iOS 27, SwiftUI over a Metal world view; 44 pt targets; safe area; UI must not cost renderer frame time.

## Direction contract

THESIS: The HUD Apple would ship: Liquid Glass instruments floating over the world, controls that behave like Control Center, and nothing on screen that is not either live data or a thing you touch. Refuses the category default of opaque dark button tiles and the cockpit-costume look.
OWN-WORLD: iOS 27 Liquid Glass with a light smoke tint (legibility over bright sky) capsules, circles and rounded rects with no strokes; SF Pro Rounded semibold numerals with small secondary units; SF Symbols plus a few authored glyphs in matching weight (landing gear, spoilers); semantic system colors: white fill for "on", green for engaged automation, orange for caution (reverse, parking brake, gear in transit), red for warning; cyan for pilot-selected values (the cockpit convention, PRODUCT principle 4; system blue vanishes against sky).
STORY: The pilot sees the world first, reads speed, altitude and vertical speed at a glance across the top center, slides thrust with the left thumb and flaps, spoilers, gear and brake with the right, and opens camera, map, ATC, autopilot, lights and settings from the glass button bar at the bottom center, whose panels rise between the thumb columns without moving them.
FIRST VIEWPORT: Full-bleed world, arranged the way the owner flies in Infinite Flight (owner direction 2026-11-07: "positioning like infinite flight"), rendered in Apple's language. Top center: one glass capsule of flight data, with the autopilot status capsule under it while engaged. Bottom center: one merged glass button bar (camera menu, map, ATC, autopilot, lights, settings); panels rise from it as glass cards between the thumb columns. Left edge: tall Control Center-style thrust slider filling white from the bottom, percentage inside, REV circle beneath. Right edge: gear and brake circles above two sliders that extend downward like the real levers (spoilers narrow, flaps wide), every detent named. Top-left: pause. Data and button bar sit on the true center axis.
FORM: canon (category standard, rendered in Apple's platform language at the owner's request); position: user's standing exit; seed key 6b2622df.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
