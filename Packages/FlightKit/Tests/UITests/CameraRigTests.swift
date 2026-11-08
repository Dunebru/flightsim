import Foundation
import Testing
import simd
@testable import UI

struct CameraRigTests {
    /// Heading east, level: the cockpit camera looks east and sits forward of the airframe centre.
    @Test func cockpitLooksAlongTheNose() {
        var rig = CameraRig()
        rig.mode = .cockpit
        rig.lookPitch = 0
        // Let any transition finish.
        var pose = rig.pose(aircraftPosition: .zero, heading: .pi / 2, pitch: 0, roll: 0, dt: 1)
        pose = rig.pose(aircraftPosition: .zero, heading: .pi / 2, pitch: 0, roll: 0, dt: 1)
        #expect(pose.forward.x > 0.99, "forward \(pose.forward)")
        #expect(pose.position.x > 0.5, "eye should be forward of centre: \(pose.position)")
        #expect(abs(pose.up.z - 1) < 1e-9)
    }

    /// Banked right 30 degrees: the cockpit horizon tilts with the aircraft.
    @Test func cockpitBanksWithTheAircraft() {
        var rig = CameraRig()
        rig.mode = .cockpit
        _ = rig.pose(aircraftPosition: .zero, heading: 0, pitch: 0, roll: 0.5236, dt: 1)
        let pose = rig.pose(aircraftPosition: .zero, heading: 0, pitch: 0, roll: 0.5236, dt: 1)
        // Heading north, right wing down: the camera's up vector leans toward the right (east).
        #expect(pose.up.x > 0.45, "up \(pose.up)")
    }

    /// Body-to-world matches the renderer: a nose-up pitch raises the nose.
    @Test func noseUpRaisesTheNose() {
        let r = CameraRig.bodyToWorld(heading: .pi / 2, pitch: 0.2, roll: 0)
        let nose = r * SIMD3<Double>(1, 0, 0)
        #expect(nose.z > 0.19 && nose.x > 0.97)
    }

    /// Switching views blends over 0.6 s rather than cutting.
    @Test func switchingViewsBlends() {
        var rig = CameraRig()
        let chase = rig.pose(aircraftPosition: .zero, heading: 0, pitch: 0, roll: 0, dt: 0.016)
        rig.mode = .tower
        let mid = rig.pose(aircraftPosition: .zero, heading: 0, pitch: 0, roll: 0, dt: 0.3)
        let towerPos = rig.towerPosition
        let d0 = simd_distance(mid.position, chase.position), d1 = simd_distance(mid.position, towerPos)
        #expect(d0 > 1 && d1 > 1, "halfway through the blend the camera is between the two views")
        let end = rig.pose(aircraftPosition: .zero, heading: 0, pitch: 0, roll: 0, dt: 0.5)
        #expect(simd_distance(end.position, towerPos) < 1e-6)
    }

    /// Regression: an absolute z >= 0.5 clamp lifted the chase camera 8 m when the runway sat
    /// below the scene origin (KPHX runway 08, 7.4 m below field elevation).
    @Test func chaseCameraFollowsAnAircraftBelowTheOrigin() {
        var rig = CameraRig()
        let p = SIMD3<Double>(-1_800, 400, -7.4)
        let pose = rig.pose(aircraftPosition: p, heading: .pi / 2, pitch: 0, roll: 0, dt: 1)
        let expected = p.z + 1.2 + rig.orbitDistance * sin(rig.orbitPitch)
        #expect(abs(pose.position.z - expected) < 0.01, "camera at \(pose.position.z), expected \(expected)")
    }
}
