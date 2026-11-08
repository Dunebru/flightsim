import Foundation
import Renderer
import simd

/// The five views, computed from the aircraft's pose, with eased transitions between them.
nonisolated struct CameraRig {
    enum Mode: Equatable { case cockpit, chase, tower, wing, orbit }

    var mode: Mode = .chase {
        didSet { if mode != oldValue { beginTransition() } }
    }

    // User adjustments (drag and pinch).
    var orbitYaw: Double = -25 * .pi / 180      // chase: relative to heading; orbit: absolute
    var orbitPitch: Double = 8 * .pi / 180
    var orbitDistance: Double = 15
    var lookYaw: Double = 0                     // cockpit head turn
    var lookPitch: Double = -6 * .pi / 180
    var zoom: Double = 1                        // tower and wing field-of-view factor

    /// Whether the aircraft's own geometry is drawn in this view. The C172 test model's
    /// instrument panel lives in separate FlightGear files that are not imported yet (M6), so the
    /// cockpit view is a clear pilot's-eye view for now rather than an empty cabin shell.
    var drawsAircraft: Bool { mode != .cockpit }

    /// Pilot eye and wing-camera positions in the body frame (x forward, y left, z up, metres,
    /// origin on the ground under the airframe centre). Set for the C172 test model.
    var eyeOffset = SIMD3<Double>(1.56, 0.27, 1.71)
    var wingOffset = SIMD3<Double>(0.1, 5.4, 2.15)
    /// Tower viewpoint near KPHX runway 8/26, north side, world metres.
    var towerPosition = SIMD3<Double>(-700, 420, 32)

    private var transitionFrom: CameraPose?
    private var transitionStart: Double = 0
    private var lastPose: CameraPose?
    private var clock: Double = 0
    static let transitionDuration = 0.6

    private mutating func beginTransition() {
        transitionFrom = lastPose
        transitionStart = clock
    }

    /// Body-to-world rotation, matching the renderer: heading about z, pitch about y (nose up is
    /// negative), bank about x.
    static func bodyToWorld(heading: Double, pitch: Double, roll: Double) -> simd_double3x3 {
        func rz(_ a: Double) -> simd_double3x3 {
            simd_double3x3(columns: (SIMD3(cos(a), sin(a), 0), SIMD3(-sin(a), cos(a), 0), SIMD3(0, 0, 1)))
        }
        func ry(_ a: Double) -> simd_double3x3 {
            simd_double3x3(columns: (SIMD3(cos(a), 0, -sin(a)), SIMD3(0, 1, 0), SIMD3(sin(a), 0, cos(a))))
        }
        func rx(_ a: Double) -> simd_double3x3 {
            simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(a), sin(a)), SIMD3(0, -sin(a), cos(a))))
        }
        return rz(.pi / 2 - heading) * ry(-pitch) * rx(roll)
    }

    /// The camera for this frame. `dt` advances the transition clock.
    mutating func pose(aircraftPosition p: SIMD3<Double>, heading: Double, pitch: Double, roll: Double, dt: Double) -> CameraPose {
        clock += dt
        let r = Self.bodyToWorld(heading: heading, pitch: pitch, roll: roll)
        var target: CameraPose
        switch mode {
        case .chase, .orbit:
            let yaw = mode == .chase ? heading + orbitYaw : orbitYaw
            let cam = OrbitCamera(target: p + SIMD3(0, 0, 1.2), yaw: yaw, pitch: orbitPitch, distance: orbitDistance)
            target = cam.pose
        case .cockpit:
            // Head turn in the body frame, then into the world with the aircraft's attitude.
            let look = SIMD3(cos(lookPitch) * cos(lookYaw), cos(lookPitch) * sin(lookYaw), sin(lookPitch))
            target = CameraPose(position: p + r * eyeOffset, forward: simd_normalize(r * look),
                                up: simd_normalize(r * SIMD3(0, 0, 1)), fovY: 68 * .pi / 180)
        case .wing:
            let look = simd_normalize(SIMD3<Double>(1.0, -0.22, -0.06))
            target = CameraPose(position: p + r * wingOffset, forward: simd_normalize(r * look),
                                up: simd_normalize(r * SIMD3(0, 0, 1)), fovY: 62 * .pi / 180 / zoom)
        case .tower:
            let toAircraft = p + SIMD3(0, 0, 1.5) - towerPosition
            let distance = simd_length(toAircraft)
            // Keep the aircraft about the same size on screen as it moves away.
            let fov = min(max(2 * atan(18 / distance), 1.5 * .pi / 180), 55 * .pi / 180) / zoom
            target = CameraPose(position: towerPosition, forward: toAircraft / distance, up: SIMD3(0, 0, 1), fovY: fov)
        }
        if let from = transitionFrom {
            let t = min(1, (clock - transitionStart) / Self.transitionDuration)
            let e = t * t * (3 - 2 * t)
            if t >= 1 {
                transitionFrom = nil
            } else {
                target = CameraPose(
                    position: from.position + (target.position - from.position) * e,
                    forward: simd_normalize(from.forward + (target.forward - from.forward) * e),
                    up: simd_normalize(from.up + (target.up - from.up) * e),
                    fovY: from.fovY + (target.fovY - from.fovY) * e
                )
            }
        }
        lastPose = target
        return target
    }

    // MARK: Gestures

    mutating func drag(_ dx: Double, _ dy: Double) {
        switch mode {
        case .cockpit:
            lookYaw = min(max(lookYaw - dx * 0.006, -2.6), 2.6)
            lookPitch = min(max(lookPitch + dy * 0.005, -1.1), 1.1)
        case .chase, .orbit:
            orbitYaw += dx * 0.008
            orbitPitch = min(max(orbitPitch + dy * 0.006, -0.15), 1.4)
        case .tower, .wing:
            break
        }
    }

    mutating func pinch(_ factor: Double) {
        switch mode {
        case .chase, .orbit: orbitDistance = min(max(orbitDistance / factor, 6), 400)
        case .tower, .wing: zoom = min(max(zoom * factor, 0.5), 8)
        case .cockpit: break
        }
    }
}
