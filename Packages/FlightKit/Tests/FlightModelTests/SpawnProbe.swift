import Foundation
import Testing
@testable import FlightModel

/// An on-ground start must settle quietly on the gear. Regression: starting with the reference
/// point at ground level buried the gear, launched the aircraft at 850 fpm and left it resting on
/// a wingtip at 20 degrees of bank (seen on the phone 2026-11-07).
struct GroundStartTests {
    static let ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 1135,
                                      heightAboveGroundFeet: 0, headingDegrees: 90, airspeedKnots: 0)

    @Test(arguments: ["c172p", "A320"])
    func settlesLevelOnTheGear(model: String) throws {
        let fdm = try FlightDynamics(model: model)
        for attempt in 0..<2 {          // first spawn, then a reset on the ground
            try fdm.initialize(Self.ic)
            var c = ControlInputs()
            c.parkingBrake = true
            fdm.apply(c)
            var worstRoll = 0.0, worstClimb = 0.0
            for _ in 0..<48 {
                fdm.step(10)
                let s = fdm.state
                worstRoll = max(worstRoll, abs(s.roll) * 180 / .pi)
                worstClimb = max(worstClimb, abs(s.verticalSpeedFPM))
            }
            let s = fdm.state
            #expect(s.onGround, "\(model) attempt \(attempt): not on the ground")
            #expect(worstRoll < 2, "\(model) attempt \(attempt): rolled \(worstRoll) degrees")
            #expect(worstClimb < 150, "\(model) attempt \(attempt): vertical speed \(worstClimb) fpm while settling")
            #expect(abs(s.pitch * 180 / .pi) < 5, "\(model) attempt \(attempt): pitch \(s.pitch * 180 / .pi)")
            #expect(abs(s.heading * 180 / .pi - 90) < 1, "\(model) attempt \(attempt): heading \(s.heading * 180 / .pi)")
        }
    }
}

/// The solid ground follows the scenery: as the terrain elevation under the aircraft rises (taxiing
/// up a 50 ft slope), the aircraft rides up with it and stays on its gear at the same height above
/// the ground. Fails if the terrain property is not applied (the gear would end up buried).
struct TerrainFollowingTests {
    @Test func aircraftRidesUpWithTheGround() throws {
        let fdm = try FlightDynamics(model: "c172p")
        try fdm.initialize(GroundStartTests.ic)
        var c = ControlInputs()
        c.parkingBrake = true
        fdm.apply(c)
        fdm.step(240)
        let before = fdm.state
        // Raise the ground 50 ft over 5 s (a gentle slope), then let it settle for 2 s.
        for i in 1...600 {
            fdm.setTerrainElevation(feet: 1135 + 50 * Double(i) / 600)
            fdm.step()
        }
        fdm.step(240)
        let after = fdm.state
        #expect(abs(fdm.terrainElevationFeet - 1185) < 0.01)
        #expect(abs((after.altitudeFeet - before.altitudeFeet) - 50) < 1, "climbed \(after.altitudeFeet - before.altitudeFeet) ft")
        #expect(abs(after.heightAboveGroundFeet - before.heightAboveGroundFeet) < 0.5,
                "height above ground \(before.heightAboveGroundFeet) -> \(after.heightAboveGroundFeet)")
        #expect(after.onGround)
    }
}
