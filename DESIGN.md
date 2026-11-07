---
name: Flight
description: A personal iPhone flight simulator whose cockpit chrome is Apple's own platform language floating over the world.
colors:
  engaged-green: "#30D158"
  caution-orange: "#FF9F0A"
  warning-red: "#FF453A"
  selected-cyan: "#64D2FF"
  fill-white: "#FFFFFF"
  label-secondary: "rgba(255, 255, 255, 0.9)"
  smoke-tint: "rgba(0, 0, 0, 0.28)"
  inset-fill: "rgba(255, 255, 255, 0.16)"
  inset-fill-quiet: "rgba(255, 255, 255, 0.12)"
  ink-on-fill: "rgba(0, 0, 0, 0.85)"
typography:
  display:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "52pt"
    fontWeight: 700
  headline:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "34pt"
    fontWeight: 700
  title:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "20pt"
    fontWeight: 700
  metric:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "20pt"
    fontWeight: 600
    fontFeature: "tnum"
  metric-small:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "15pt"
    fontWeight: 600
    fontFeature: "tnum"
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "17pt"
    fontWeight: 600
  label-strong:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "13pt"
    fontWeight: 700
  caption:
    fontFamily: "SF Pro, system-ui"
    fontSize: "12pt"
    fontWeight: 600
  unit:
    fontFamily: "SF Pro Rounded, ui-rounded, system-ui"
    fontSize: "11pt"
    fontWeight: 600
rounded:
  chip: "16pt"
  slider: "22pt"
  card: "28pt"
  capsule: "9999pt"
spacing:
  tight: "6pt"
  gap: "10pt"
  inner: "12pt"
  edge: "16pt"
  metric-run: "20pt"
components:
  metrics-capsule:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.fill-white}"
    typography: "{typography.metric}"
    rounded: "{rounded.capsule}"
    padding: "0 22pt"
    height: "52pt"
  autopilot-capsule:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.selected-cyan}"
    typography: "{typography.metric-small}"
    rounded: "{rounded.capsule}"
    padding: "0 16pt"
    height: "34pt"
  tool-bar:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.fill-white}"
    rounded: "{rounded.capsule}"
    padding: "0 6pt"
    height: "48pt"
  tool-button-open:
    backgroundColor: "{colors.fill-white}"
    textColor: "#000000"
    rounded: "{rounded.capsule}"
    size: "40pt"
  circle-toggle:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.fill-white}"
    rounded: "{rounded.capsule}"
    size: "52pt"
  circle-toggle-compact:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.fill-white}"
    rounded: "{rounded.capsule}"
    size: "48pt"
  circle-toggle-on:
    backgroundColor: "{colors.fill-white}"
    textColor: "#000000"
    rounded: "{rounded.capsule}"
    size: "52pt"
  circle-toggle-engaged:
    backgroundColor: "{colors.engaged-green}"
    textColor: "#000000"
    rounded: "{rounded.capsule}"
    size: "52pt"
  circle-toggle-caution:
    backgroundColor: "{colors.caution-orange}"
    textColor: "#000000"
    rounded: "{rounded.capsule}"
    size: "52pt"
  glass-slider:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.fill-white}"
    rounded: "{rounded.slider}"
    width: "64pt"
  glass-slider-fill:
    backgroundColor: "{colors.fill-white}"
    textColor: "{colors.ink-on-fill}"
  panel-card:
    backgroundColor: "{colors.smoke-tint}"
    textColor: "{colors.fill-white}"
    typography: "{typography.title}"
    rounded: "{rounded.card}"
    padding: "10pt 8pt 10pt 18pt"
  target-chip:
    backgroundColor: "{colors.inset-fill-quiet}"
    textColor: "{colors.selected-cyan}"
    typography: "{typography.metric}"
    rounded: "{rounded.chip}"
    padding: "0 12pt"
    height: "56pt"
  target-chip-selected:
    backgroundColor: "{colors.selected-cyan}"
    textColor: "#000000"
    rounded: "{rounded.chip}"
  panel-button:
    backgroundColor: "{colors.inset-fill}"
    textColor: "{colors.fill-white}"
    typography: "{typography.metric-small}"
    rounded: "{rounded.capsule}"
    height: "44pt"
  mode-button-on:
    backgroundColor: "{colors.engaged-green}"
    textColor: "#000000"
    typography: "{typography.label-strong}"
    rounded: "{rounded.capsule}"
    height: "44pt"
---

# Design System: Flight

## Overview

**Creative North Star: "Control Center at Thirty Thousand Feet"**

The system is Apple's iOS 27 platform language applied to a cockpit. Every piece of chrome is a sheet of Liquid Glass with a light smoke tint, floating over a full-bleed world with no frame, toolbar background, or scrim around it. Controls borrow their behavior from Control Center: tall sliders that fill white as the value rises, round toggles that turn solid when on, a single merged capsule of buttons. Numbers are SF Pro Rounded semibold with tabular digits and small secondary units; icons are SF Symbols, plus three authored filled glyphs (landing gear, flaps, spoilers) drawn to sit beside them at matching weight.

Density follows the hands. Instruments cluster on the true center axis (data at the top, the tool bar at the bottom), and everything touched during takeoff and landing lives in two thumb columns on the left and right edges. Panels rise as glass cards between those columns without displacing them. Color is semantic and fixed: a hue on screen always reports state, never decorates.

The confirmed rejection is the first prototype's look: opaque dark boxed tiles and a cockpit costume typeface. The system also stays off any other flight sim's visual identity while borrowing Infinite Flight's arrangement.

**Key Characteristics:**
- Smoke-tinted Liquid Glass for every surface, with no strokes and no drawn shadows.
- Capsules, circles, and continuous rounded rects only.
- White fill means "on"; green, orange, red, and cyan each carry exactly one meaning.
- SF Pro Rounded semibold numerals with tabular digits and numeric content transitions.
- Springs for every state change, haptic selection feedback on every toggle and detent.

## Colors

A colorless glass world where the only hues are state signals, all taken from the system palette so they track Apple's own tuning.

### Primary
- **Engaged Green** (system green): automation engaged and healthy state. Autopilot status dot and label, active autopilot mode buttons, the autopilot master switch tint, gear down and locked.

### Secondary
- **Caution Orange** (system orange): a configuration the pilot must be aware of. Reverse thrust (REV circle and the thrust fill), parking brake set, gear in transit (pulsing), spoilers past the armed detent.
- **Selected Cyan** (system cyan): values the pilot chose, following the cockpit convention for selected targets. Autopilot target numerals and the selected target chip. Cyan, not system blue, because blue vanishes against sky.

### Tertiary
- **Warning Red** (system red): reserved for stall and unsafe gear. Declared as a token; no surface in this build uses it yet.

### Neutral
- **Fill White**: the "on" state of every toggle, the slider fill, the open tool button, and all primary text over glass.
- **Secondary Label** (white at 90%): metric labels, units, light captions.
- **Smoke Tint** (black at 28%): the tint on every glass surface; this is what keeps small white labels at 4.5:1 over bright sky.
- **Inset Fill** (white at 16%) and **Inset Fill Quiet** (white at 12%): buttons and chips inside a glass card, which sit on glass rather than becoming glass themselves.
- **Ink on Fill** (black at 85%): text and glyphs where a white fill covers them.

### Named Rules
**The White Is On Rule.** A control that is on becomes a solid fill with a black glyph; off is plain glass with a white glyph. A state color replaces white only when the state itself is engaged, caution, or warning.

**The One Meaning Rule.** Green is engaged, orange is caution, red is warning, cyan is pilot-selected. No hue appears for brand, emphasis, or decoration.

**The Smoke Glass Rule.** Glass is always tinted with black at 28%. Untinted glass measured 2.98:1 for small white labels over sky in review; do not lighten the tint.

## Typography

**Display Font:** SF Pro Rounded (system `.rounded` design)
**Body Font:** SF Pro (system default design)

**Character:** Rounded numerals give instruments a friendly, Apple Watch legibility at a glance; plain SF Pro carries captions and icon-adjacent labels. There is no third family.

### Hierarchy
- **Display** (bold, 52pt): the app name on the main menu. Placeholder screen; the only use.
- **Headline** (bold, 34pt): modal state titles such as Paused.
- **Title** (bold, 20pt, rounded): glass panel titles.
- **Metric** (semibold, 20pt, rounded, tabular digits): primary flight data and autopilot target chips. The style's default size is 22pt; the slider readout uses 17pt.
- **Metric Small** (semibold, 15pt, rounded, tabular digits): autopilot status targets and increment buttons.
- **Body** (semibold, 17pt): SF Symbols in the tool bar and pause button, and glass-prominent button labels.
- **Label Strong** (bold, 13pt, rounded): mode buttons, autopilot status text, the current slider detent.
- **Caption** (semibold, 12pt): metric labels above values (IAS, ALT, V/S).
- **Unit** (semibold, 11pt, rounded): units set beside a value on its first baseline, in secondary white. Non-current detent names use 11pt medium at 70% opacity.

### Named Rules
**The Live Digit Rule.** Every changing number uses tabular digits and a numeric content transition, so values roll rather than jump and columns never shift.

**The Small Unit Rule.** Units are always a separate, smaller, secondary-white run aligned to the value's baseline; never the same size as the number.

## Layout

The world is full bleed; chrome floats inside the safe area with a 16pt edge inset and a 10pt gap between neighboring controls. The arrangement is fixed: pause at top left; one flight data capsule on the true center axis at the top, with the autopilot status capsule 8pt beneath it while engaged; the merged tool bar on the true center axis at the bottom; thrust slider (up to 250pt tall) with the REV circle beneath on the left edge; parking brake and gear circles above the spoilers (52pt wide) and flaps (68pt wide) sliders on the right edge, up to 200pt tall. Panels open above the tool bar, centered and inset so they never overlap either thumb column.

Responsiveness is by subtraction, not squeezing. The data capsule drops N1, then GS, before it would compress; the autopilot capsule drops targets in pairs. Tablet uses the same arrangement with more air. Inside panels, rows sit 10 to 12pt apart and items within a row 6pt apart; the data capsule spaces its values 20pt apart.

## Elevation & Depth

Depth is the material, not shadows. Every surface is Liquid Glass with the smoke tint, and interactive surfaces use the interactive glass variant so they respond to touch with the system's own highlight. The tool bar sits in a glass effect container so its glass merges and morphs as one piece. Within a glass card, secondary controls are flat translucent white insets, one level up. A modal pause dims the world with black at 35%.

### Shadow Vocabulary
- **Over-world legibility** (black at 35%, 2pt blur, 1pt down): only on white content that sits directly over the world inside a slider. It is a legibility aid, not elevation.

### Named Rules
**The Material Is the Depth Rule.** No drop shadows on surfaces and no strokes on any shape. Separation comes from glass against the world and from inset fills against glass.

## Shapes

Three shapes, all continuous-corner: capsules for bars, buttons, and status; circles for toggles; rounded rectangles for sliders (22pt), target chips (16pt), and panel cards (28pt). Corners nest so inner radii are smaller than their container. Nothing has a border. The three authored glyphs are solid filled silhouettes (with an even-odd cutout for the tire hub) scaled to the same box as an SF Symbol.

## Components

### Buttons
Quiet until touched, then solid.
- **Tool bar button:** 48pt hit area, SF Symbol at 17pt semibold in white. When its panel is open, a 40pt white circle sits behind a black glyph. The autopilot entry uses the text AP in 14pt bold rounded.
- **Panel button:** full-width capsule, 44pt minimum height, Inset Fill behind white 15pt semibold rounded tabular text. Supports press-and-hold repeat.
- **Mode button:** same capsule; off is Inset Fill with white 13pt bold rounded text, on is Engaged Green with black text.
- **Prominent action:** the system glass-prominent button style tinted white with black 17pt semibold text, 44pt tall (Free Flight, Resume). Destructive or secondary actions in a panel use the plain system glass button style.
- **Close:** 30pt circle of white at 18% with a 13pt bold xmark, inside a 44pt hit area.

### Chips
- **Target chip:** 16pt rounded rectangle, 56pt minimum height, 92pt minimum width. Unselected: Inset Fill Quiet, secondary caption, value in Selected Cyan while the autopilot is engaged (white otherwise). Selected: solid Selected Cyan with black value and 70% black caption.

### Cards / Containers
- **Corner Style:** continuous 28pt.
- **Background:** smoke glass.
- **Shadow Strategy:** none; see Elevation & Depth.
- **Border:** none.
- **Internal Padding:** 18pt leading, 8pt trailing, 10pt vertical; header row of a 20pt bold rounded title, optional trailing control, and the close button, with 12pt between rows.
- **Motion:** rises from the bottom (scale from 92% anchored at the bottom plus fade) on a 0.35s spring with 0.15 bounce.

### Navigation
- **Tool bar:** one capsule of interactive smoke glass, 6pt horizontal padding, buttons spaced edge to edge. Camera is a native menu; every other button toggles exactly one panel.

### Glass Slider
The signature control, Control Center's brightness slider turned into a throttle and levers. Smoke glass rounded rectangle (22pt) with a white fill: thrust fills from the bottom with a percentage readout at the top and a flame symbol at the foot; spoilers and flaps fill from the top like the real levers and name every detent down their length (current one in 13pt bold, others 11pt medium at 70%). The fill edge always lands just past the current detent's name. Content is white over glass and inverts to black where the fill covers it. Dragging is relative, rubber-bands up to 12% past either end and springs back (0.35s, 0.4 bounce), and every detent fires a selection haptic. A state color replaces the white fill when the setting is cautionary (reverse thrust, spoilers deployed).

### Circle Toggle
52pt interactive glass circle (48pt compact for pause and REV, 50pt in the lights row) with a white glyph; on, it fills solid in white or its state color with a black glyph. Lights appear as a row of these with an 11pt medium caption under each. Gear in transit pulses its glyph between full and 35% opacity every 0.45s.

### Status Capsules
The flight data capsule is 52pt tall glass with 22pt side padding: caption label over a 20pt metric with its unit. The autopilot capsule is 34pt tall with 16pt side padding: an 8pt green dot, AP (and A/THR) in green 13pt bold rounded, then captions with 15pt cyan targets. It slides in from the top with a fade.

### Empty States
A system that does not exist yet is shown with the platform's own content-unavailable view (symbol, title, one sentence) inside a glass card, never a fake or greyed control.

## Do's and Don'ts

### Do:
- **Do** put every surface on Liquid Glass with the 28% black smoke tint, and use the interactive variant for anything touchable.
- **Do** show "on" as a solid fill with a black glyph: white by default, Engaged Green, Caution Orange, or Warning Red when the state demands it.
- **Do** set every changing number in SF Pro Rounded semibold with tabular digits and a numeric content transition, unit smaller and secondary.
- **Do** use SF Symbols first; draw a filled glyph only when no symbol exists, at matching weight and box.
- **Do** keep touch targets at 44pt or more and attach a selection haptic to every toggle and detent.
- **Do** animate state with springs (0.3 to 0.35s, bounce 0.15 for panels and capsules).
- **Do** drop lower-priority values before any capsule would compress or wrap.

### Don't:
- **Don't** use opaque dark tiles, boxed cards, or a cockpit costume typeface; that was the rejected first prototype.
- **Don't** add strokes or drop shadows to any surface.
- **Don't** use system blue for selected values; it disappears against sky. Use Selected Cyan.
- **Don't** use any hue decoratively; each color reports exactly one kind of state.
- **Don't** lighten or remove the smoke tint to make glass look clearer.
- **Don't** copy the visual identity of Infinite Flight or Microsoft Flight Simulator; borrow only arrangement and conventions.
