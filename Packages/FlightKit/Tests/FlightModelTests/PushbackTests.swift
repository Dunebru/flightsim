import Foundation
import Testing
@testable import FlightModel

/// The tug pushes an A320 (engines at idle, parking brake off) back at walking pace, stops it
/// after 45 m straight, or after about a quarter turn with the tail swung the way asked.
@Test(arguments: PushbackTug.Direction.allCases)
func pushbackMovesTheA320(direction: PushbackTug.Direction) throws {
    let fdm = try FlightDynamics(model: "A320")
    #expect(fdm.canPushBack)
    let ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 1135,
                               heightAboveGroundFeet: 0, headingDegrees: 0, airspeedKnots: 0)
    try fdm.initialize(ic)
    var tug = PushbackTug(direction: direction)
    var c = ControlInputs()
    let dt = 1.0 / 120
    let start = fdm.state
    var fastest = 0.0
    var t = 0.0
    while t < 240, tug.phase != .done {
        let s = fdm.state
        let cmd = tug.update(dt: dt, heading: s.heading, forwardKnots: s.forwardSpeedKnots, weightPounds: fdm.get("inertia/weight-lbs"))
        fdm.setPushback(pounds: cmd.pounds)
        c.steering = cmd.steering
        c.brakes = cmd.brakes
        fdm.apply(c)
        fdm.step(1)
        t += dt
        fastest = max(fastest, -fdm.state.forwardSpeedKnots)
    }
    let end = fdm.state
    var turn = (end.heading - start.heading) * 180 / .pi
    turn = (turn + 540).truncatingRemainder(dividingBy: 360) - 180
    // Moved backwards: heading 0 is north, so the aircraft ends up south of where it was.
    let movedNorth = (end.latitude - start.latitude) * 111_320
    print("pushback \(direction): \(t) s, \(tug.distance) m, turned \(turn) deg, fastest \(fastest) kt, north \(movedNorth) m")
    #expect(tug.phase == .done, "\(direction): still \(tug.phase) after \(t) s")
    #expect(fastest > 1.5 && fastest < 4, "\(direction): \(fastest) kt")
    #expect(movedNorth < -10)
    switch direction {
    case .straight: #expect(abs(turn) < 3); #expect(tug.distance > 44)
    // Tail left (to the west, facing north): the nose swings right, heading increases.
    case .tailLeft: #expect(turn > 80 && turn < 100)
    case .tailRight: #expect(turn < -80 && turn > -100)
    }
    #expect(abs(end.forwardSpeedKnots) < 0.3)
}
