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
    /// A high-wing four-seater (C172): for its lights.
    static let lightAircraft = Spec(length: 8.3, diameter: 1.2, span: 11.0, sweep: 0, rootChord: 1.6, tipChord: 1.1,
                                    wingZ: 0.65, wingX: 1.5, finHeight: 1.5, finChord: 1.2, tailSpan: 3.4,
                                    engineDiameter: 0.9, engineLength: 1.0, engineY: [0], noseToGear: 1.4, gearHeight: 0.9)
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
        var narrow: [SIMD8<Float>] = [], wide: [SIMD8<Float>] = []
        for slot in site.airlinerStands where slot.occupied {
            if let ref = slot.ref, ref == excluding { continue }
            let placement = site.placement(.stand(slot.ref ?? "")) ?? StartPlacement(position: site.onSurface(slot.position), heading: 0, altitude: nil)
            let inst = SIMD8<Float>(Float(slot.position.x), Float(slot.position.y), Float(placement.position.z), Float(slot.heading),
                                    Float(slot.seed / 0.75), 0, 0, 0)
            if slot.parkedWidebody { wide.append(inst) } else { narrow.append(inst) }
        }
        return (narrow, wide)
    }
}

/// The exterior lights of a moving airliner, in the airport frame.
enum AircraftLights {
    /// Body point (x forward, y left, z up) to the airport frame, as the instance shader does it.
    static func place(_ p: SIMD3<Double>, at position: SIMD3<Double>, heading: Double, pitch: Double, roll: Double) -> SIMD3<Double> {
        let cr = cos(roll), sr = sin(roll)
        var q = SIMD3(p.x, p.y * cr - p.z * sr, p.z * cr + p.y * sr)
        let cp = cos(pitch), sp = sin(pitch)
        q = SIMD3(q.x * cp - q.z * sp, q.y, q.z * cp + q.x * sp)
        let fwd = SIMD2(sin(heading), cos(heading)), left = SIMD2(-cos(heading), sin(heading))
        let h = fwd * q.x + left * q.y
        return position + SIMD3(h.x, h.y, q.z)
    }

    /// Lights for one instance: navigation (red left, green right, white tail) and the red
    /// beacons when the engines run, white wingtip strobes, landing lights in the wing roots and
    /// the nose gear's taxi light, by the instance's flags.
    static func lights(_ i: SIMD8<Float>, spec s: ParkedAircraftMesh.Spec) -> [GPULight] {
        let flags = Int(i[7])
        guard flags != 0 else { return [] }
        let pos = SIMD3(Double(i[0]), Double(i[1]), Double(i[2]))
        let heading = Double(i[3]), pitch = Double(i[5]), roll = Double(i[6]), seed = Float(i[4])
        func at(_ p: SIMD3<Double>) -> SIMD4<Float> { SIMD4(SIMD3<Float>(place(p, at: pos, heading: heading, pitch: pitch, roll: roll)), 0) }
        func dir(_ d: SIMD3<Double>) -> SIMD3<Float> {
            SIMD3<Float>(simd_normalize(place(d, at: .zero, heading: heading, pitch: pitch, roll: roll)))
        }
        let bodyZ = s.gearHeight + s.diameter / 2
        let tipX = s.noseToGear - s.wingX - (s.span / 2 - s.diameter / 2) * tan(s.sweep * .pi / 180) - s.tipChord * 0.5
        let wingZ = bodyZ + s.wingZ + s.span * 0.03
        let tailX = s.noseToGear - s.length + 0.3
        var out: [GPULight] = []
        func light(_ p: SIMD3<Double>, cd: Float, colour: SIMD3<Float>, flash: (Float, Float)? = nil,
                   beam: (SIMD3<Double>, Double)? = nil) {
            var position = at(p)
            position.w = cd
            let d = beam.map { SIMD4(dir($0.0), Float(cos($0.1 * .pi / 180))) } ?? .zero
            let params = flash.map { SIMD4<Float>($0.0, seed + $0.1, $0.0 >= 1.5 ? $0.0 / 25 : 0.12, 0) } ?? .zero
            out.append(GPULight(position: position, colour: SIMD4(colour, flash == nil ? 0 : 1), direction: d, params: params))
        }
        if flags & 8 != 0 {
            light(SIMD3(tipX, s.span / 2, wingZ), cd: 60, colour: SIMD3(1, 0.06, 0.03))
            light(SIMD3(tipX, -s.span / 2, wingZ), cd: 60, colour: SIMD3(0.1, 1, 0.35))
            light(SIMD3(tailX, 0, bodyZ + s.diameter * 0.35), cd: 30, colour: SIMD3(1, 1, 0.95))
            let mid = s.noseToGear - s.length * 0.45
            light(SIMD3(mid, 0, bodyZ + s.diameter / 2 + 0.15), cd: 300, colour: SIMD3(1, 0.08, 0.03), flash: (1.0, 0))
            light(SIMD3(mid + 3, 0, bodyZ - s.diameter / 2 - 0.15), cd: 300, colour: SIMD3(1, 0.08, 0.03), flash: (1.0, 0.5))
        }
        if flags & 4 != 0 {
            light(SIMD3(tipX - 0.3, s.span / 2, wingZ), cd: 4_000, colour: SIMD3(1, 1, 1), flash: (1.6, 0))
            light(SIMD3(tipX - 0.3, -s.span / 2, wingZ), cd: 4_000, colour: SIMD3(1, 1, 1), flash: (1.6, 0))
        }
        if flags & 1 != 0 {
            let rootX = s.noseToGear - s.wingX + 0.2
            for side in [-1.0, 1.0] {
                light(SIMD3(rootX, side * (s.diameter / 2 + 1.0), bodyZ + s.wingZ), cd: 150_000, colour: SIMD3(1, 0.97, 0.9),
                      beam: (SIMD3(1, 0, -0.05), 9))
            }
        }
        if flags & 2 != 0 {
            light(SIMD3(s.noseToGear - 0.3, 0, s.gearHeight + 0.6), cd: 30_000, colour: SIMD3(1, 0.95, 0.85),
                  beam: (SIMD3(1, 0, -0.15), 14))
        }
        return out
    }
}
