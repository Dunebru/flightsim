import Foundation

/// A polygon in the scene's ENU frame where the ground is held to a smooth surface: an airport,
/// so terrain (and buildings baked into a surface model) never pokes through the pavement. The
/// surface interpolates height samples (ENU x, y, height above the scene origin) by inverse
/// distance weighting; outside the polygon the hold fades out over `margin` metres.
public struct FlattenPolygon: Sendable, Equatable {
    public var ring: [SIMD2<Double>]
    public var samples: [SIMD3<Double>] { didSet { grid = Self.makeGrid(samples, minimum, maximum, margin) } }
    public var margin: Double
    private let minimum: SIMD2<Double>, maximum: SIMD2<Double>
    /// The surface precomputed every `gridSpacing` metres over the polygon plus its margin;
    /// lookups are bilinear (interpolating 200 samples per vertex was the airport's main cost).
    private var grid: Grid
    static let gridSpacing = 20.0

    struct Grid: Sendable, Equatable {
        var origin: SIMD2<Double> = .zero
        var columns = 0, rows = 0
        var values: [Float] = []
    }

    public init(ring: [SIMD2<Double>], samples: [SIMD3<Double>], margin: Double = 150) {
        self.ring = ring
        self.margin = margin
        let lo = ring.reduce(SIMD2(repeating: .infinity)) { pointwiseMin($0, $1) }
        let hi = ring.reduce(SIMD2(repeating: -.infinity)) { pointwiseMax($0, $1) }
        minimum = lo
        maximum = hi
        self.samples = samples
        grid = Self.makeGrid(samples, lo, hi, margin)
    }

    static func makeGrid(_ samples: [SIMD3<Double>], _ lo: SIMD2<Double>, _ hi: SIMD2<Double>, _ margin: Double) -> Grid {
        guard lo.x.isFinite, hi.x.isFinite, !samples.isEmpty else { return Grid() }
        let o = lo - SIMD2(repeating: margin + gridSpacing)
        let cols = Int(((hi.x - lo.x) + 2 * (margin + gridSpacing)) / gridSpacing) + 2
        let rows = Int(((hi.y - lo.y) + 2 * (margin + gridSpacing)) / gridSpacing) + 2
        guard cols * rows < 4_000_000 else { return Grid() }
        var values = [Float](repeating: 0, count: cols * rows)
        for j in 0..<rows {
            for i in 0..<cols {
                values[j * cols + i] = Float(idw(samples, o + SIMD2(Double(i), Double(j)) * gridSpacing))
            }
        }
        return Grid(origin: o, columns: cols, rows: rows, values: values)
    }

    static func idw(_ samples: [SIMD3<Double>], _ p: SIMD2<Double>) -> Double {
        var num = 0.0, den = 0.0
        for s in samples {
            let d2 = (s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y)
            if d2 < 1e-6 { return s.z }
            let w = 1 / d2
            num += w * s.z
            den += w
        }
        return den > 0 ? num / den : 0
    }

    func contains(_ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    func distanceToEdge(_ p: SIMD2<Double>) -> Double {
        var best = Double.infinity
        for i in 0..<(ring.count - 1) {
            let a = ring[i], ab = ring[i + 1] - a
            let t = max(0, min(1, ((p - a) * ab).sum() / max((ab * ab).sum(), 1e-12)))
            let d = p - (a + ab * t)
            best = min(best, (d * d).sum())
        }
        return best.squareRoot()
    }

    public func weight(_ p: SIMD2<Double>) -> Double {
        if p.x < minimum.x - margin || p.y < minimum.y - margin || p.x > maximum.x + margin || p.y > maximum.y + margin { return 0 }
        if contains(p) { return 1 }
        let d = distanceToEdge(p)
        guard d < margin else { return 0 }
        let t = 1 - d / margin
        return t * t * (3 - 2 * t)
    }

    /// Height above the scene origin: inverse-distance weighting (power 2) of the samples,
    /// read bilinearly from the precomputed grid where it covers the point.
    public func height(at p: SIMD2<Double>) -> Double {
        let g = grid
        let f = (p - g.origin) / Self.gridSpacing
        let i = Int(floor(f.x)), j = Int(floor(f.y))
        guard i >= 0, j >= 0, i < g.columns - 1, j < g.rows - 1 else { return Self.idw(samples, p) }
        let tx = Float(f.x - Double(i)), ty = Float(f.y - Double(j))
        let a = g.values[j * g.columns + i], b = g.values[j * g.columns + i + 1]
        let c = g.values[(j + 1) * g.columns + i], d = g.values[(j + 1) * g.columns + i + 1]
        return Double((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
    }
}

/// Anything that holds the ground to a surface: a runway rectangle or an airport polygon.
public enum GroundOverride: Sendable, Equatable {
    case area(FlattenArea)
    case polygon(FlattenPolygon)

    public func weight(_ p: SIMD2<Double>) -> Double {
        switch self {
        case .area(let a): a.weight(p)
        case .polygon(let a): a.weight(p)
        }
    }

    public func height(at p: SIMD2<Double>) -> Double {
        switch self {
        case .area(let a): a.height(at: p)
        case .polygon(let a): a.height(at: p)
        }
    }

    /// The same override with its surface moved by `dz` metres.
    public func raised(by dz: Double) -> GroundOverride {
        switch self {
        case .area(var a): a.height += dz; return .area(a)
        case .polygon(var a): a.samples = a.samples.map { SIMD3($0.x, $0.y, $0.z + dz) }; return .polygon(a)
        }
    }
}
