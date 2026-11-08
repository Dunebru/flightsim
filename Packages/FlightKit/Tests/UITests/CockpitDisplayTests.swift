import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UI

/// The A320 screens drawn for a climbing right turn, written to artifacts/renders/display-*.png
/// for review and read by the flight-deck render.
struct CockpitDisplayTests {
    @Test func drawPages() throws {
        var d = DisplayInputs()
        d.ias = 212; d.altitude = 4_350; d.verticalSpeed = 1_800; d.heading = 87; d.track = 91
        d.pitch = 8; d.roll = 15; d.groundSpeed = 238; d.trueAirspeed = 226; d.n1 = 84.2; d.flaps = 0.25
        d.gearDown = 0; d.onGround = false; d.windFrom = 260; d.windKnots = 12; d.selectedAltitude = 7_000
        d.fma = ["SPEED", "CLB", "HDG", "", "AP1"]
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../artifacts/renders").standardized
        for page in ["pfd", "nd", "ewd", "sd", "mcdu", "dcdu", "isis", "clock", "atc", "batt"] {
            let px = CockpitDisplays.draw(page, d)
            let n = CockpitDisplays.size
            #expect(px.count == n * n * 4)
            // Something drawn: well over a few percent of pixels not black.
            let lit = stride(from: 0, to: px.count, by: 4).filter { px[$0] > 40 || px[$0 + 1] > 40 || px[$0 + 2] > 40 }.count
            #expect(lit > n * n / 300, "\(page) is nearly empty")
            let data = Data(px)
            let provider = CGDataProvider(data: data as CFData)!
            let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("display-\(page).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}
