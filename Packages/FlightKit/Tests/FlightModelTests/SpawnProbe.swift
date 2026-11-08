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

/// Weather reaches the flight model: a 20 kt headwind takes 20 kt off the groundspeed; a 20 kt
/// tailwind adds it. Fails if the wind properties are not applied.
struct WindTests {
    @Test func headwindAndTailwind() throws {
        func groundMinusTrue(windFromEast: Bool) throws -> Double {
            let fdm = try FlightDynamics(model: "c172p")
            let ic = InitialConditions(latitude: 33.44, longitude: -112.0, terrainElevationFeet: 1135,
                                       heightAboveGroundFeet: 3_000, headingDegrees: 90, airspeedKnots: 100)
            try fdm.initialize(ic)
            try fdm.trim(.full)
            var a = AtmosphereInputs()
            a.windEastKnots = windFromEast ? -20 : 20      // air moving west (headwind) or east (tailwind)
            fdm.setAtmosphere(a)
            fdm.step(600)
            let s = fdm.state
            return s.groundSpeedKnots - s.trueAirspeedKnots
        }
        let head = try groundMinusTrue(windFromEast: true), tail = try groundMinusTrue(windFromEast: false)
        #expect(abs(head + 20) < 3, "headwind: groundspeed minus true airspeed \(head)")
        #expect(abs(tail - 20) < 3, "tailwind: \(tail)")
    }
}

/// The geometry numbers the drawn model is placed by match the JSBSim files they were read
/// from (a model update that moves the gear or the CG fails here).
struct ProfileGeometryTests {
    @Test(arguments: [AircraftProfile.c172, .a320])
    func matchesTheJSBSimFile(profile: AircraftProfile) throws {
        let url = try #require(FlightDynamics.bundledRoot?.appendingPathComponent("aircraft/\(profile.id)/\(profile.id).xml"))
        let text = try String(contentsOf: url, encoding: .utf8)
        func location(after marker: String) throws -> SIMD3<Double> {
            let range = try #require(text.range(of: marker))
            let rest = text[range.upperBound...]
            func value(_ tag: String) throws -> Double {
                let open = try #require(rest.range(of: "<\(tag)>")), close = try #require(rest.range(of: "</\(tag)>"))
                return try #require(Double(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)))
            }
            return SIMD3(try value("x"), try value("y"), try value("z"))
        }
        let cg = try location(after: "<location name=\"CG\"")
        let nose = try location(after: profile.id == "A320" ? "name=\"NOSE_LG\"" : "name=\"NOSE\"")
        let main = try location(after: profile.id == "A320" ? "name=\"LEFT_MLG\"" : "name=\"LEFT_MAIN\"")
        #expect(abs((cg.x - nose.x) * 0.0254 - profile.noseWheelAheadOfCG) < 0.01)
        #expect(abs((cg.z - main.z) * 0.0254 - profile.cgAboveMainGear) < 0.01)
    }
}
