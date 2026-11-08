import Foundation
import Testing
import FlightModel
@testable import UI

/// The flight model lets an aircraft hit the ground at 9,000 fpm and bounce back onto its
/// wheels; the sim calls that a crash.
struct CrashCheckTests {
    func state(onGround: Bool, vs: Double = 0, pitch: Double = 0, roll: Double = 0, height: Double = 4.4) -> FlightState {
        var s = FlightState()
        s.onGround = onGround
        s.verticalSpeedFPM = vs
        s.pitch = pitch * .pi / 180
        s.roll = roll * .pi / 180
        s.heightAboveGroundFeet = height
        return s
    }

    @Test func normalFlyingAndLandingIsNoCrash() {
        var check = CrashCheck(restingHeightFeet: 4.4)
        #expect(check.update(state(onGround: false, vs: -700, height: 40)) == nil)
        #expect(check.update(state(onGround: false, vs: -600, height: 5)) == nil)
        // A firm landing: 600 fpm at contact, gear compressing half a foot.
        #expect(check.update(state(onGround: true, vs: -600, pitch: 4, height: 3.9)) == nil)
        #expect(check.update(state(onGround: true, vs: 0, pitch: 0, height: 4.4)) == nil)
        // Taxiing hard round a corner: some roll on the gear.
        #expect(check.update(state(onGround: true, roll: 6)) == nil)
    }

    @Test func hardImpactIsACrash() {
        var check = CrashCheck(restingHeightFeet: 4.4)
        _ = check.update(state(onGround: false, vs: -2_400, pitch: -20, height: 20))
        #expect(check.update(state(onGround: true, vs: -2_400, pitch: -20, height: 3)) != nil)
    }

    @Test func strikesAreCrashes() {
        var check = CrashCheck(restingHeightFeet: 4.4)
        #expect(check.update(state(onGround: true, roll: 35)) != nil, "wingtip on the ground")
        check = CrashCheck(restingHeightFeet: 4.4)
        #expect(check.update(state(onGround: true, pitch: -18)) != nil, "propeller or nose in the ground")
        check = CrashCheck(restingHeightFeet: 4.4)
        #expect(check.update(state(onGround: true, height: 2.4)) != nil, "airframe two feet into the ground")
    }

    /// A crash stays reported until reset, even when the aircraft bounces back onto its wheels.
    @Test func staysCrashed() {
        var check = CrashCheck(restingHeightFeet: 4.4)
        _ = check.update(state(onGround: false, vs: -3_000, height: 10))
        let first = check.update(state(onGround: true, vs: -3_000, height: 3))
        #expect(first != nil)
        #expect(check.update(state(onGround: true, height: 4.4)) == first)
        check.reset()
        #expect(check.update(state(onGround: true, height: 4.4)) == nil)
    }
}
