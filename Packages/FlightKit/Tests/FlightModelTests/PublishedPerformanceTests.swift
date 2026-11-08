import Foundation
import Testing
@testable import FlightModel

/// PLAN.md M2 criteria 3 and 4: the flight models against published numbers.
///
/// Sources (verified 2026-11-07):
/// [P] Cessna 172P POH (1981), Figure 5-3 stall speeds, page 5-11.
/// [C] Cessna 172P POH Figures 5-5 (takeoff) and 5-6 (climb), as excerpted by the Civil Air Patrol.
/// [A] Airbus A320 Aircraft Characteristics, July 2026, approach speed 136 kt at 66 t CONF FULL.
/// Derived: A320 VS1g CONF FULL ~109 kt at 64.5 t from [A] / 1.23 (Airbus VLS = 1.23 VS1g),
/// scaled by sqrt(weight). No citable CONF 0 stall speed was found, so none is asserted.
@Suite(.serialized)
struct PublishedPerformanceTests {
    // MARK: Cessna 172P at 2,400 lb

    /// [P]: 51 KCAS flaps up (rearward CG; 52 at forward CG), power off. Tolerance 4 kt.
    @Test func c172StallFlapsUp() throws {
        var p = try TestPilot(model: "c172p")
        p.loadC172ToMaxWeight()
        try p.startInAir(altitudeFeet: 5_000, knots: 75, flaps: 0)
        let v = p.minimumSpeedStall()
        #expect(abs(v - 51) <= 4, "stall flaps up \(v) KCAS, POH 51")
    }

    /// [P]: 46 KCAS flaps 30, power off. Tolerance 4 kt.
    @Test func c172StallFlaps30() throws {
        var p = try TestPilot(model: "c172p")
        p.loadC172ToMaxWeight()
        try p.startInAir(altitudeFeet: 5_000, knots: 70, flaps: 1)
        let v = p.minimumSpeedStall()
        #expect(abs(v - 46) <= 4, "stall flaps 30 \(v) KCAS, POH 46")
    }

    /// [C]: ~700 fpm at sea level, 15 C, Vy 76 KIAS, full throttle. Tolerance 15%.
    @Test func c172ClimbAtVy() throws {
        var p = try TestPilot(model: "c172p")
        p.loadC172ToMaxWeight()
        try p.startInAir(altitudeFeet: 500, knots: 76, flaps: 0)
        let roc = p.climbRate(atKnots: 76)
        #expect(abs(roc - 700) / 700 <= 0.15, "climb \(roc) fpm, POH ~700 (\(p.lastClimbDiagnostics))")
    }

    /// [C]: ground roll ~890 ft, sea level, 15 C, flaps 10, short-field technique, lift-off
    /// 51 KIAS. Tolerance 20%.
    @Test func c172TakeoffGroundRoll() throws {
        var p = try TestPilot(model: "c172p")
        p.loadC172ToMaxWeight()
        let roll = try p.takeoffGroundRoll(rotateKnots: 49, flaps: 1.0 / 3)
        #expect(abs(roll - 890) / 890 <= 0.20, "ground roll \(roll) ft, POH ~890")
    }

    /// Trim converges in straight and level flight at 5,000 ft, 100 KIAS and holds for 30 s.
    @Test func c172TrimHoldsLevelFlight() throws {
        var p = try TestPilot(model: "c172p")
        try p.startInAir(altitudeFeet: 5_000, knots: 100, flaps: 0)
        let h0 = p.fdm.get("position/h-sl-ft")
        var maxDev = 0.0
        for _ in 0..<(120 * 30) {
            p.fdm.step()
            maxDev = max(maxDev, abs(p.fdm.get("position/h-sl-ft") - h0))
        }
        #expect(maxDev < 50, "altitude wandered \(maxDev) ft")
        #expect(abs(p.fdm.get("velocities/vc-kts") - 100) < 2)
    }

    // MARK: A320 at 64 t (tuned generic JSBSim model; see aircraft/A320/TUNING.md)

    /// Derived from [A]: VS1g CONF FULL ~109 kt at 64.5 t, so ~108.6 at 64.0 t. Tolerance 8 kt.
    @Test func a320StallConfFull() throws {
        var p = try TestPilot(model: "A320")
        try p.startInAir(altitudeFeet: 10_000, knots: 160, flaps: 1)
        let w = p.weightPounds * 0.4536 / 1000
        let reference = 109 * (w / 64.5).squareRoot()
        let v = p.stallSpeed()
        #expect(abs(v - reference) <= 8, "VS1g FULL \(v) kt at \(w) t, reference \(reference) (\(p.lastStallDiagnostics))")
    }

    /// At [A]'s 136 kt in CONF FULL on a 3 degree glide path the real aircraft flies about 2.5
    /// degrees nose up. The model must trim to a plausible attitude (0 to 5 degrees).
    @Test func a320ApproachAttitude() throws {
        let fdm = try FlightDynamics(model: "A320")
        var ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 0,
                                   heightAboveGroundFeet: 1_500, headingDegrees: 90, airspeedKnots: 136)
        ic.flaps = 1
        fdm.set("ic/gamma-deg", -3)
        try fdm.initialize(ic)
        fdm.set("ic/gamma-deg", -3)
        var c = ControlInputs()
        c.flaps = 1
        fdm.apply(c)
        try fdm.trim(.full)
        let pitch = fdm.get("attitude/theta-deg")
        #expect(pitch > 0 && pitch < 5, "approach pitch \(pitch) deg")
    }

    /// PLAN.md: trims at FL350, Mach 0.78 (268 KCAS in the standard atmosphere).
    @Test func a320TrimsAtCruise() throws {
        let fdm = try FlightDynamics(model: "A320")
        let ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 0,
                                   heightAboveGroundFeet: 35_000, headingDegrees: 90, airspeedKnots: 268)
        try fdm.initialize(ic)
        var c = ControlInputs()
        c.gearDown = false
        fdm.apply(c)
        try fdm.trim(.full)
        #expect(abs(fdm.get("velocities/mach") - 0.78) < 0.02)
        #expect(fdm.get("aero/alpha-deg") > 0 && fdm.get("aero/alpha-deg") < 6)
    }

    /// Hands-off after a trim at 250 KCAS, 10,000 ft: no divergence in 60 s (guards the
    /// stability changes in tuning T1 and T4).
    @Test func a320StableHandsOff() throws {
        let fdm = try FlightDynamics(model: "A320")
        let ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 0,
                                   heightAboveGroundFeet: 10_000, headingDegrees: 90, airspeedKnots: 250)
        try fdm.initialize(ic)
        var c = ControlInputs()
        c.gearDown = false
        fdm.apply(c)
        try fdm.trim(.full)
        let h0 = fdm.get("position/h-sl-ft")
        var maxDev = 0.0
        for _ in 0..<(120 * 60) {
            fdm.step()
            maxDev = max(maxDev, abs(fdm.get("position/h-sl-ft") - h0))
        }
        #expect(maxDev < 200, "altitude deviation \(maxDev) ft")
    }

    /// Sanity: rotates and lifts off within a realistic runway length at 64 t, flaps 10.
    @Test func a320LiftsOffWithinRunwayLength() throws {
        var p = try TestPilot(model: "A320")
        let roll = try p.takeoffGroundRoll(rotateKnots: 145, flaps: 0.25)
        #expect(roll < 7_500, "ground roll \(roll) ft")
    }
}
