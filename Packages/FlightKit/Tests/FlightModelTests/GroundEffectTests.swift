import Foundation
import Testing
@testable import FlightModel

/// PLAN.md M2 criterion 6: ground effect present. Lift coefficient at the same angle of attack is
/// higher at 0.2 spans above the ground than at 2 spans.
@Test(arguments: ["c172p", "A320"])
func groundEffectRaisesLiftNearTheGround(model: String) throws {
    let fdm = try FlightDynamics(model: model)
    let span = fdm.get("metrics/bw-ft")
    func liftCoefficient(atSpans h: Double) throws -> Double {
        var ic = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 0,
                                   heightAboveGroundFeet: h * span, headingDegrees: 90,
                                   airspeedKnots: model == "A320" ? 160 : 70)
        ic.gearDown = true
        try fdm.initialize(ic)
        fdm.set("ic/alpha-deg", 5)
        _ = fdm.set("fcs/elevator-cmd-norm", 0)
        fdm.step(1)
        return fdm.get("aero/cl-squared").squareRoot() / max(fdm.get("aero/function/kCLge"), 1e-9) * fdm.get("aero/function/kCLge")
    }
    let near = try liftCoefficient(atSpans: 0.2)
    let nearFactor = fdm.get("aero/function/kCLge")
    let far = try liftCoefficient(atSpans: 2.0)
    let farFactor = fdm.get("aero/function/kCLge")
    #expect(nearFactor > 1.05, "\(model): ground-effect lift factor at 0.2 spans is \(nearFactor)")
    #expect(abs(farFactor - 1) < 0.001, "\(model): factor at 2 spans is \(farFactor)")
    #expect(near > 0 && far > 0)
}
