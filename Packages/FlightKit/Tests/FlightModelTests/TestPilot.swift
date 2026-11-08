import Foundation
@testable import FlightModel

/// A simple, deterministic test pilot that flies JSBSim through standard performance manoeuvres.
/// Its loops are deliberately plain (proportional-derivative on pitch attitude); they only need to
/// hold the aircraft steady enough to measure it.
struct TestPilot {
    let fdm: FlightDynamics
    var controls = ControlInputs()
    let rate = 120.0
    var lastStallDiagnostics = ""

    init(model: String) throws {
        fdm = try FlightDynamics(model: model)
    }

    /// C172P at its 2,400 lb maximum: pilot 180 + co-pilot 180 + two rear passengers 170 each,
    /// with the model's 200 lb of fuel on a 1,500 lb empty weight.
    func loadC172ToMaxWeight() {
        fdm.set("inertia/pointmass-weight-lbs[1]", 180)
        fdm.set("inertia/pointmass-weight-lbs[2]", 170)
        fdm.set("inertia/pointmass-weight-lbs[3]", 170)
    }

    var weightPounds: Double { fdm.get("inertia/weight-lbs") }

    mutating func startInAir(altitudeFeet: Double, knots: Double, flaps: Double, gearDown: Bool = true) throws {
        var ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 0,
                                   heightAboveGroundFeet: altitudeFeet, headingDegrees: 90, airspeedKnots: knots)
        ic.flaps = flaps
        ic.gearDown = gearDown
        try fdm.initialize(ic)
        controls = ControlInputs()
        controls.flaps = flaps
        controls.gearDown = gearDown
        fdm.apply(controls)
        try fdm.trim(.full)
        controls.throttle = fdm.get("fcs/throttle-cmd-norm")
        controls.pitchTrim = fdm.get("fcs/pitch-trim-cmd-norm")
    }

    /// Pitch-attitude hold with rate damping; returns the elevator (pitch) command.
    func pitchCommand(toward thetaTargetDeg: Double, gain: Double = 0.08, damping: Double = 0.25) -> Double {
        let theta = fdm.get("attitude/theta-deg")
        let q = fdm.get("velocities/q-rad_sec") * 180 / .pi
        return max(-1, min(1, gain * (thetaTargetDeg - theta) - damping * q * 0.1))
    }

    /// Steps one physics tick with wings held level.
    mutating func tick(pitch: Double) {
        controls.pitch = pitch
        let phi = fdm.get("attitude/phi-deg")
        let p = fdm.get("velocities/p-rad_sec") * 180 / .pi
        controls.roll = max(-1, min(1, -0.05 * phi - 0.02 * p))
        fdm.apply(controls)
        fdm.step()
    }

    // MARK: Manoeuvres

    /// 1 g stall speed (calibrated, knots) from the maximum lift coefficient the model reaches in
    /// an idle-power angle-of-attack ramp of 0.5 deg/s:  VS1g = sqrt(2 W / (rho0 S CLmax)).
    /// Independent of how quickly a controller can chase altitude, which a heavy jet at idle
    /// outruns.
    mutating func stallSpeed() -> Double {
        controls.throttle = 0
        var alphaTarget = fdm.get("aero/alpha-deg")
        var clMax = 0.0
        var alphaAtMax = 0.0
        for _ in 0..<Int(rate * 90) {
            alphaTarget = min(alphaTarget + 0.5 / rate, 30)
            let alpha = fdm.get("aero/alpha-deg")
            let q = fdm.get("velocities/q-rad_sec") * 180 / .pi
            tick(pitch: max(-1, min(1, 0.15 * (alphaTarget - alpha) - 0.05 * q)))
            let cl = fdm.get("aero/cl-squared").squareRoot()
            if cl > clMax { clMax = cl; alphaAtMax = alpha }
            // Well past the lift peak: done.
            if alpha > alphaAtMax + 6 { break }
        }
        let w = weightPounds, area = fdm.get("metrics/Sw-sqft")
        let vs = (2 * w / (0.002_376_9 * area * clMax)).squareRoot() * 0.592_484
        lastStallDiagnostics = String(format: "CLmax %.2f at alpha %.1f deg, weight %.0f lb, S %.0f ft2", clMax, alphaAtMax, w, area)
        return vs
    }

    /// Steady climb at a calibrated airspeed with full power; returns the average climb rate (fpm)
    /// over `seconds` after `settle` seconds.
    mutating func climbRate(atKnots target: Double, settle: Double = 20, seconds: Double = 30) -> Double {
        controls.throttle = 1
        var theta = fdm.get("attitude/theta-deg")
        var climbed = 0.0
        var startH = 0.0
        for i in 0..<Int(rate * (settle + seconds)) {
            let v = fdm.get("velocities/vc-kts")
            let accel = fdm.get("accelerations/vdot-ft_sec2") * 0.5925
            theta += (0.06 * (v - target) + 0.2 * accel) / rate * 10
            theta = max(-5, min(20, theta))
            tick(pitch: pitchCommand(toward: theta))
            if i == Int(rate * settle) { startH = fdm.get("position/h-sl-ft") }
        }
        climbed = fdm.get("position/h-sl-ft") - startH
        return climbed / seconds * 60
    }

    /// Full-power takeoff roll from a standstill on the runway; rotates at `rotateKnots` and returns
    /// the ground distance until all wheels leave the ground, feet.
    mutating func takeoffGroundRoll(rotateKnots: Double, flaps: Double) throws -> Double {
        var ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 0,
                                   heightAboveGroundFeet: 0, headingDegrees: 90, airspeedKnots: 0)
        ic.flaps = flaps
        try fdm.initialize(ic)
        controls = ControlInputs()
        controls.flaps = flaps
        controls.throttle = 1
        controls.parkingBrake = true
        fdm.apply(controls)
        fdm.step(Int(rate * 3))   // full power against the brakes, as in a static run-up
        controls.parkingBrake = false
        let lat0 = fdm.get("position/lat-geod-deg"), lon0 = fdm.get("position/long-gc-deg")
        for _ in 0..<Int(rate * 90) {
            let v = fdm.get("velocities/vc-kts")
            let pitch = v >= rotateKnots ? pitchCommand(toward: 8) : 0
            // Keep it on the centreline with the rudder.
            let psi = fdm.get("attitude/psi-deg")
            controls.yaw = max(-1, min(1, 0.08 * (90 - psi)))
            tick(pitch: pitch)
            if !fdm.state.onGround {
                let lat = fdm.get("position/lat-geod-deg"), lon = fdm.get("position/long-gc-deg")
                let dy = (lat - lat0) * 364_000
                let dx = (lon - lon0) * 364_000 * cos(lat0 * .pi / 180)
                return (dx * dx + dy * dy).squareRoot()
            }
        }
        return .infinity
    }
}
