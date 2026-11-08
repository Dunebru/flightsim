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
