# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

One person: the owner, flying for personal enjoyment on an iPhone 18 Pro Max (iPad secondary). Holds the phone in landscape with both hands and steers by tilting it, so both thumbs rest on the left and right screen edges throughout a flight. Mostly flies full airliner trips (A320, 737, 747 class): takeoff, autopilot climb and cruise, descent, approach and landing, in sessions long enough for the phone to get warm.

## Product Purpose

A personal flight simulator on the phone that is as realistic as an iPhone allows: physics-based flight models, real airports, terrain, sky and weather. Success is a flight that feels real from gate to gate, where the screen gets out of the way of the view and every control is where the thumb expects it.

## Positioning

Ergonomics in the spirit of Infinite Flight (thumb-reachable controls, landscape, tilt) combined with conventions familiar from Microsoft Flight Simulator (panel windows from a top bar), with an original visual identity. Never a copy of either app's look; nothing is extracted from either.

## Operating Context

Landscape only. Phone tilted continuously to steer, so the screen is seen at changing angles and in varying light, and touches happen mostly at the left and right edges with thumbs while the phone is moving. Long phases with nothing to touch (autopilot cruise) alternate with short busy phases (takeoff, approach, landing) where gear, flaps, spoilers, throttle and autopilot changes happen within seconds of each other.

## Capabilities and Constraints

- SwiftUI for all chrome, Metal for the 3D world beneath it (PLAN.md).
- Controls: tilt (primary), on-screen stick, game controllers (secondary).
- Systems: autopilot with real mode logic, flight plans, ATC, weather, failures, all arriving by milestone (PLAN.md section 13).
- Performance budget: the UI must not cost frame time the renderer needs (60 fps target).
- Personal use only; never distributed.

## Brand Commitments

Working name "Flight". No logo or brand assets exist. Binding direction from the owner (2026-11-07): the UI should feel like Apple designed the flight sim, using Apple's own platform design language (Liquid Glass, SF Pro, SF Symbols, Control Center-style controls, native menus and motion), with ergonomics closest to Infinite Flight. The first prototype (boxed dark cards, cockpit typeface) was rejected as looking generated.

## Evidence on Hand

No content beyond the app itself. Rejected prototype screenshots: `artifacts/verify/20261107-151210/`.

## Product Principles

1. The view outside is the product; chrome earns every point of screen it covers.
2. Thumbs first: anything used during takeoff and landing is reachable without moving a hand off the edge.
3. The screen reflects flight phase: busy when the pilot is busy, quiet in cruise.
4. Real cockpit conventions over app conventions, where pilots already have a learned meaning.
5. Honest state: a value on screen is either live or plainly marked as not.
