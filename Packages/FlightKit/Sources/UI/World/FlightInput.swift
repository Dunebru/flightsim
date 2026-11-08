#if os(iOS)
import CoreMotion
import GameController
import Foundation

/// Tilt steering from the device's gravity vector, relative to a calibrated neutral attitude.
///
/// Holding the phone in landscape: rotating it like a steering wheel banks (right is
/// clockwise), and tilting the top edge toward you pitches up. Rotation in the screen plane and
/// the screen normal's elevation are measured in the device frame, so the mapping is the same
/// in either landscape orientation.
final class TiltInput {
    private let motion = CMMotionManager()
    private var neutral: CMAcceleration?
    private var latest: CMAcceleration?

    /// Degrees of tilt for full deflection.
    var rollRange: Double = 28
    var pitchRange: Double = 22
    /// Degrees ignored around neutral.
    var deadZone: Double = 1.5
    /// 0 = linear ... 1 = strongly expo (fine control near centre).
    var expo: Double = 0.35

    var isAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity else { return }
            self.latest = g
            if self.neutral == nil { self.neutral = g }
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }

    /// Takes the current attitude as neutral.
    func calibrate() { neutral = latest }

    /// (pitch, roll), each -1...1, or nil before the first motion sample.
    func read() -> (pitch: Double, roll: Double)? {
        guard let g = latest, let n = neutral else { return nil }
        let angle = atan2(g.y, g.x), angle0 = atan2(n.y, n.x)
        var dRoll = (angle - angle0) * 180 / .pi
        if dRoll > 180 { dRoll -= 360 }
        if dRoll < -180 { dRoll += 360 }
        let dPitch = (asin(max(-1, min(1, g.z))) - asin(max(-1, min(1, n.z)))) * 180 / .pi
        return (shape(dPitch, range: pitchRange), shape(dRoll, range: rollRange))
    }

    private func shape(_ degrees: Double, range: Double) -> Double {
        let magnitude = max(0, abs(degrees) - deadZone) / (range - deadZone)
        let x = min(1, magnitude)
        let curved = (1 - expo) * x + expo * x * x * x
        return degrees < 0 ? -curved : curved
    }
}

/// MFi, PlayStation and Xbox controllers through the GameController framework.
/// Left stick: pitch and roll. Right stick horizontal: rudder. Triggers: thrust up and down.
final class GamepadInput {
    var isConnected: Bool { GCController.current?.extendedGamepad != nil }

    struct Reading {
        var pitch: Double
        var roll: Double
        var yaw: Double
        /// Thrust change per second requested by the triggers.
        var throttleRate: Double
    }

    func read() -> Reading? {
        guard let pad = GCController.current?.extendedGamepad else { return nil }
        func dz(_ v: Float) -> Double { abs(v) < 0.06 ? 0 : Double(v) }
        return Reading(
            pitch: -dz(pad.leftThumbstick.yAxis.value),     // stick back is nose up
            roll: dz(pad.leftThumbstick.xAxis.value),
            yaw: dz(pad.rightThumbstick.xAxis.value),
            throttleRate: Double(pad.rightTrigger.value - pad.leftTrigger.value) * 0.5
        )
    }
}
#endif
