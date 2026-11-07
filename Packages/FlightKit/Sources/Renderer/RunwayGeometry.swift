import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// A runway with markings in the pattern of a precision instrument runway (FAA AC 150/5340-1).
/// Dimensions below are as recalled from the advisory circular and will be checked against it
/// in M5, when airports are generated from data.
struct RunwaySpec {
    var length: Float          // metres
    var width: Float           // metres
    /// Designators at the low-heading end (west for 08) and the reciprocal end.
    var lowDesignator: String
    var highDesignator: String
    /// True heading of the low end, degrees.
    var heading: Float

    static let kphx08_26 = RunwaySpec(length: 3_502, width: 45.7, lowDesignator: "8", highDesignator: "26", heading: 90)
}

/// Marking atlas: 16 cells of 64 x 128 px. Cell 0 is solid paint; then digits 0-9, then L, C, R.
enum MarkingAtlas {
    static let cellWidth = 64, cellHeight = 128, cells = 16
    static let glyphs: [Character] = Array("0123456789LCR")

    static func cell(for c: Character) -> Int {
        (glyphs.firstIndex(of: c) ?? -1) + 1
    }

    /// UV rectangle (u0, v0, u1, v1) of a cell, inset half a texel to avoid bleeding.
    static func uvRect(cell: Int) -> SIMD4<Float> {
        let w = Float(cellWidth * cells)
        let u0 = (Float(cell * cellWidth) + 0.5) / w
        let u1 = (Float((cell + 1) * cellWidth) - 0.5) / w
        return SIMD4(u0, 0.5 / Float(cellHeight), u1, 1 - 0.5 / Float(cellHeight))
    }

    /// Renders the atlas: white paint on black, glyph outlines stretched to fill each cell the way
    /// runway numerals are painted tall and narrow.
    static func makeTexture(device: any MTLDevice, queue: any MTLCommandQueue) -> (any MTLTexture)? {
        let width = cellWidth * cells, height = cellHeight
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: cellWidth, height: cellHeight))
            let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, 200, nil)
            for (i, ch) in glyphs.enumerated() {
                var unichars = Array(String(ch).utf16)
                var glyph = CGGlyph()
                guard CTFontGetGlyphsForCharacters(font, &unichars, &glyph, 1),
                      let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                let box = path.boundingBoxOfPath
                let cellRect = CGRect(x: (i + 1) * cellWidth, y: 0, width: cellWidth, height: cellHeight)
                    .insetBy(dx: 6, dy: 6)
                var t = CGAffineTransform(translationX: cellRect.minX, y: cellRect.minY)
                    .scaledBy(x: cellRect.width / box.width, y: cellRect.height / box.height)
                    .translatedBy(x: -box.minX, y: -box.minY)
                if let fitted = path.copy(using: &t) {
                    ctx.addPath(fitted)
                    ctx.fillPath()
                }
            }
            return true
        }
        guard drawn else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let staging = device.makeTexture(descriptor: desc) else { return nil }
        // CoreGraphics rows run bottom-up here (origin bottom-left); flip so v = 0 is the glyph top.
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            let src = (height - 1 - y) * width
            flipped.replaceSubrange(y * width..<(y + 1) * width, with: pixels[src..<src + width])
        }
        staging.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: flipped, bytesPerRow: width)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: staging)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
        }
        return staging
    }
}

/// Builds runway surface and marking quads in runway-local coordinates: x along the runway
/// (low end at -length/2), y across (left of the low-end landing direction is +y), z up.
enum RunwayGeometry {
    static func surface(_ spec: RunwaySpec) -> [MeshVertex] {
        quad(minX: -spec.length / 2, maxX: spec.length / 2, minY: -spec.width / 2, maxY: spec.width / 2,
             z: 0.02, uv: SIMD4(-spec.length / 2, -spec.width / 2, spec.length / 2, spec.width / 2))
    }

    static func markings(_ spec: RunwaySpec) -> [MeshVertex] {
        var v: [MeshVertex] = []
        let half = spec.length / 2
        let solid = MarkingAtlas.uvRect(cell: 0)
        let z: Float = 0.04

        // Side stripes: 0.9 m wide along both edges.
        for side: Float in [-1, 1] {
            let outer = side * (spec.width / 2 - 0.3)
            let inner = side * (spec.width / 2 - 1.2)
            v += quad(minX: -half + 2, maxX: half - 2, minY: min(outer, inner), maxY: max(outer, inner), z: z, uv: solid)
        }

        for end in [Float(-1), Float(1)] {
            // `along(d)` is the runway-local x of a point d metres in from this end.
            func along(_ d: Float) -> Float { end < 0 ? -half + d : half - d }
            func span(_ d0: Float, _ d1: Float) -> (Float, Float) {
                let a = along(d0), b = along(d1)
                return (min(a, b), max(a, b))
            }

            // Threshold bars: 12 stripes, 45.7 m long, 1.75 m wide, starting 6.1 m in.
            let (tx0, tx1) = span(6.1, 6.1 + 45.7)
            let stripeW: Float = 1.75, gap: Float = 1.75, centreGap: Float = 3.5
            for i in 0..<6 {
                let offset = centreGap / 2 + Float(i) * (stripeW + gap)
                for side: Float in [-1, 1] {
                    let y0 = side * offset, y1 = side * (offset + stripeW)
                    v += quad(minX: tx0, maxX: tx1, minY: min(y0, y1), maxY: max(y0, y1), z: z, uv: solid)
                }
            }

            // Designator: numerals 18.3 m tall, 6.1 m wide, 6.1 m beyond the threshold bars,
            // reading upright for an aircraft landing over this end.
            let designator = end < 0 ? spec.lowDesignator : spec.highDesignator
            let chars = Array(designator)
            let digitW: Float = 6.1, digitGap: Float = 3.0, digitL: Float = 18.3
            let total = Float(chars.count) * digitW + Float(chars.count - 1) * digitGap
            let nStart: Float = 6.1 + 45.7 + 6.1
            for (k, ch) in chars.enumerated() {
                let uv = MarkingAtlas.uvRect(cell: MarkingAtlas.cell(for: ch))
                // Left-to-right as seen by the landing pilot: for the low end (flying +x),
                // the pilot's left is +y.
                let leftEdge = total / 2 - Float(k) * (digitW + digitGap)
                let yA = end < 0 ? leftEdge : -leftEdge
                let yB = end < 0 ? leftEdge - digitW : -leftEdge + digitW
                let xNear = along(nStart), xFar = along(nStart + digitL)
                v += orientedQuad(near: xNear, far: xFar, left: yA, right: yB, z: z, uv: uv)
            }

            // Touchdown zone bars: 22.9 m x 1.83 m, 1.52 m apart, inner edge 10.97 m from the
            // centreline, at 500 / 1500 / 2000 / 2500 / 3000 ft. Aiming point at 1020 ft.
            let tdz: [(Float, Int)] = [(152.4, 3), (457.2, 2), (609.6, 2), (762.0, 1), (914.4, 1)]
            for (distance, bars) in tdz {
                let (x0, x1) = span(distance, distance + 22.9)
                for b in 0..<bars {
                    let o = 10.97 + Float(b) * (1.83 + 1.52)
                    for side: Float in [-1, 1] {
                        let y0 = side * o, y1 = side * (o + 1.83)
                        v += quad(minX: x0, maxX: x1, minY: min(y0, y1), maxY: max(y0, y1), z: z, uv: solid)
                    }
                }
            }
            let (ax0, ax1) = span(310.9, 310.9 + 45.7)
            for side: Float in [-1, 1] {
                let y0 = side * 10.97, y1 = side * (10.97 + 9.1)
                v += quad(minX: ax0, maxX: ax1, minY: min(y0, y1), maxY: max(y0, y1), z: z, uv: solid)
            }
        }

        // Centreline: 36.6 m stripes, 24.4 m gaps, 0.9 m wide, from 12.2 m past the numerals.
        let start = -half + 6.1 + 45.7 + 6.1 + 18.3 + 12.2
        var x = start
        while x + 36.6 < half - (6.1 + 45.7 + 6.1 + 18.3 + 12.2) {
            v += quad(minX: x, maxX: x + 36.6, minY: -0.45, maxY: 0.45, z: z, uv: solid)
            x += 36.6 + 24.4
        }
        return v
    }

    static func quad(minX: Float, maxX: Float, minY: Float, maxY: Float, z: Float, uv: SIMD4<Float>) -> [MeshVertex] {
        let n = SIMD4<Float>(0, 0, 1, 0)
        let a = MeshVertex(position: SIMD4(minX, minY, z, 1), normal: n, uv: SIMD2(uv.x, uv.y))
        let b = MeshVertex(position: SIMD4(maxX, minY, z, 1), normal: n, uv: SIMD2(uv.z, uv.y))
        let c = MeshVertex(position: SIMD4(maxX, maxY, z, 1), normal: n, uv: SIMD2(uv.z, uv.w))
        let d = MeshVertex(position: SIMD4(minX, maxY, z, 1), normal: n, uv: SIMD2(uv.x, uv.w))
        return [a, b, c, a, c, d]
    }

    /// A glyph quad: v runs from the glyph top (far from the threshold) to its foot (near);
    /// u runs from the reader's left to right.
    static func orientedQuad(near: Float, far: Float, left: Float, right: Float, z: Float, uv: SIMD4<Float>) -> [MeshVertex] {
        let n = SIMD4<Float>(0, 0, 1, 0)
        let nl = MeshVertex(position: SIMD4(near, left, z, 1), normal: n, uv: SIMD2(uv.x, uv.w))
        let nr = MeshVertex(position: SIMD4(near, right, z, 1), normal: n, uv: SIMD2(uv.z, uv.w))
        let fr = MeshVertex(position: SIMD4(far, right, z, 1), normal: n, uv: SIMD2(uv.z, uv.y))
        let fl = MeshVertex(position: SIMD4(far, left, z, 1), normal: n, uv: SIMD2(uv.x, uv.y))
        return [nl, nr, fr, nl, fr, fl]
    }
}
