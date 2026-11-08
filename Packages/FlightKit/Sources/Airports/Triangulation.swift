import Foundation
import simd

/// Planar polygon helpers for airport surfaces (ENU metres).
public enum Polygon2D {
    public static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        var a = 0.0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// The ring without a repeated closing point.
    static func open(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard ring.count > 1, let f = ring.first, let l = ring.last, simd_distance(f, l) < 1e-6 else { return ring }
        return Array(ring.dropLast())
    }

    static func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    static func inTriangle(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        let d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p)
        return d1 >= 0 && d2 >= 0 && d3 >= 0
    }

    /// Ear-clipping triangulation of a polygon with holes (holes joined to the outer ring by
    /// bridges). Returns triangles counter-clockwise seen from above.
    public static func triangulate(outer: [SIMD2<Double>], holes: [[SIMD2<Double>]] = []) -> [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] {
        var ring = open(outer)
        guard ring.count >= 3 else { return [] }
        if signedArea(ring) < 0 { ring.reverse() }
        // Bridge each hole (clockwise) into the ring, rightmost hole first.
        let hs = holes.map { h -> [SIMD2<Double>] in
            var o = open(h)
            if signedArea(o) > 0 { o.reverse() }
            return o
        }.filter { $0.count >= 3 }.sorted { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        for hole in hs {
            let hi = hole.indices.max { hole[$0].x < hole[$1].x }!
            let m = hole[hi]
            // The visible ring vertex: nearest to the right whose bridge crosses no ring edge.
            var best: Int?
            var bestD = Double.infinity
            for (i, p) in ring.enumerated() {
                let d = simd_distance_squared(p, m)
                guard d < bestD else { continue }
                var clear = true
                for j in 0..<ring.count {
                    let a = ring[j], b = ring[(j + 1) % ring.count]
                    if j == i || (j + 1) % ring.count == i { continue }
                    if segmentsCross(m, p, a, b) { clear = false; break }
                }
                if clear { best = i; bestD = d }
            }
            guard let b = best else { continue }
            let holeLoop = Array(hole[hi...] + hole[..<hi]) + [hole[hi]]
            ring = Array(ring[...b]) + holeLoop + Array(ring[b...])
        }

        var idx = Array(ring.indices)
        var out: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] = []
        var guardCount = 0
        while idx.count > 3 && guardCount < 100_000 {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let ia = idx[(k + idx.count - 1) % idx.count], ib = idx[k], ic = idx[(k + 1) % idx.count]
                let a = ring[ia], b = ring[ib], c = ring[ic]
                if cross(a, b, c) <= 1e-12 { continue }   // reflex or degenerate
                var empty = true
                for j in idx where j != ia && j != ib && j != ic {
                    let p = ring[j]
                    if p == a || p == b || p == c { continue }
                    if inTriangle(p, a, b, c) { empty = false; break }
                }
                if empty {
                    out.append((a, b, c))
                    idx.remove(at: k)
                    clipped = true
                    break
                }
            }
            if !clipped {
                // Numerically stuck (collinear runs): drop the flattest vertex and continue.
                let k = idx.indices.min { abs(cross(ring[idx[($0 + idx.count - 1) % idx.count]], ring[idx[$0]], ring[idx[($0 + 1) % idx.count]]))
                    < abs(cross(ring[idx[($1 + idx.count - 1) % idx.count]], ring[idx[$1]], ring[idx[($1 + 1) % idx.count]])) }!
                idx.remove(at: k)
            }
        }
        if idx.count == 3, cross(ring[idx[0]], ring[idx[1]], ring[idx[2]]) > 0 { out.append((ring[idx[0]], ring[idx[1]], ring[idx[2]])) }
        return out
    }

    static func segmentsCross(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
        let d1 = cross(a, b, p), d2 = cross(a, b, q), d3 = cross(p, q, a), d4 = cross(p, q, b)
        return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))
    }

    /// Splits triangles until no edge is longer than `maxEdge`, so a large flat polygon can
    /// follow a gently curved surface.
    public static func subdivide(_ tris: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)], maxEdge: Double)
        -> [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] {
        var out: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] = []
        var stack = tris
        while let (a, b, c) = stack.popLast() {
            let ab = simd_distance(a, b), bc = simd_distance(b, c), ca = simd_distance(c, a)
            let longest = max(ab, bc, ca)
            if longest <= maxEdge || out.count > 400_000 { out.append((a, b, c)); continue }
            if longest == ab {
                let m = (a + b) / 2; stack.append((a, m, c)); stack.append((m, b, c))
            } else if longest == bc {
                let m = (b + c) / 2; stack.append((a, b, m)); stack.append((a, m, c))
            } else {
                let m = (c + a) / 2; stack.append((a, b, m)); stack.append((m, b, c))
            }
        }
        return out
    }
}
