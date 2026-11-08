import Foundation
import Testing
@testable import Autopilot
@testable import FlightModel

/// The autopilot flying the real JSBSim models at 120 Hz, as the physics loop runs it.
struct APFlight {
    let fdm: FlightDynamics
    let ap: Autopilot
    var inputs = ControlInputs()
    var settings = AutopilotSettings()

    init(model: String, latitude: Double = 33.4342, longitude: Double = -112.0116, terrainFeet: Double = 0,
         heightFeet: Double, knots: Double, heading: Double, flaps: Double = 0, gearDown: Bool = true) throws {
        fdm = try FlightDynamics(model: model)
        ap = Autopilot(gains: .forModel(model))
        var ic = InitialConditions(latitude: latitude, longitude: longitude, terrainElevationFeet: terrainFeet,
                                   heightAboveGroundFeet: heightFeet, headingDegrees: heading, airspeedKnots: knots)
        ic.flaps = flaps
        ic.gearDown = gearDown
        try fdm.initialize(ic)
        inputs.flaps = flaps
        inputs.gearDown = gearDown
        fdm.apply(inputs)
        try fdm.trim(.full)
        inputs.throttle = fdm.get("fcs/throttle-cmd-norm")
        inputs.pitchTrim = fdm.get("fcs/pitch-trim-cmd-norm")
        settings.headingDegrees = heading
        settings.altitudeFeet = fdm.state.altitudeFeet
        settings.speedKnots = knots
    }

    /// Flies for a time, calling `each` with the state about every tenth of a second.
    mutating func fly(seconds: Double, _ each: (FlightState) -> Bool = { _ in true }) {
        ap.update(settings)
        let steps = Int(seconds * 120)
        for i in 0..<steps {
            var applied = inputs
            let state = fdm.state
            ap.control(state: state, inputs: &applied, dt: 1.0 / 120)
            fdm.apply(applied)
            fdm.step()
            if i % 12 == 0, !each(fdm.state) { return }
        }
    }
}

@Suite struct AutopilotFlightTests {
    /// HDG: a 90 degree turn at the bank limit, holding altitude through it.
    @Test func c172TurnsToHeadingAndHoldsAltitude() throws {
        var f = try APFlight(model: "c172p", heightFeet: 3_000, knots: 100, heading: 90)
        let start = f.fdm.state.altitudeFeet
        f.settings.engaged = true
        f.settings.headingDegrees = 180
        f.settings.verticalSpeedFPM = 500
        var maxBank = 0.0, maxAltError = 0.0
        f.fly(seconds: 70) { s in
            maxBank = max(maxBank, abs(s.roll * 180 / .pi))
            maxAltError = max(maxAltError, abs(s.altitudeFeet - start))
            return true
        }
        let s = f.fdm.state
        let heading = s.heading * 180 / .pi
        print(String(format: "AP C172 HDG: heading %.1f, max bank %.1f, max altitude error %.0f ft", heading, maxBank, maxAltError))
        #expect(abs(heading - 180) < 3)
        #expect(maxBank <= f.ap.gains.bankLimit + 3)
        #expect(maxAltError < 100)
        #expect(f.ap.status.lateral == .heading && f.ap.status.vertical == .altitude)
    }

    /// ALT with V/S: climbs at the selected rate, captures without overshooting, then holds.
    @Test func c172ClimbsAndCapturesAltitude() throws {
        var f = try APFlight(model: "c172p", heightFeet: 3_000, knots: 80, heading: 90)
        f.inputs.throttle = 1
        f.settings.engaged = true
        f.settings.altitudeFeet = 4_500
        f.settings.verticalSpeedFPM = 600
        var maxAltitude = 0.0, climbRates: [Double] = []
        f.fly(seconds: 300) { s in
            maxAltitude = max(maxAltitude, s.altitudeFeet)
            if s.altitudeFeet < 4_000 && s.altitudeFeet > 3_300 { climbRates.append(s.verticalSpeedFPM) }
            return true
        }
        var held: [Double] = []
        f.fly(seconds: 60) { s in held.append(s.altitudeFeet); return true }
        let meanClimb = climbRates.reduce(0, +) / Double(max(climbRates.count, 1))
        print(String(format: "AP C172 ALT: climb %.0f fpm, overshoot %.0f ft, held %.0f to %.0f", meanClimb,
                     maxAltitude - 4_500, held.min() ?? 0, held.max() ?? 0))
        #expect(abs(meanClimb - 600) < 120)
        #expect(maxAltitude - 4_500 < 120)
        #expect((held.min() ?? 0) > 4_450 && (held.max() ?? 0) < 4_550)
    }

    /// A/THR and a descent: speed held while descending at the selected rate to the altitude.
    @Test func a320HoldsSpeedThroughADescent() throws {
        var f = try APFlight(model: "A320", heightFeet: 10_000, knots: 250, heading: 90, gearDown: false)
        f.settings.engaged = true
        f.settings.autothrottle = true
        f.settings.speedKnots = 250
        f.settings.altitudeFeet = 7_000
        f.settings.verticalSpeedFPM = 1_500
        var speeds: [Double] = []
        f.fly(seconds: 200) { s in
            if s.time > 30 { speeds.append(s.indicatedAirspeedKnots) }
            return true
        }
        let s = f.fdm.state
        print(String(format: "AP A320 descent: altitude %.0f, speed %.0f to %.0f kt", s.altitudeFeet, speeds.min() ?? 0, speeds.max() ?? 0))
        #expect(abs(s.altitudeFeet - 7_000) < 60)
        #expect((speeds.min() ?? 0) > 238 && (speeds.max() ?? 0) < 262)
        #expect(f.ap.status.autothrottle)
    }

    /// APPR: from a 30 degree intercept below the glidepath, captures the localizer, then the
    /// glideslope, and is on both at 200 ft.
    @Test func a320FliesTheILS() throws {
        let field = 1_135.0
        let approach = ApproachPath(name: "ILS 08", thresholdLatitude: 33.4342, thresholdLongitude: -112.0116,
                                    thresholdElevationFeet: field, courseDegrees: 90, localizerDistanceMetres: 3_800)
        let r = 6_371_000.0
        // 11 km before the threshold, 1.5 km right of (south of) the course, 1,500 ft above the field.
        let lat = 33.4342 - 1_500 / r * 180 / .pi
        let lon = -112.0116 - 11_000 / (r * cos(33.4342 * .pi / 180)) * 180 / .pi
        var f = try APFlight(model: "A320", latitude: lat, longitude: lon, terrainFeet: field, heightFeet: 1_500,
                             knots: 150, heading: 60, flaps: 1)
        f.settings.engaged = true
        f.settings.autothrottle = true
        f.settings.speedKnots = 145
        f.settings.approachArmed = true
        f.settings.approach = approach
        var sawLocalizer = false, sawGlideslope = false
        var at200: (loc: Double, gs: Double)?
        let ap = f.ap
        f.fly(seconds: 400) { s in
            let st = ap.status
            if st.lateral == .localizer { sawLocalizer = true }
            if st.vertical == .glideslope { sawGlideslope = true }
            if s.heightAboveGroundFeet < 200 {
                at200 = (st.localizerDots ?? 9, st.glideslopeDots ?? 9)
                return false
            }
            return true
        }
        let a = try #require(at200, "never reached 200 ft (at \(Int(f.fdm.state.heightAboveGroundFeet)) ft)")
        print(String(format: "AP A320 ILS at 200 ft: LOC %.2f dots, G/S %.2f dots", a.loc, a.gs))
        #expect(sawLocalizer && sawGlideslope)
        #expect(abs(a.loc) < 0.3)
        #expect(abs(a.gs) < 0.5)
    }

    /// NAV: direct to the first point from wherever the aircraft is, an anticipated turn onto
    /// the second leg, then along it, close past the last point, holding its course after.
    @Test func c172FliesARoute() throws {
        var f = try APFlight(model: "c172p", heightFeet: 3_000, knots: 100, heading: 90)
        let r = 6_371_000.0, lat0 = 33.4342, lon0 = -112.0116
        func point(_ name: String, north: Double, east: Double) -> NavPoint {
            NavPoint(name: name, latitude: lat0 + north / r * 180 / .pi,
                     longitude: lon0 + east / (r * cos(lat0 * .pi / 180)) * 180 / .pi)
        }
        let a = point("A", north: 8_000, east: 2_000), b = point("B", north: 8_000, east: 14_000)
        f.settings.engaged = true
        f.settings.navEngaged = true
        f.settings.route = [a, b]
        let ap = f.ap
        var closestA = 1e9, closestB = 1e9, worstOnLeg2 = 0.0, sawNav = false
        f.fly(seconds: 420) { s in
            let da = a.offset(to: s.latitude, s.longitude), db = b.offset(to: s.latitude, s.longitude)
            closestA = min(closestA, (da.x * da.x + da.y * da.y).squareRoot())
            closestB = min(closestB, (db.x * db.x + db.y * db.y).squareRoot())
            if ap.status.lateral == .nav { sawNav = true }
            // Well established on the second leg (east, 8 km north): distance off its line.
            if ap.status.activeWaypoint == 1, db.y < -2_000, da.y > 3_000 { worstOnLeg2 = max(worstOnLeg2, abs(da.x)) }
            return true
        }
        print(String(format: "AP C172 NAV: closest to A %.0f m, to B %.0f m, worst off leg 2 %.0f m, active %@",
                     closestA, closestB, worstOnLeg2, ap.status.activeWaypoint.map(String.init) ?? "none"))
        #expect(sawNav)
        #expect(closestA < 800, "turned in early, within a turn radius")
        #expect(closestB < 200)
        #expect(worstOnLeg2 < 150)
        #expect(ap.status.activeWaypoint == nil, "past the last point")
    }

    /// Off means off: the pilot's inputs pass through untouched.
    @Test func disengagedPassesThePilotThrough() throws {
        let ap = Autopilot(gains: .c172)
        var settings = AutopilotSettings()
        settings.engaged = false
        ap.update(settings)
        var inputs = ControlInputs()
        inputs.pitch = 0.3
        inputs.roll = -0.2
        inputs.throttle = 0.7
        var state = FlightState()
        state.onGround = false
        ap.control(state: state, inputs: &inputs, dt: 1.0 / 120)
        #expect(inputs.pitch == 0.3 && inputs.roll == -0.2 && inputs.throttle == 0.7)
    }

    @Test func approachGeometry() {
        let a = ApproachPath(name: "t", thresholdLatitude: 33.4, thresholdLongitude: -112, thresholdElevationFeet: 1_000,
                             courseDegrees: 90, localizerDistanceMetres: 3_000)
        // 1 km west of the threshold and 100 m south: before it and right of an eastbound course.
        let r = 6_371_000.0
        let o = a.offsets(latitude: 33.4 - 100 / r * 180 / .pi, longitude: -112 - 1_000 / (r * cos(33.4 * .pi / 180)) * 180 / .pi)
        #expect(abs(o.along + 1_000) < 1 && abs(o.right - 100) < 1)
        // On the path: 3 degrees through 50 ft over the threshold.
        let path = a.pathAltitudeFeet(along: -1_000)
        #expect(abs(path - (1_050 + 1_000 * 3.280_84 * tan(3 * Double.pi / 180))) < 0.01)
    }
}
