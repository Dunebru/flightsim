import Foundation
import Testing
@testable import FlightModel

/// Exploration: prints how the bundled C172P behaves. Not an assertion of published numbers.
@Test func exploreC172() throws {
    let fdm = try FlightDynamics(model: "c172p")
    print("explore engines:", fdm.engineCount, "version", FlightDynamics.engineVersion)
    var ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 1135,
                               heightAboveGroundFeet: 0, headingDegrees: 90, airspeedKnots: 0)
    try fdm.initialize(ic)
    var c = ControlInputs()
    c.throttle = 0.2
    c.brakes = 1
    fdm.apply(c)
    fdm.step(240)
    var s = fdm.state
    print(String(format: "explore ground: rpm %.0f agl %.2f onGround %@ ias %.1f", s.engineIndication, s.heightAboveGroundFeet, s.onGround ? "yes" : "no", s.indicatedAirspeedKnots))
    print("explore weight lb:", fdm.get("inertia/weight-lbs"), "fuel lb:", fdm.get("propulsion/total-fuel-lbs"))

    ic.heightAboveGroundFeet = 5000 - 1135
    ic.airspeedKnots = 100
    ic.gearDown = true
    try fdm.initialize(ic)
    do { try fdm.trim(.full) } catch { print("explore trim error:", error) }
    s = fdm.state
    print(String(format: "explore trimmed: ias %.1f alt %.0f pitch %.2f deg rpm %.0f elev %.3f throttle %.3f", s.indicatedAirspeedKnots, s.altitudeFeet, s.pitch * 57.3, s.engineIndication, fdm.get("fcs/elevator-cmd-norm"), fdm.get("fcs/throttle-cmd-norm")))
    fdm.step(120 * 30)
    s = fdm.state
    print(String(format: "explore after 30 s: ias %.1f alt %.0f vs %.0f fpm pitch %.2f roll %.2f", s.indicatedAirspeedKnots, s.altitudeFeet, s.verticalSpeedFPM, s.pitch * 57.3, s.roll * 57.3))
}
