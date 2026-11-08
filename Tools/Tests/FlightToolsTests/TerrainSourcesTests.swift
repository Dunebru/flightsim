import CoreGraphics
import Foundation
import ImageIO
import Terrain
import Testing
import UniformTypeIdentifiers
@testable import FlightToolsCore

struct TerrainSourcesTests {
    @Test func terrariumEncoding() {
        #expect(TerrariumSource.height(r: 128, g: 0, b: 0) == 0)
        #expect(TerrariumSource.height(r: 129, g: 44, b: 128) == 300.5)
        #expect(TerrariumSource.height(r: 127, g: 255, b: 0) == -1)
    }

    /// A real tile (zoom 8 over central Arizona) decodes to plausible heights: the Salt River
    /// valley near 300 m, the Mogollon Rim country above 2,000 m, nothing absurd.
    @Test func decodesARealTile() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../Data/raw/terrarium/8/48/102.png").standardized
        let data = try Data(contentsOf: fixture)
        let h = try #require(TerrariumSource.decode(data))
        let lo = h.min()!, hi = h.max()!
        #expect(lo > 50 && lo < 400, "lowest \(lo) m")
        #expect(hi > 2_000 && hi < 3_900, "highest \(hi) m")
    }

    /// Encodes a terrarium PNG of the ramp h = 0.25 * gx + 0.125 * gy over global pixel
    /// coordinates (gx, gy) at the tile's zoom.
    static func rampTile(_ k: TileKey) -> Data {
        var px = [UInt8](repeating: 255, count: 256 * 256 * 4)
        for y in 0..<256 {
            for x in 0..<256 {
                let h = 0.25 * Double(k.x * 256 + x) + 0.125 * Double(k.y * 256 + y)
                let v = h + 32_768
                let r = Int(v / 256), g = Int(v) % 256, b = Int(((v - floor(v)) * 256).rounded())
                let i = (y * 256 + x) * 4
                px[i] = UInt8(r); px[i + 1] = UInt8(g); px[i + 2] = UInt8(b)
            }
        }
        let data = NSMutableData()
        let img = CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Heights are sampled continuously across source tiles: a ramp comes back exact, and two
    /// neighbouring target tiles agree on their shared edge.
    @Test func samplingIsSeamless() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("terrarium-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        let source = TerrariumSource(cache: cache) { k in Self.rampTile(k) }
        let a = TileKey(z: 9, x: 100, y: 200), b = TileKey(z: 9, x: 101, y: 200)
        let ha = try await source.heights(for: a), hb = try await source.heights(for: b)
        // Source zoom 10: sample i of tile a sits at global pixel (x * 512 + i * 8 - 0.5).
        for (j, i) in [(0, 0), (10, 20), (64, 64), (32, 5)] {
            let gx = Double(a.x * 512 + i * 8) - 0.5, gy = Double(a.y * 512 + j * 8) - 0.5
            let expected = Float(0.25 * gx + 0.125 * gy)
            #expect(abs(ha[j * 65 + i] - expected) < 0.01, "sample (\(i), \(j)): \(ha[j * 65 + i]) vs \(expected)")
        }
        for j in 0..<65 { #expect(ha[j * 65 + 64] == hb[j * 65]) }
        // Prefetch covers every source tile the sampling touched: footprint plus a margin.
        let fetched = Set(try FileManager.default.subpathsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".png") })
        let planned = TerrariumSource.sources(for: a).union(TerrariumSource.sources(for: b))
        #expect(planned.count == 24)   // 6 columns x 4 rows at zoom 10
        #expect(fetched.count <= planned.count)
        for path in fetched {
            let p = path.dropLast(4).split(separator: "/").compactMap { Int($0) }
            #expect(planned.contains(TileKey(z: p[0], x: p[1], y: p[2])), "\(path) fetched but not planned")
        }
    }

    /// Ocean depths come back as sea level: the drawn surface over the sea is the water.
    @Test func oceanDepthsAreClampedToSeaLevel() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("terrarium-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cache) }
        #expect(TerrariumSource.height(r: 100, g: 0, b: 0) < -7_000)
        let deep = TerrariumSource(cache: cache) { _ in Self.flatTile(r: 100) }
        let h = try await deep.heights(for: TileKey(z: 7, x: 20, y: 50))
        #expect(h.allSatisfy { $0 == 0 })
    }

    static func flatTile(r: UInt8) -> Data {
        var px = [UInt8](repeating: 255, count: 256 * 256 * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i + 1] = 0; px[i + 2] = 0 }
        let data = NSMutableData()
        let img = CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1024,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                          provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test func colourTransferMatchesTheTargetStatistics() {
        var src = [UInt8](), dst = [UInt8]()
        for i in 0..<1_000 {
            let t = Double(i % 100) / 100
            src += [UInt8(90 + 40 * t), UInt8(95 + 40 * t), UInt8(100 + 40 * t), 255]   // grey, low contrast
            dst += [UInt8(120 + 90 * t), UInt8(100 + 70 * t), UInt8(80 + 50 * t), 255]  // warm tan
        }
        let from = ColourStats.of([src]), to = ColourStats.of([dst])
        let out = ColourStats.of([from.transfer(src, to: to)])
        for c in 0..<3 {
            #expect(abs(out.mean[c] - to.mean[c]) < 1)
            #expect(abs(out.std[c] - to.std[c]) < 1)
        }
    }
}
