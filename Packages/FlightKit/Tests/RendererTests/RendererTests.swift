import Aircraft
import CoreGraphics
import Foundation
import ImageIO
import Metal
import SimCore
import Testing
import UniformTypeIdentifiers
import simd
@testable import Renderer

/// Renderer tests run headless on the Mac's GPU through the same code path the app uses.
@Suite(.serialized)
struct RendererTests {
    static let device = MTLCreateSystemDefaultDevice()
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("../../../..").standardized
    static let c172Dir = repoRoot.appendingPathComponent("Data/Bundle/Aircraft/c172p")

    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    // MARK: Layout

    @Test func gpuStructLayoutsMatchShaders() {
        #expect(MemoryLayout<FrameUniforms>.stride == 5 * 64 + 9 * 16)
        #expect(MemoryLayout<DrawUniforms>.stride == 2 * 64 + 3 * 16)
        #expect(MemoryLayout<MeshVertex>.stride == 48)
        #expect(MemoryLayout<TerrainVertex>.stride == 20)
    }

    @Test func reverseZProjectionMapsNearToOneAndFarToZero() {
        let p = MatrixMath.perspectiveReverseZ(fovY: 1, aspect: 1, near: 0.1)
        let near = p * SIMD4<Float>(0, 0, -0.1, 1)
        let far = p * SIMD4<Float>(0, 0, -1e7, 1)
        #expect(abs(near.z / near.w - 1) < 1e-6)
        #expect(far.z / far.w < 1e-7)
    }

    // MARK: Sky

    struct Pixel { var r, g, b: Double }

    static func pixel(_ img: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> Pixel {
        let i = (y * w + x) * 4
        return Pixel(r: Double(img[i + 2]), g: Double(img[i + 1]), b: Double(img[i]))
    }

    /// A camera on the runway looking at the horizon in a chosen direction.
    static func skyScene(date: Date, yawDegrees: Double) -> SceneDescription {
        var s = SceneDescription.phoenixTest(date: date)
        s.showAircraft = false
        s.camera = OrbitCamera(target: SIMD3(0, 0, 2), yaw: yawDegrees * .pi / 180, pitch: -12 * .pi / 180,
                               distance: 0.01, fovY: 70 * .pi / 180)
        return s
    }

    @Test func noonSkyIsBlueAboveAndBrighterNearHorizon() throws {
        let device = try #require(Self.device)
        let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        let w = 160, h = 120
        let img = try r.renderImage(Self.skyScene(date: Self.date("2026-06-21T19:30:00Z"), yawDegrees: 0), width: w, height: h)
        try Self.savePNG(img, w, h, name: "test-sky-noon")
        let top = Self.pixel(img, w, w / 2, 2)
        #expect(top.b > top.r + 20, "zenith-ward sky should be clearly blue: \(top)")
        // Lower sky toward the horizon is paler (more white) than higher sky.
        let low = Self.pixel(img, w, w / 2, h / 2 - 8)
        #expect((low.r + low.g) > (top.r + top.g), "horizon should be paler: top \(top), low \(low)")
    }

    @Test func sunsetHorizonIsWarmTowardTheSun() throws {
        let device = try #require(Self.device)
        // Find a time when the sun is about 2 degrees up at KPHX on 2026-06-21 (evening, UTC next day).
        var sunsetDate = Self.date("2026-06-22T02:00:00Z")
        while SolarEphemeris.sunPosition(at: sunsetDate, latitude: 33.4342, longitude: -112.0116).elevation > 2 {
            sunsetDate.addTimeInterval(60)
        }
        let sun = SolarEphemeris.sunPosition(at: sunsetDate, latitude: 33.4342, longitude: -112.0116)
        let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        let w = 160, h = 120
        var scene = Self.skyScene(date: sunsetDate, yawDegrees: sun.azimuth)
        scene.camera.pitch = -5 * .pi / 180
        let img = try r.renderImage(scene, width: w, height: h)
        try Self.savePNG(img, w, h, name: "test-sky-sunset")
        // Just above the horizon, beside the sun, the sky is warm (red over blue).
        let nearHorizon = Self.pixel(img, w, w / 2 + 30, h / 2 - 2)
        #expect(nearHorizon.r > nearHorizon.b, "sunset horizon should be warm: \(nearHorizon)")
    }

    @Test func nightIsFarDarkerThanDay() throws {
        let device = try #require(Self.device)
        let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        let w = 96, h = 64
        let day = try r.renderImage(Self.skyScene(date: Self.date("2026-06-21T19:30:00Z"), yawDegrees: 0), width: w, height: h)
        r.resetHistory()
        let night = try r.renderImage(Self.skyScene(date: Self.date("2026-06-22T08:00:00Z"), yawDegrees: 0), width: w, height: h)
        try Self.savePNG(night, w, h, name: "test-sky-night")
        // Colour channels only: the alpha byte is always 255 and would put a floor under the mean.
        func mean(_ img: [UInt8]) -> Double {
            var sum = 0
            for i in stride(from: 0, to: img.count, by: 4) { sum += Int(img[i]) + Int(img[i + 1]) + Int(img[i + 2]) }
            return Double(sum) / Double(img.count / 4 * 3)
        }
        #expect(mean(night) < mean(day) * 0.35, "night \(mean(night)) vs day \(mean(day))")
    }

    // MARK: Floating origin

    /// A comb of 2 cm slats with 2 cm gaps: any positional error shows up as changed pixels.
    static func comb() throws -> AC3DModel {
        var text = "AC3Db\nMATERIAL \"white\" rgb 0.9 0.9 0.9 amb 1 1 1 emis 0 0 0 spec 0.1 0.1 0.1 shi 8 trans 0\nOBJECT world\nkids 1\nOBJECT poly\nname \"comb\"\n"
        let slats = 40
        text += "numvert \(slats * 4)\n"
        for i in 0..<slats {
            let x0 = Double(i) * 0.04 - 0.8, x1 = x0 + 0.02
            text += "\(x0) 0 0\n\(x1) 0 0\n\(x1) 1.5 0\n\(x0) 1.5 0\n"
        }
        text += "numsurf \(slats)\n"
        for i in 0..<slats {
            text += "SURF 0x20\nmat 0\nrefs 4\n\(i * 4) 0 0\n\(i * 4 + 1) 0 0\n\(i * 4 + 2) 0 0\n\(i * 4 + 3) 0 0\n"
        }
        text += "kids 0\n"
        return try AC3DParser.parse(text)
    }

    static func combScene(offset: SIMD3<Double>) -> SceneDescription {
        var s = SceneDescription.phoenixTest(date: date("2026-06-21T19:30:00Z"))
        s.showGround = false
        s.showRunway = false
        s.aircraftPosition = SIMD3(0, 0, 0)
        s.aircraftHeading = .pi / 2
        s.camera = OrbitCamera(target: SIMD3(0, 0, 0.75), yaw: 0, pitch: 0, distance: 2.2, fovY: 60 * .pi / 180)
        s.worldOffset = offset
        return s
    }

    static func fractionDifferent(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 3) -> Double {
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if abs(Int(a[i]) - Int(b[i])) > tolerance || abs(Int(a[i + 1]) - Int(b[i + 1])) > tolerance
                || abs(Int(a[i + 2]) - Int(b[i + 2])) > tolerance { n += 1 }
        }
        return Double(n) / Double(a.count / 4)
    }

    @Test func floatingOriginHoldsFiveThousandKilometresOut() throws {
        let device = try #require(Self.device)
        let r = try SceneRenderer(device: device, aircraftModel: try Self.comb(), aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        let w = 256, h = 192
        let base = try r.renderImage(Self.combScene(offset: .zero), width: w, height: h)
        try Self.savePNG(base, w, h, name: "test-comb-origin")
        for km in [50.0, 5_000.0] {
            r.resetHistory()
            let far = try r.renderImage(Self.combScene(offset: SIMD3(km * 1000, -km * 700, 0)), width: w, height: h)
            let diff = Self.fractionDifferent(base, far)
            #expect(diff < 0.001, "\(km) km from origin: \(diff * 100)% of pixels changed")
        }
    }

    /// Proves the test above can fail: without the floating origin, 5,000 km out, the comb's
    /// 2 cm slats collapse onto a ~0.5 m float grid.
    @Test func withoutFloatingOriginTheCombBreaks() throws {
        let device = try #require(Self.device)
        let r = try SceneRenderer(device: device, aircraftModel: try Self.comb(), aircraftTextures: nil)
        var settings = RenderSettings(upscaler: .off, renderScale: 1)
        settings.disableFloatingOrigin = true
        r.settings = settings
        let w = 256, h = 192
        let base = try r.renderImage(Self.combScene(offset: .zero), width: w, height: h)
        r.resetHistory()
        let far = try r.renderImage(Self.combScene(offset: SIMD3(5_000_000, -3_500_000, 0)), width: w, height: h)
        try Self.savePNG(far, w, h, name: "test-comb-no-floating-origin")
        #expect(Self.fractionDifferent(base, far) > 0.02)
    }

    // MARK: Full scene snapshot (when the C172 asset has been fetched)

    @Test(.enabled(if: FileManager.default.fileExists(atPath: c172Dir.appendingPathComponent("c172-common.ac").path)))
    func phoenixSceneSnapshot() throws {
        let device = try #require(Self.device)
        let text = try String(contentsOf: Self.c172Dir.appendingPathComponent("c172-common.ac"), encoding: .isoLatin1)
        let r = try SceneRenderer(device: device, aircraftModel: try AC3DParser.parse(text), aircraftTextures: Self.c172Dir)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        // Times chosen by sun elevation at KPHX on 2026-06-21 (local evening is the next UTC day).
        for (name, elevation, afternoon) in [("morning", 20.0, false), ("noon", 79.0, false), ("sunset", 4.0, true),
                                             ("dusk", -3.0, true), ("night", -25.0, true)] {
            r.resetHistory()
            let date = Self.time(whenSunAt: elevation, afternoon: afternoon)
            let img = try r.renderImage(SceneDescription.phoenixTest(date: date), width: 1200, height: 540)
            try Self.savePNG(img, 1200, 540, name: "scene-\(name)")
        }
    }

    /// First minute on 2026-06-21 (KPHX) when the sun crosses `elevation`, rising or setting.
    static func time(whenSunAt elevation: Double, afternoon: Bool) -> Date {
        var d = date(afternoon ? "2026-06-21T19:30:00Z" : "2026-06-21T11:00:00Z")
        for _ in 0..<(18 * 60) {
            let e = SolarEphemeris.sunPosition(at: d, latitude: 33.4342, longitude: -112.0116).elevation
            if afternoon ? e <= elevation : e >= elevation { return d }
            d.addTimeInterval(60)
        }
        return d
    }

    // MARK: PNG output (artifacts/renders, gitignored)

    static func savePNG(_ bgra: [UInt8], _ w: Int, _ h: Int, name: String) throws {
        let dir = repoRoot.appendingPathComponent("artifacts/renders")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(name).png") as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

/// MetalFX temporal upscaling of a static scene must converge toward the native-resolution
/// image, and the jitter we hand MetalFX must have the right sign: the flipped sign has to land
/// measurably further from the reference. Skipped where MetalFX is unavailable.
@Suite(.serialized)
struct TemporalUpscalingTests {
    static var available: Bool {
        guard let d = MTLCreateSystemDefaultDevice() else { return false }
        return SceneRenderer.supports(.temporal, device: d)
    }

    static func meanError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            for c in 0..<3 { sum += Double(abs(Int(a[i + c]) - Int(b[i + c]))) }
        }
        return sum / Double(a.count / 4 * 3)
    }

    @Test(.enabled(if: available))
    func temporalConvergesAndJitterSignIsRight() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let w = 320, h = 240
        let scene = RendererTests.combScene(offset: .zero)

        let native = try SceneRenderer(device: device, aircraftModel: try RendererTests.comb(), aircraftTextures: nil)
        native.settings = RenderSettings(upscaler: .off, renderScale: 1)
        let reference = try native.renderImage(scene, width: w, height: h)

        func upscaled(flip: Bool) throws -> [UInt8] {
            let r = try SceneRenderer(device: device, aircraftModel: try RendererTests.comb(), aircraftTextures: nil)
            var s = RenderSettings(upscaler: .temporal, renderScale: 0.5)
            s.flipJitterSignForTest = flip
            r.settings = s
            return try r.renderImage(scene, width: w, height: h, warmupFrames: 48)
        }
        let correct = try upscaled(flip: false)
        let flipped = try upscaled(flip: true)

        let bilinear = try SceneRenderer(device: device, aircraftModel: try RendererTests.comb(), aircraftTextures: nil)
        bilinear.settings = RenderSettings(upscaler: .off, renderScale: 0.5)
        let plain = try bilinear.renderImage(scene, width: w, height: h)

        let eCorrect = Self.meanError(correct, reference)
        let eFlipped = Self.meanError(flipped, reference)
        let ePlain = Self.meanError(plain, reference)
        print(String(format: "temporal error: correct %.2f  flipped %.2f  bilinear %.2f", eCorrect, eFlipped, ePlain))
        try RendererTests.savePNG(correct, w, h, name: "test-temporal-upscaled")
        try RendererTests.savePNG(plain, w, h, name: "test-bilinear-upscaled")
        #expect(eCorrect < ePlain, "temporal upscaling should beat a plain bilinear upscale")
        #expect(eCorrect < eFlipped * 0.9, "jitter sign: correct \(eCorrect) vs flipped \(eFlipped)")
    }
}

/// Top-down views of both thresholds, for checking marking layout by eye (artifacts/renders).
@Test func runwayThresholdSnapshots() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
    r.settings = RenderSettings(upscaler: .off, renderScale: 1)
    for (name, x, yaw) in [("rwy08", -1_751.0 + 60, 90.0), ("rwy26", 1_751.0 - 60, 270.0)] {
        var s = SceneDescription.phoenixTest(date: RendererTests.date("2026-06-21T19:30:00Z"))
        s.showAircraft = false
        // Looking down the landing direction from above the approach end.
        s.camera = OrbitCamera(target: SIMD3(x, 0, 0), yaw: yaw * .pi / 180, pitch: 70 * .pi / 180,
                               distance: 120, fovY: 55 * .pi / 180)
        r.resetHistory()
        let img = try r.renderImage(s, width: 800, height: 600)
        try RendererTests.savePNG(img, 800, 600, name: "test-\(name)")
    }
}

/// Attitude conventions: a nose-up pitch raises the nose, a right bank lowers the right wing.
@Test func attitudeRotationsFollowAviationConventions() {
    let noseUp = MatrixMath.rotationY(Float(-10 * Double.pi / 180)) * SIMD4<Float>(1, 0, 0, 0)
    #expect(noseUp.z > 0.17)
    let rightWing = MatrixMath.rotationX(Float(20 * Double.pi / 180)) * SIMD4<Float>(0, -1, 0, 0)   // -y is right
    #expect(rightWing.z < -0.3)
}
