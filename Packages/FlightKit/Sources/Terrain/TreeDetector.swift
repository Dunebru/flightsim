import Foundation

/// A tree found in aerial imagery, in its tile's frame (metres from the tile centre, on the
/// terrain surface).
public struct TreeInstance: Sendable, Equatable {
    public var position: SIMD3<Float>
    /// Canopy radius and total height, metres.
    public var radius: Float
    public var height: Float
    /// 0-1, for colour and shape variation; above 0.75 a palm.
    public var seed: Float
}

/// Finds tree canopies in fine aerial imagery (NAIP, about 0.5 to 1 m per pixel): dark green
/// pixels, gathered in 4 m cells, become one tree per cell where enough of the cell is canopy.
/// Lawns and fields are lighter green and are left alone.
public enum TreeDetector {
    /// Canopy: green clearly above red and blue, and dark.
    @inline(__always)
    static func isCanopy(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let gi = Int(g), ri = Int(r), bi = Int(b)
        let lum = (ri * 2 + gi * 5 + bi) / 8
        return gi - max(ri, bi) >= 6 && lum < 115 && lum > 18
    }

    /// - Parameters:
    ///   - pixels: RGBA8 imagery of the tile, `size` x `size`, north-west first.
    ///   - metresPerPixel: ground size of a pixel.
    ///   - surface: the tile-frame ground point under fractional tile coordinates (0-1, 0-1).
    public static func detect(pixels: [UInt8], size: Int, metresPerPixel: Double, maxTrees: Int = 2_500,
                              surface: (Double, Double) -> SIMD3<Float>) -> [TreeInstance] {
        let cell = max(2, Int((4.0 / metresPerPixel).rounded()))
        var out: [TreeInstance] = []
        var cy = 0
        while cy + cell <= size {
            var cx = 0
            while cx + cell <= size {
                var count = 0, sx = 0, sy = 0
                for y in cy..<(cy + cell) {
                    for x in cx..<(cx + cell) {
                        let i = (y * size + x) * 4
                        if isCanopy(pixels[i], pixels[i + 1], pixels[i + 2]) { count += 1; sx += x; sy += y }
                    }
                }
                if Double(count) / Double(cell * cell) > 0.45 {
                    let px = Double(sx) / Double(count) + 0.5, py = Double(sy) / Double(count) + 0.5
                    let area = Double(count) * metresPerPixel * metresPerPixel
                    let radius = Float(min(max((area / .pi).squareRoot() * 1.15, 1.4), 5))
                    var h = UInt32(truncatingIfNeeded: cx &* 73_856_093 ^ cy &* 19_349_663)
                    h = (h ^ (h >> 13)) &* 1_274_126_177
                    let seed = Float(h % 10_000) / 10_000
                    let height = seed > 0.75 ? radius * 2.6 + 5 : radius * 2.1 + 1.5
                    out.append(TreeInstance(position: surface(px / Double(size), py / Double(size)),
                                            radius: radius, height: height, seed: seed))
                    if out.count >= maxTrees { return out }
                }
                cx += cell
            }
            cy += cell
        }
        return out
    }
}
