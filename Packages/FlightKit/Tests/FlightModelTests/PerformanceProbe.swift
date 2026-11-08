import Foundation
import Testing
@testable import FlightModel

@Test func performanceProbeC172() throws {
    var p = try TestPilot(model: "c172p")
    p.loadC172ToMaxWeight()
    try p.startInAir(altitudeFeet: 5_000, knots: 75, flaps: 0)
    print(String(format: "probe C172 weight %.0f lb", p.weightPounds))
    print(String(format: "probe C172 stall clean %.1f KCAS", p.stallSpeed()))
    print("probe C172 at stall:", p.lastStallDiagnostics)
    try p.startInAir(altitudeFeet: 5_000, knots: 70, flaps: 1)
    print(String(format: "probe C172 stall flaps30 %.1f KCAS", p.stallSpeed()))
    print("probe C172 at stall:", p.lastStallDiagnostics)
    try p.startInAir(altitudeFeet: 1_000, knots: 76, flaps: 0)
    print(String(format: "probe C172 climb at 76 KCAS, SL+1000: %.0f fpm", p.climbRate(atKnots: 76)))
    print(String(format: "probe C172 takeoff ground roll %.0f ft", try p.takeoffGroundRoll(rotateKnots: 55, flaps: 0)))
}

@Test func performanceProbeA320() throws {
    var p = try TestPilot(model: "A320")
    try p.startInAir(altitudeFeet: 10_000, knots: 220, flaps: 0)
    print(String(format: "probe A320 weight %.0f lb (%.1f t)", p.weightPounds, p.weightPounds * 0.4536 / 1000))
    print(String(format: "probe A320 stall clean %.1f KCAS", p.stallSpeed()))
    print("probe A320 at stall:", p.lastStallDiagnostics)
    try p.startInAir(altitudeFeet: 10_000, knots: 160, flaps: 1)
    print(String(format: "probe A320 stall FULL %.1f KCAS", p.stallSpeed()))
    print("probe A320 at stall:", p.lastStallDiagnostics)
    try p.startInAir(altitudeFeet: 3_000, knots: 250, flaps: 0)
    print(String(format: "probe A320 climb at 250 KCAS, 3000 ft: %.0f fpm", p.climbRate(atKnots: 250)))
    // try p.startInAir(altitudeFeet: 35_000, knots: 260, flaps: 0)
    // print(String(format: "probe A320 trimmed FL350 at 260 KCAS: mach %.3f throttle %.2f", p.fdm.get("velocities/mach"), p.controls.throttle))
    print(String(format: "probe A320 takeoff ground roll %.0f ft (flaps 1, rotate 145)", try p.takeoffGroundRoll(rotateKnots: 145, flaps: 0.25)))
}
