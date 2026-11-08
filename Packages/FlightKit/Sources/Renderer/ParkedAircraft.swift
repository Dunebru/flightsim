import Airports
import Foundation
import simd

/// Generic airliners for parked traffic: parametric shapes (not models of any real type), built
/// once. Body frame: x forward, y left, z up, origin at the nose wheel on the ground, so an
/// aircraft placed at a stand's stop point sits where a real one would.
///
/// uv: x is the part (0 fuselage, 1 wing, 2 fin, 3 engine, 4 tailplane), y metres from the nose.
enum ParkedAircraftMesh {
    struct Spec {
        let length: Double, diameter: Double, span: Double, sweep: Double
        let rootChord: Double, tipChord: Double, wingZ: Double, wingX: Double
        let finHeight: Double, finChord: Double, tailSpan: Double
        let engineDiameter: Double, engineLength: Double, engineY: [Double]
        let noseToGear: Double, gearHeight: Double
    }

    /// About the size of a 150 to 180 seat twin.
    static let narrowbody = Spec(length: 37.6, diameter: 3.95, span: 35.8, sweep: 25, rootChord: 6.1, tipChord: 1.5,
                                 wingZ: -0.9, wingX: 15.5, finHeight: 6.3, finChord: 5.0, tailSpan: 12.5,
                                 engineDiameter: 2.0, engineLength: 4.4, engineY: [5.8], noseToGear: 5.1, gearHeight: 1.75)
    /// About the size of a 300 to 400 seat twin.
    static let widebody = Spec(length: 66.0, diameter: 6.0, span: 62.0, sweep: 31, rootChord: 11.0, tipChord: 2.4,
                               wingZ: -1.4, wingX: 26.0, finHeight: 10.0, finChord: 8.5, tailSpan: 21.0,
                               engineDiameter: 3.3, engineLength: 7.0, engineY: [9.6], noseToGear: 7.5, gearHeight: 2.6)

    static func build(_ s: Spec) -> [MeshVertex] {
        var v: [MeshVertex] = []
        let bodyZ = s.gearHeight + s.diameter / 2           // fuselage axis above the ground
        func add(_ p: SIMD3<Double>, _ n: SIMD3<Double>, part: Float, along: Double) {
            v.append(MeshVertex(position: SIMD4(SIMD3<Float>(p), 1), normal: SIMD4(SIMD3<Float>(simd_normalize(n)), 0),
                                uv: SIMD2(part, Float(along))))
        }
        func quad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, part: Float) {
            let n = simd_cross(b - a, d - a)
            let along = { (p: SIMD3<Double>) in s.noseToGear - p.x }
            for p in [a, b, c, a, c, d] { add(p, simd_length(n) > 0 ? n : SIMD3(0, 0, 1), part: part, along: along(p)) }
        }

        // Fuselage: 14 sides, radius profile with a rounded nose and a tail cone swept up.
        let sides = 14
        let stations = 24
        func ring(_ i: Int) -> (x: Double, r: Double, zc: Double) {
            let t = Double(i) / Double(stations)
            let x = s.noseToGear - t * s.length
            let R = s.diameter / 2
            var r = R, zc = bodyZ
            if t < 0.11 { let u = t / 0.11; r = R * (1 - (1 - u) * (1 - u)) * 0.96 + R * 0.04; zc = bodyZ - (1 - u) * R * 0.25 }
            if t > 0.72 { let u = (t - 0.72) / 0.28; r = R * (1 - u * 0.86); zc = bodyZ + u * R * 0.55 }
            return (x, max(r, 0.05), zc)
        }
        for i in 0..<stations {
            let a = ring(i), b = ring(i + 1)
            for k in 0..<sides {
                let t0 = Double(k) / Double(sides) * 2 * .pi, t1 = Double(k + 1) / Double(sides) * 2 * .pi
                let d0 = SIMD3(0, cos(t0), sin(t0)), d1 = SIMD3(0, cos(t1), sin(t1))
                let p00 = SIMD3(a.x, 0, a.zc) + d0 * a.r, p01 = SIMD3(a.x, 0, a.zc) + d1 * a.r
                let p10 = SIMD3(b.x, 0, b.zc) + d0 * b.r, p11 = SIMD3(b.x, 0, b.zc) + d1 * b.r
                for (p, n) in [(p00, d0), (p10, d0), (p11, d1), (p00, d0), (p11, d1), (p01, d1)] {
                    add(p, n, part: 0, along: s.noseToGear - p.x)
                }
            }
        }

        // Wings and tailplane: swept, tapered slabs.
        func surface(rootX: Double, rootChord: Double, tipChord: Double, halfSpan: Double, sweep: Double,
                     z: Double, thickness: Double, dihedral: Double, part: Float) {
            for side in [-1.0, 1.0] {
                let tipX = rootX - tan(sweep * .pi / 180) * halfSpan
                let r0 = SIMD3(rootX, 0, z), r1 = SIMD3(rootX - rootChord, 0, z)
                let tz = z + tan(dihedral * .pi / 180) * halfSpan
                let t0 = SIMD3(tipX, side * halfSpan, tz), t1 = SIMD3(tipX - tipChord, side * halfSpan, tz)
                let up = SIMD3(0.0, 0.0, thickness / 2), tipUp = SIMD3(0.0, 0.0, thickness / 6)
                if side > 0 {
                    quad(r0 + up, t0 + tipUp, t1 + tipUp, r1 + up, part: part)
                    quad(r1 - up, t1 - tipUp, t0 - tipUp, r0 - up, part: part)
                } else {
                    quad(t0 + tipUp, r0 + up, r1 + up, t1 + tipUp, part: part)
                    quad(t1 - tipUp, r1 - up, r0 - up, t0 - tipUp, part: part)
                }
                quad(r0 - up, t0 - tipUp, t0 + tipUp, r0 + up, part: part)   // leading edge
            }
        }
        surface(rootX: s.noseToGear - s.wingX + s.rootChord / 2, rootChord: s.rootChord, tipChord: s.tipChord,
                halfSpan: s.span / 2, sweep: s.sweep, z: bodyZ + s.wingZ, thickness: s.diameter * 0.16, dihedral: 5, part: 1)
        let tailX = s.noseToGear - s.length * 0.86
        surface(rootX: tailX + s.finChord * 0.35, rootChord: s.finChord * 0.75, tipChord: s.finChord * 0.3,
                halfSpan: s.tailSpan / 2, sweep: s.sweep + 5, z: bodyZ + s.diameter * 0.25, thickness: 0.35, dihedral: 4, part: 4)

        // Fin: a swept slab standing on the tail cone.
        let finBase = bodyZ + s.diameter * 0.35
        let f0 = SIMD3(tailX + s.finChord * 0.45, 0, finBase), f1 = SIMD3(tailX - s.finChord * 0.55, 0, finBase)
        let ftop = finBase + s.finHeight
        let f2 = SIMD3(tailX - s.finChord * 0.55 - s.finHeight * 0.55, 0, ftop)
        let f3 = SIMD3(tailX - s.finChord * 0.05 - s.finHeight * 0.75, 0, ftop)
        let half = SIMD3(0.0, 0.18, 0.0)
        quad(f0 + half, f1 + half, f2 + half, f3 + half, part: 2)
        quad(f1 - half, f0 - half, f3 - half, f2 - half, part: 2)

        // Engines: open cylinders under the wings.
        for y in s.engineY {
            for side in [-1.0, 1.0] {
                let cx = s.noseToGear - s.wingX + s.rootChord * 0.9, cy = side * y
                let cz = bodyZ + s.wingZ - s.engineDiameter * 0.55
                for k in 0..<12 {
                    let a0 = Double(k) / 12 * 2 * .pi, a1 = Double(k + 1) / 12 * 2 * .pi
                    let d0 = SIMD3(0, cos(a0), sin(a0)), d1 = SIMD3(0, cos(a1), sin(a1))
                    let r = s.engineDiameter / 2
                    let front = SIMD3(cx, cy, cz), back = SIMD3(cx - s.engineLength, cy, cz)
                    for (p, n) in [(front + d0 * r, d0), (back + d0 * r * 0.8, d0), (back + d1 * r * 0.8, d1),
                                   (front + d0 * r, d0), (back + d1 * r * 0.8, d1), (front + d1 * r, d1)] {
                        add(p, n, part: 3, along: 0)
                    }
                }
            }
        }
        return v
    }
}

/// Which stands get an aircraft: about three in four terminal-adjacent stands with a lead-in
/// line, widebodies at the larger ones, never the stand the flight starts at.
enum ParkedTraffic {
    /// Instances in the airport frame: (x, y, z, heading radians) and (seed, 0, 0, 0).
    static func placements(_ site: AirportSite, excluding: String?) -> (narrow: [SIMD8<Float>], wide: [SIMD8<Float>]) {
        let stops = site.layout.stands.filter { $0.line.count >= 2 }.map { (s: $0, p: site.xy($0.position)) }
        var narrow: [SIMD8<Float>] = [], wide: [SIMD8<Float>] = []
        for (stand, p) in stops {
            if let ref = stand.ref, ref == excluding { continue }
            // Spacing to the nearest other stand says what fits: under 30 m is general aviation.
            let spacing = stops.filter { $0.p != p }.map { simd_distance($0.p, p) }.min() ?? 100
            guard spacing >= 30 else { continue }
            // A fixed hash of the stand's position (hashValue changes every launch).
            let ix = Int64((p.x * 10).rounded()), iy = Int64((p.y * 10).rounded())
            var h = UInt64(bitPattern: (ix &* 73_856_093) ^ (iy &* 19_349_663))
            h = (h ^ (h >> 31)) &* 0x9E37_79B9_7F4A_7C15
            h ^= h >> 29
            let r = Double(h % 10_000) / 10_000
            guard r < 0.75 else { continue }                 // about three in four occupied
            let placement = site.placement(.stand(stand.ref ?? "")) ?? StartPlacement(position: site.onSurface(p), heading: 0, altitude: nil)
            let line = stand.line.map(site.xy)
            let a = line[line.count - 2], b = line[line.count - 1]
            let heading = atan2(b.x - a.x, b.y - a.y)
            let isWide = spacing >= 62 && r < 0.4
            let inst = SIMD8<Float>(Float(p.x), Float(p.y), Float(placement.position.z), Float(heading), Float(r / 0.75), 0, 0, 0)
            if isWide { wide.append(inst) } else { narrow.append(inst) }
        }
        return (narrow, wide)
    }
}
