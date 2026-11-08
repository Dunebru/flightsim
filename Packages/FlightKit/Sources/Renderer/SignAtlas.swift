import Airports
import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Sign faces drawn into one texture, and the boxes that carry them.
enum SignAtlas {
    static let width = 2048
    static let rowHeight = 96

    struct Built {
        let texture: any MTLTexture
        let vertices: [MeshVertex]
    }

    /// Lays out every unique face, draws the atlas, and builds the sign boxes (airport frame).
    static func build(_ signs: [SignPlacement], device: any MTLDevice) -> Built? {
        let faces = Array(Set(signs.flatMap { [$0.front] + ($0.back.map { [$0] } ?? []) }))
            .sorted { ($0.style.rawValue, $0.text) < ($1.style.rawValue, $1.text) }
        guard !faces.isEmpty else { return nil }
        let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, 74, nil)
        // Rects in pixels; row 0 starts after an 8 px solid dark block used for box sides.
        var rects: [SignPlacement.Face: CGRect] = [:]
        var x = 16, y = 0
        func lineWidth(_ s: String) -> Int {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.init(kCTFontAttributeName as String): font]))
            return Int(ceil(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        for f in faces {
            let w = lineWidth(f.text) + 48
            if x + w > width { x = 0; y += rowHeight }
            rects[f] = CGRect(x: x, y: y, width: w, height: rowHeight)
            x += w + 4
        }
        let height = y + rowHeight
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // CoreGraphics draws with y up; flip so row 0 is at the top of the buffer.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 12, height: rowHeight))
            for (f, r) in rects {
                let (bg, fg): (CGColor, CGColor) = switch f.style {
                case .mandatory: (CGColor(red: 0.78, green: 0.06, blue: 0.06, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                case .location: (CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1), CGColor(red: 1, green: 0.82, blue: 0.1, alpha: 1))
                case .distance: (CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                }
                ctx.setFillColor(bg)
                ctx.fill(r)
                if f.style == .location {
                    ctx.setStrokeColor(fg)
                    ctx.setLineWidth(5)
                    ctx.stroke(r.insetBy(dx: 10, dy: 10))
                }
                // Text, upright in the flipped context.
                ctx.saveGState()
                ctx.translateBy(x: r.minX, y: r.maxY)
                ctx.scaleBy(x: 1, y: -1)
                let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
                                                            .init(kCTForegroundColorAttributeName as String): fg]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: f.text, attributes: attrs))
                ctx.textPosition = CGPoint(x: 24, y: 22)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            return true
        }
        guard ok else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4)

        // Boxes: the face panel on legs, 0.3 m deep, bottom 0.45 m above the ground.
        var v: [MeshVertex] = []
        let dark = SIMD2<Float>(4 / Float(width), 4 / Float(height))
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, n: SIMD3<Double>,
                  uv: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)) {
            let nn = SIMD4<Float>(SIMD3<Float>(n), 0)
            func mv(_ p: SIMD3<Double>, _ t: SIMD2<Float>) -> MeshVertex { MeshVertex(position: SIMD4(SIMD3<Float>(p), 1), normal: nn, uv: t) }
            v += [mv(a, uv.0), mv(b, uv.1), mv(c, uv.2), mv(a, uv.0), mv(c, uv.2), mv(d, uv.3)]
        }
        for s in signs {
            guard let fr = rects[s.front] else { continue }
            let h = s.facing * .pi / 180
            let n = SIMD3(sin(h), cos(h), 0)              // the front face looks this way
            let right = SIMD3(-n.y, n.x, 0)               // reading direction for a viewer facing it
            let w = s.height * Double(fr.width) / Double(rowHeight)
            let z0 = s.position.z + 0.45, z1 = z0 + s.height
            let depth = 0.3
            let c = SIMD3(s.position.x, s.position.y, 0)
            func p(_ along: Double, _ out: Double, _ z: Double) -> SIMD3<Double> { c + right * along + n * out + SIMD3(0, 0, z) }
            func uvRect(_ r: CGRect) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
                let u0 = Float(r.minX) / Float(width), u1 = Float(r.maxX) / Float(width)
                let v0 = Float(r.minY) / Float(height), v1 = Float(r.maxY) / Float(height)
                return (SIMD2(u0, v1), SIMD2(u1, v1), SIMD2(u1, v0), SIMD2(u0, v0))   // bottom-left first
            }
            let solid = (dark, dark, dark, dark)
            // Front: left to right as the viewer sees it.
            quad(p(-w / 2, depth / 2, z0), p(w / 2, depth / 2, z0), p(w / 2, depth / 2, z1), p(-w / 2, depth / 2, z1), n: n, uv: uvRect(fr))
            // Back: the second face, or plain.
            let backUV = s.back.flatMap { rects[$0] }.map(uvRect) ?? solid
            quad(p(w / 2, -depth / 2, z0), p(-w / 2, -depth / 2, z0), p(-w / 2, -depth / 2, z1), p(w / 2, -depth / 2, z1), n: -n, uv: backUV)
            // Ends and top.
            quad(p(w / 2, depth / 2, z0), p(w / 2, -depth / 2, z0), p(w / 2, -depth / 2, z1), p(w / 2, depth / 2, z1), n: right, uv: solid)
            quad(p(-w / 2, -depth / 2, z0), p(-w / 2, depth / 2, z0), p(-w / 2, depth / 2, z1), p(-w / 2, -depth / 2, z1), n: -right, uv: solid)
            quad(p(-w / 2, depth / 2, z1), p(w / 2, depth / 2, z1), p(w / 2, -depth / 2, z1), p(-w / 2, -depth / 2, z1), n: SIMD3(0, 0, 1), uv: solid)
            // Two legs.
            for x in [-w / 2 + 0.15, w / 2 - 0.15] {
                quad(p(x - 0.04, 0, s.position.z), p(x + 0.04, 0, s.position.z), p(x + 0.04, 0, z0), p(x - 0.04, 0, z0), n: n, uv: solid)
                quad(p(x + 0.04, 0, s.position.z), p(x - 0.04, 0, s.position.z), p(x - 0.04, 0, z0), p(x + 0.04, 0, z0), n: -n, uv: solid)
            }
        }
        return Built(texture: texture, vertices: v)
    }
}
