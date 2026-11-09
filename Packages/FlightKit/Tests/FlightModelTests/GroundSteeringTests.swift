import Foundation
import Testing
@testable import FlightModel

/// The nose wheel steers. Taxiing at about 10 kt with the tiller at half (about 37 degrees of
/// nose wheel), an A320 settles into a turn of more than 10 degrees a second (the geometry gives
/// about 20 with no tyre slip); a C172 with full rudder pedal (10 degrees of nose wheel) more
/// than 15. Before the steering command was passed to JSBSim, both managed under 0.2.
@Test(arguments: [("A320", 0.5, 10.0), ("c172p", 1.0, 15.0)])
func noseWheelSteersWhileTaxiing(model: String, steering: Double, minimumRate: Double) throws {
    let fdm = try FlightDynamics(model: model)
    let ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 1135,
                               heightAboveGroundFeet: 0, headingDegrees: 90, airspeedKnots: 0)
    try fdm.initialize(ic)
    var c = ControlInputs()
    // Accelerate straight to about 10 kt, then hold it there with power and brakes.
    var t = 0.0
    while t < 60, fdm.state.groundSpeedKnots < 10 {
        c.throttle = model == "A320" ? 0.3 : 0.5
        fdm.apply(c); fdm.step(1); t += 1.0 / 120
    }
    #expect(fdm.state.groundSpeedKnots >= 10, "\(model) never reached taxi speed")
    c.steering = steering
    var headings: [Double] = []
    for i in 0..<(120 * 9) {
        c.throttle = fdm.state.groundSpeedKnots > 11 ? 0 : (model == "A320" ? 0.25 : 0.4)
        c.brakes = fdm.state.groundSpeedKnots > 13 ? 0.3 : 0
        fdm.apply(c); fdm.step(1)
        if i % 120 == 0 { headings.append(fdm.state.heading * 180 / .pi) }
    }
    // The settled rate, over seconds 5 to 8.
    var turned = headings[8] - headings[5]
    turned = (turned + 540).truncatingRemainder(dividingBy: 360) - 180
    let rate = turned / 3
    print("\(model) turn rate \(rate) deg/s at \(fdm.state.groundSpeedKnots) kt, nose wheel \(fdm.state.noseSteeringDegrees ?? .nan) deg")
    #expect(rate > minimumRate, "\(model): \(rate) deg/s")
    #expect(fdm.state.onGround)
}
