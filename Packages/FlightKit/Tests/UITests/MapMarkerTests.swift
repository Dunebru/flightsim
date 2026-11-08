import SwiftUI
import Testing
@testable import UI

/// The map's aircraft marker points along the track. The swept wings and tailplane put the
/// silhouette's centre of mass behind its middle, so it sits opposite the nose.
@MainActor
struct MapMarkerTests {
    func whitePixels(track: Double) throws -> [(Int, Int)] {
        let r = ImageRenderer(content: AircraftMarker(track: track).frame(width: 40, height: 40).background(Color.black))
        r.scale = 1
        let image = try #require(r.cgImage)
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out: [(Int, Int)] = []
        for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4] > 200 { out.append((x, y)) } }
        return out
    }

    @Test func noseFollowsTheTrack() throws {
        // Image rows run top to bottom in the bitmap.
        let north = try whitePixels(track: 0), east = try whitePixels(track: 90), northwest = try whitePixels(track: 315)
        func mean(_ p: [(Int, Int)]) -> (Double, Double) {
            (Double(p.map(\.0).reduce(0, +)) / Double(p.count), Double(p.map(\.1).reduce(0, +)) / Double(p.count))
        }
        // The wings sit behind the middle, so the mass centre is behind it: below for north, left for east.
        let n = mean(north), e = mean(east), nw = mean(northwest)
        print("MARKER mass centre north \(n), east \(e), northwest \(nw)")
        #expect(n.1 > 20, "pointing north, the mass is low")
        #expect(e.0 < 20, "pointing east, the mass is to the left")
        #expect(nw.0 > 20 && nw.1 > 20, "pointing northwest, the mass is low and right")
    }
}
