public import Foundation
public import simd
public import SimCore

// MARK: - GPU structs (layouts mirror Shaders/00_Common.metal and 20_Scene.metal exactly)

struct FrameUniforms {
    var viewProj = matrix_identity_float4x4
    var viewProjNoJitter = matrix_identity_float4x4
    var prevViewProjNoJitter = matrix_identity_float4x4
    var invViewProjNoJitter = matrix_identity_float4x4
    var shadowViewProj = matrix_identity_float4x4
    var cameraDelta = SIMD4<Float>.zero
    var sunDirection = SIMD4<Float>.zero
    var sunIlluminance = SIMD4<Float>.zero
    var atmosphere = SIMD4<Float>.zero
    var noiseOrigin = SIMD4<Float>.zero
    var renderSize = SIMD4<Float>.zero
    var jitter = SIMD4<Float>.zero
    var shadowParams = SIMD4<Float>.zero
    var debug = SIMD4<Float>.zero
}

struct MeshVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD2<Float>
    var pad = SIMD2<Float>.zero
}

struct DrawUniforms {
    var model = matrix_identity_float4x4
    var prevModel = matrix_identity_float4x4
    var baseColor = SIMD4<Float>(1, 1, 1, 1)
    var material = SIMD4<Float>(0.8, 0, 0, 0)     // roughness, metallic, textured, kind
    var emissive = SIMD4<Float>.zero
}

enum SurfaceKind: Float {
    case aircraft = 0, runway = 1, marking = 2, ground = 3, terrain = 4
}

/// Size of the GPU-side lighting state (three float4).
let lightingStateSize = 48

// MARK: - Scene description

/// Camera that orbits a target point, as in a chase or free-orbit view.
public struct OrbitCamera: Sendable, Equatable {
    /// Point looked at, in world metres (ENU from the scene origin).
    public var target: SIMD3<Double>
    /// Direction the camera looks, radians clockwise from north.
    public var yaw: Double
    /// Downward look angle, radians (positive looks down).
    public var pitch: Double
    /// Distance from the target, metres.
    public var distance: Double
    /// Vertical field of view, radians.
    public var fovY: Double

    public init(target: SIMD3<Double>, yaw: Double, pitch: Double, distance: Double, fovY: Double = 50 * .pi / 180) {
        self.target = target
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.fovY = fovY
    }

    /// Unit view direction in world ENU.
    public var forward: SIMD3<Double> {
        SIMD3(sin(yaw) * cos(pitch), cos(yaw) * cos(pitch), -sin(pitch))
    }

    /// Camera position in world metres, kept at least 0.5 m above the ground.
    public var position: SIMD3<Double> {
        var p = target - forward * distance
        p.z = max(p.z, 0.5)
        return p
    }
}

/// A camera with full orientation (the cockpit and wing views bank with the aircraft).
public struct CameraPose: Sendable, Equatable {
    /// World metres (ENU from the scene origin).
    public var position: SIMD3<Double>
    /// Unit view direction.
    public var forward: SIMD3<Double>
    /// Unit up direction (perpendicular to forward).
    public var up: SIMD3<Double>
    public var fovY: Double

    public init(position: SIMD3<Double>, forward: SIMD3<Double>, up: SIMD3<Double> = SIMD3(0, 0, 1), fovY: Double) {
        self.position = position
        self.forward = forward
        self.up = up
        self.fovY = fovY
    }
}

extension OrbitCamera {
    public var pose: CameraPose { CameraPose(position: position, forward: forward, up: SIMD3(0, 0, 1), fovY: fovY) }
}

/// Everything the renderer needs to draw one frame.
public struct SceneDescription: Sendable {
    /// Geodetic position of the scene origin (drives the sun and the atmosphere).
    public var origin: Geodetic
    public var date: Date
    public var camera: OrbitCamera
    /// When set, overrides `camera` (cockpit, wing and tower views).
    public var cameraPose: CameraPose?
    /// Aircraft reference point on the ground, world metres, and heading (radians from north).
    public var aircraftPosition: SIMD3<Double>
    public var aircraftHeading: Double
    /// Bank angle, radians, right wing down positive.
    public var aircraftRoll: Double = 0
    /// Pitch attitude, radians, nose up positive.
    public var aircraftPitch: Double = 0
    public var showGround = true
    public var showRunway = true
    public var showAircraft = true
    /// Added to every world position (camera included). Used by the floating-origin test.
    public var worldOffset = SIMD3<Double>.zero

    public init(origin: Geodetic, date: Date, camera: OrbitCamera,
                aircraftPosition: SIMD3<Double>, aircraftHeading: Double) {
        self.origin = origin
        self.date = date
        self.camera = camera
        self.aircraftPosition = aircraftPosition
        self.aircraftHeading = aircraftHeading
    }

    /// The M1 test scene: KPHX runway 8/26, aircraft near the runway 8 threshold, chase camera
    /// off its left rear quarter.
    public static func phoenixTest(date: Date) -> SceneDescription {
        let aircraft = PhoenixSite.centreline(-1_600)
        return SceneDescription(
            origin: PhoenixSite.origin,
            date: date,
            camera: OrbitCamera(target: aircraft + SIMD3(0, 0, 1.2), yaw: 70 * .pi / 180,
                                pitch: 8 * .pi / 180, distance: 15),
            aircraftPosition: aircraft,
            aircraftHeading: PhoenixSite.runwayHeading * .pi / 180
        )
    }
}

// MARK: - Settings and statistics

public enum UpscalerMode: String, Sendable, CaseIterable {
    /// MetalFX temporal upscaling and anti-aliasing (jittered, uses depth and motion).
    case temporal
    /// MetalFX spatial upscaling.
    case spatial
    /// No MetalFX; bilinear upscale in the final pass (the iOS Simulator path).
    case off
}

public struct RenderSettings: Sendable, Equatable {
    public var upscaler: UpscalerMode = .temporal
    /// Render resolution as a fraction of the output resolution.
    public var renderScale: Double = 0.67
    /// Draw world positions without the floating origin (test and demonstration only).
    public var disableFloatingOrigin = false
    /// Hand MetalFX the opposite jitter sign (test only: proves the sign matters).
    public var flipJitterSignForTest = false

    public init(upscaler: UpscalerMode = .temporal, renderScale: Double = 0.67) {
        self.upscaler = upscaler
        self.renderScale = renderScale
    }
}

public struct FrameStats: Sendable, Equatable {
    /// Exponentially averaged GPU time per pass, milliseconds.
    public var gpuMilliseconds: [String: Double] = [:]
    public var gpuTotalMilliseconds: Double = 0
    /// GPU span of a whole frame: first stage start to last stage end, averaged. Stages of
    /// consecutive frames can overlap and the GPU clock varies, so the per-stage sum above
    /// overstates the cost; this is the number to compare against the frame budget.
    public var gpuFrameMilliseconds: Double = 0
    /// CPU time spent encoding the frame, milliseconds.
    public var cpuMilliseconds: Double = 0
    public var renderSize = SIMD2<Int>(0, 0)
    public var outputSize = SIMD2<Int>(0, 0)
    public var upscaler: UpscalerMode = .off
    public var frameCount = 0

    public init() {}
}
