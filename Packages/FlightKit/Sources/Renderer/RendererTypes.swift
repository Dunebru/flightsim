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
    var worldShadowViewProj = matrix_identity_float4x4
    var cameraDelta = SIMD4<Float>.zero
    var sunDirection = SIMD4<Float>.zero
    var sunIlluminance = SIMD4<Float>.zero
    var atmosphere = SIMD4<Float>.zero
    var noiseOrigin = SIMD4<Float>.zero
    var renderSize = SIMD4<Float>.zero
    var jitter = SIMD4<Float>.zero
    var shadowParams = SIMD4<Float>.zero
    var worldShadowParams = SIMD4<Float>.zero
    var debug = SIMD4<Float>.zero
    var cloudShadow = SIMD4<Float>.zero
    var cloudShadowShift = SIMD4<Float>.zero
    var cloudLight = SIMD4<Float>.zero
    var fog = SIMD4<Float>.zero
    var weather = SIMD4<Float>.zero
    var moonDirection = SIMD4<Float>.zero
    var moonLight = SIMD4<Float>.zero
}

/// Matches StarGPU and StarUniforms in 26_Stars.metal.
struct StarGPU {
    var dirMag: SIMD4<Float>
    var colour: SIMD4<Float>
}

struct StarUniforms {
    var rotation = matrix_identity_float4x4
    var params = SIMD4<Float>.zero
}

/// A catalogue star for the sky: J2000 direction, visual magnitude, B-V colour index.
public struct SkyStar: Sendable {
    public var direction: SIMD3<Float>
    public var magnitude: Float
    public var colourIndex: Float

    /// Reads stars.bin from `flight-tools star-cook`.
    public static func load(_ url: URL) throws -> [SkyStar] {
        let data = try Data(contentsOf: url)
        guard data.count >= 8, data.prefix(4) == Data("STAR".utf8) else { return [] }
        return data.withUnsafeBytes { raw -> [SkyStar] in
            let count = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian)
            guard data.count >= 8 + count * 20 else { return [] }
            return (0..<count).map { i in
                func f(_ k: Int) -> Float { Float(bitPattern: raw.loadUnaligned(fromByteOffset: 8 + i * 20 + k * 4, as: UInt32.self).littleEndian) }
                return SkyStar(direction: SIMD3(f(0), f(1), f(2)), magnitude: f(3), colourIndex: f(4))
            }
        }
    }

    /// Colour from B-V through the star's temperature (Ballesteros 2012) and a blackbody fit,
    /// normalised to its brightest channel.
    var colour: SIMD3<Float> {
        let bv = Double(min(max(colourIndex, -0.4), 2.0))
        let t = 4_600 * (1 / (0.92 * bv + 1.7) + 1 / (0.92 * bv + 0.62))
        let k = t / 100
        let r = k <= 66 ? 255 : 329.7 * pow(k - 60, -0.1332)
        let g = k <= 66 ? 99.47 * log(k) - 161.12 : 288.12 * pow(k - 60, -0.0755)
        let b = k >= 66 ? 255 : (k <= 19 ? 0 : 138.52 * log(k - 10) - 305.04)
        let c = SIMD3(min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255)) / 255
        // Stars look far less coloured than their spectra; keep a hint.
        let tint = c / max(c.max(), 1e-3)
        return SIMD3<Float>(simd_mix(SIMD3<Double>(repeating: 1), tint, SIMD3(repeating: 0.45)))
    }
}

struct MeshVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD2<Float>
    var pad = SIMD2<Float>.zero
}

/// Must match `GPULight` and `LightUniforms` in 25_Lights.metal.
struct GPULight {
    var position: SIMD4<Float>
    var colour: SIMD4<Float>
    var direction: SIMD4<Float>
    var params: SIMD4<Float>
}

struct LightUniforms {
    var model = matrix_identity_float4x4
    var up = SIMD4<Float>(0, 0, 1, 0)
    var params = SIMD4<Float>.zero
}

/// The shared tree mesh: a unit icosphere canopy (w = 0) and a unit four-sided trunk (w = 1).
enum TreeMesh {
    static func vertices() -> [SIMD4<Float>] {
        // Pairs of (position with part in w, normal).
        let t: Float = (1 + Float(5).squareRoot()) / 2
        let raw: [SIMD3<Float>] = [SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
                                   SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
                                   SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1)].map(simd_normalize)
        let faces: [(Int, Int, Int)] = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4),
                                        (11, 10, 2), (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8),
                                        (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
        var out: [SIMD4<Float>] = []
        for (a, b, c) in faces {
            for i in [a, b, c] { out.append(SIMD4(raw[i], 0)); out.append(SIMD4(raw[i], 0)) }
        }
        // Trunk: four sides from z 0 to 1, half-width 1.
        let corners: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, -1)]
        for i in 0..<4 {
            let p = corners[i], q = corners[(i + 1) % 4]
            let n = simd_normalize(SIMD3(p.x + q.x, p.y + q.y, 0))
            for v in [SIMD3(p.x, p.y, 0), SIMD3(q.x, q.y, 0), SIMD3(q.x, q.y, 1), SIMD3(p.x, p.y, 0), SIMD3(q.x, q.y, 1), SIMD3(p.x, p.y, 1)] {
                out.append(SIMD4(v, 1)); out.append(SIMD4(n, 0))
            }
        }
        return out
    }
}

/// Must match `CompactVertex` in 20_Scene.metal (24 bytes): city buildings.
struct CompactVertex {
    var x, y, z: Float
    var nx, ny, nz, seed: Int8
    var u, v: Float
}

/// Must match `TerrainVertex` in 20_Scene.metal (20 bytes).
struct TerrainVertex {
    var x, y, z: Float
    var nx, ny, nz, nw: Int8
    var u, v: UInt16
}

struct DrawUniforms {
    var model = matrix_identity_float4x4
    var prevModel = matrix_identity_float4x4
    var baseColor = SIMD4<Float>(1, 1, 1, 1)
    var material = SIMD4<Float>(0.8, 0, 0, 0)     // roughness, metallic, textured, kind
    var emissive = SIMD4<Float>.zero
}

enum SurfaceKind: Float {
    case aircraft = 0, runway = 1, marking = 2, ground = 3, terrain = 4, pavement = 5, building = 6, sign = 7, tree = 8, parked = 9
}

/// Size of the GPU-side lighting state (three float4).
let lightingStateSize = 64

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
    /// (Keeping the camera above the ground is the caller's job: the ground is the terrain and
    /// airport surface, not a plane at z = 0. An absolute z clamp here once lifted the chase
    /// camera 8 m above KPHX runway 08, which sits below the field-elevation origin.)
    public var position: SIMD3<Double> {
        target - forward * distance
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
    /// Cloud layers to draw (at most three are used, lowest first).
    public var clouds: [CloudLayer] = []
    /// Wind at cloud height, metres per second toward (east, north): moves the cloud field.
    public var cloudWind = SIMD2<Double>.zero
    /// Reported visibility at the field (m); 15 km or more adds no mist.
    public var visibilityMetres: Double = 40_000
    /// How quickly mist thins with height (m): shallow for fog, deep for haze.
    public var fogScaleHeight: Double = 500
    /// Moving AI aircraft per airport (ICAO): instances in that airport's frame, (x, y, z,
    /// heading) and (seed, pitch, roll, lights: 1 landing, 2 taxi, 4 strobes, 8 beacon and nav).
    public var traffic: [String: TrafficInstances] = [:]
    /// Rain or snow falling around the camera.
    public var precipitation: Precipitation?
    /// How wet the ground is, 0 dry to 1 soaked: darker, glossier pavement.
    public var wetness: Double = 0

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

// MARK: - Clouds

/// One cloud layer for the renderer: heights above sea level, the fraction of sky it covers and
/// what kind of cloud it is.
public struct CloudLayer: Sendable, Equatable {
    public enum Kind: Int, Sendable {
        case stratus = 0, cumulus = 1, cumulonimbus = 2, cirrus = 3
    }
    public var baseMetres: Double
    public var topMetres: Double
    public var coverage: Double
    public var kind: Kind

    public init(baseMetres: Double, topMetres: Double, coverage: Double, kind: Kind) {
        self.baseMetres = baseMetres
        self.topMetres = topMetres
        self.coverage = coverage
        self.kind = kind
    }

    /// Extinction at full density (1/m), shape noise scale and detail scale (m).
    var style: SIMD4<Float> {
        switch kind {
        case .stratus: SIMD4(0.035, 7_000, 900, 0)
        case .cumulus: SIMD4(0.05, 2_600, 480, 0)
        case .cumulonimbus: SIMD4(0.06, 9_000, 700, 0)
        case .cirrus: SIMD4(0.003, 9_000, 1_500, 0)
        }
    }
}

/// Matches CloudUniforms in 40_Clouds.metal.
struct CloudUniforms {
    var layer0Shape = SIMD4<Float>.zero, layer0Style = SIMD4<Float>.zero
    var layer1Shape = SIMD4<Float>.zero, layer1Style = SIMD4<Float>.zero
    var layer2Shape = SIMD4<Float>.zero, layer2Style = SIMD4<Float>.zero
    var camera = SIMD4<Float>.zero
    var wind = SIMD4<Float>.zero
    var size = SIMD4<Float>.zero
    var bounds = SIMD4<Float>.zero

    mutating func setLayers(_ layers: [CloudLayer]) {
        let used = Array(layers.sorted { $0.baseMetres < $1.baseMetres }.prefix(3))
        func pack(_ l: CloudLayer) -> (SIMD4<Float>, SIMD4<Float>) {
            (SIMD4(Float(l.baseMetres), Float(l.topMetres), Float(min(max(l.coverage, 0), 1)), Float(l.kind.rawValue)), l.style)
        }
        if used.count > 0 { (layer0Shape, layer0Style) = pack(used[0]) }
        if used.count > 1 { (layer1Shape, layer1Style) = pack(used[1]) }
        if used.count > 2 { (layer2Shape, layer2Style) = pack(used[2]) }
        wind.z = Float(used.count)
        bounds.x = Float(used.map(\.baseMetres).min() ?? 0)
        bounds.y = Float(used.map(\.topMetres).max() ?? 0)
    }
}

/// Moving aircraft at one airport, by shape.
public struct TrafficInstances: Sendable, Equatable {
    public var narrow: [SIMD8<Float>]
    public var wide: [SIMD8<Float>]

    public init(narrow: [SIMD8<Float>], wide: [SIMD8<Float>]) {
        self.narrow = narrow
        self.wide = wide
    }
}

/// Falling rain, drizzle or snow; intensity 0.35 light, 0.65 moderate, 1 heavy.
public struct Precipitation: Sendable, Equatable {
    public enum Kind: Sendable { case rain, drizzle, snow }
    public var kind: Kind
    public var intensity: Double

    public init(kind: Kind, intensity: Double) {
        self.kind = kind
        self.intensity = intensity
    }

    /// Fall speed (m/s), drop radius (m) and drops in the box around the camera at this intensity.
    var fallSpeed: Double { kind == .snow ? 1.1 : (kind == .drizzle ? 3.5 : 6 + 3 * intensity) }
    var radius: Double { kind == .snow ? 0.004 : (kind == .drizzle ? 0.0004 : 0.0009 + 0.0006 * intensity) }
    var dropCount: Int { Int((kind == .snow ? 12_000.0 : (kind == .drizzle ? 8_000 : 8_000)) * min(max(intensity, 0.1), 1)) }
}

/// Matches PrecipUniforms in 45_Precipitation.metal.
struct PrecipUniforms {
    var box = SIMD4<Float>.zero
    var offset = SIMD4<Float>.zero
    var streak = SIMD4<Float>.zero
    var look = SIMD4<Float>.zero
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
    /// Draw the procedural ground plane under the terrain (off in tests to expose holes).
    public var fallbackGround = true
    /// Leave the sky black (test only: any black pixel below the horizon is a hole).
    public var blackSkyForTest = false

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
