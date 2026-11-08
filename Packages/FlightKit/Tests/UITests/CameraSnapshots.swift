import Aircraft
import CoreGraphics
import Foundation
import ImageIO
import Metal
import Renderer
import Testing
import UniformTypeIdentifiers
@testable import UI

/// Renders each camera view of the C172 on the KPHX runway to artifacts/renders/camera-*.png,
/// to check eye and wing camera placement by eye. Skipped when the model is not fetched.
struct CameraSnapshots {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
    static let c172 = root.appendingPathComponent("Data/Bundle/Aircraft/c172p")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: c172.appendingPathComponent("c172-common.ac").path)))
    func cameraViews() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let text = try String(contentsOf: Self.c172.appendingPathComponent("c172-common.ac"), encoding: .isoLatin1)
        let r = try SceneRenderer(device: device, aircraftModel: try AC3DParser.parse(text), aircraftTextures: Self.c172)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        var scene = SceneDescription.phoenixTest(date: ISO8601DateFormatter().date(from: "2026-06-21T17:00:00Z")!)
        for (name, mode) in [("cockpit", CameraRig.Mode.cockpit), ("wing", .wing), ("tower", .tower), ("orbit", .orbit)] {
            var rig = CameraRig()
            rig.mode = mode
            for _ in 0..<3 {
                scene.cameraPose = rig.pose(aircraftPosition: scene.aircraftPosition, heading: scene.aircraftHeading,
                                            pitch: 0.04, roll: 0, dt: 0.5)
            }
            scene.showAircraft = rig.drawsAircraft
            r.resetHistory()
            let img = try r.renderImage(scene, width: 1000, height: 460)
            try Self.save(img, 1000, 460, "camera-\(name)")
        }
    }

    static func save(_ bgra: [UInt8], _ w: Int, _ h: Int, _ name: String) throws {
        let dir = root.appendingPathComponent("artifacts/renders")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(i, i + 2) }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
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
