public import Foundation
import simd

/// A triangle list in the airport's ENU frame (metres, relative to the airport origin).
public struct MeshData: Sendable {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []

    public init() {}

    public var triangleCount: Int { positions.count / 3 }

    mutating func add(_ p: SIMD3<Double>, _ n: SIMD3<Double>, _ uv: SIMD2<Double>) {
        positions.append(SIMD3<Float>(p))
        normals.append(SIMD3<Float>(n))
        uvs.append(SIMD2<Float>(uv))
    }

    /// A triangle facing up (fixes the winding so the face is counter-clockwise from above).
    mutating func ground(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                         uv: (SIMD3<Double>) -> SIMD2<Double>) {
        let up = SIMD3<Double>(0, 0, 1)
        let ccw = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0
        for p in ccw ? [a, b, c] : [a, c, b] { add(p, up, uv(p)) }
    }

    mutating func append(_ other: MeshData) {
        positions += other.positions
        normals += other.normals
        uvs += other.uvs
    }
}

/// Runway paint is drawn from an atlas: cell 0 is solid paint, then digits 0-9, L, C, R.
public enum MarkingCells {
    public static let glyphs: [Character] = Array("0123456789LCR")
    public static let count = 16

    public static func cell(for c: Character) -> Int { (glyphs.firstIndex(of: c) ?? -1) + 1 }

    /// UV rectangle of a cell (u0, v0, u1, v1), inset half a texel (64 x 128 px cells).
    public static func uvRect(cell: Int) -> SIMD4<Double> {
        let w = Double(64 * count)
        return SIMD4((Double(cell * 64) + 0.5) / w, 0.5 / 128, (Double((cell + 1) * 64) - 0.5) / w, 1 - 0.5 / 128)
    }
}

/// Everything drawn at an airport, grouped by how it is shaded.
public struct AirportGeometry: Sendable {
    public struct RunwayMesh: Sendable {
        public var name: String
        /// uv: metres from the runway centre (along, across).
        public var surface: MeshData
        /// uv: marking atlas.
        public var markings: MeshData
        public var length: Double
        public var width: Double
        public var asphalt: Bool
    }
    public var runways: [RunwayMesh] = []
    /// Taxiways, concrete and asphalt (uv: ENU metres, for slab joints).
    public var concrete = MeshData()
    public var asphalt = MeshData()
    /// Aprons (floodlit at night).
    public var apronConcrete = MeshData()
    public var apronAsphalt = MeshData()
    /// Passenger boarding bridges and windsocks (uv: metres along, metres up).
    public var bridges = MeshData()
    public var windsocks = MeshData()
    /// Yellow paint: taxiway centrelines, holding positions, lead-in lines (solid).
    public var yellowPaint = MeshData()
    /// Walls (uv: metres along the wall, metres up) and roofs (uv: ENU metres), per kind.
    public var buildings: [Building.Kind: MeshData] = [:]
    /// Control tower cab glazing.
    public var glazing = MeshData()

    /// Heights above the airport surface for each layer, so coplanar surfaces never fight.
    public enum Layer {
        public static let apron = 0.0
        public static let taxiway = 0.0
        public static let runway = 0.02
        public static let paint = 0.03
    }

    public static func build(_ site: AirportSite) -> AirportGeometry {
        var g = AirportGeometry()
        let frames = site.layout.runways.map(site.runwayFrame)
        for (r, f) in zip(site.layout.runways, frames) { g.runways.append(runway(r, f, site)) }
        for a in site.layout.aprons { apron(a, site, into: &g) }
        for t in site.layout.taxiways { taxiway(t, site, into: &g) }
        for t in site.layout.taxiways { centreline(t, site, runways: frames, into: &g.yellowPaint) }
        for h in site.layout.holdPositions { hold(h, site, into: &g.yellowPaint) }
        for s in site.layout.stands where s.line.count >= 2 { leadIn(s, site, into: &g.yellowPaint) }
        for b in site.layout.buildings { building(b, site, into: &g) }
        for line in jetBridges(site) { bridge(line, site, into: &g.bridges) }
        for w in site.layout.windsocks ?? [] { windsock(site.xy(w), site, into: &g.windsocks) }
        for c in AirportLights.mastPositions(site) { mast(c, site, into: &g.bridges) }
        return g
    }

    // MARK: Runways

    static func runway(_ r: Runway, _ f: RunwayFrame, _ site: AirportSite) -> RunwayMesh {
        var surface = MeshData()
        let L = f.length, W = r.width
        let steps = max(2, Int(L / 50))
        func at(_ s: Double, _ t: Double, lift: Double) -> SIMD3<Double> {
            let p = f.point(s, t)
            return SIMD3(p.x, p.y, site.z(p) + lift)
        }
        for i in 0..<steps {
            let s0 = L * Double(i) / Double(steps), s1 = L * Double(i + 1) / Double(steps)
            for (t0, t1) in [(-W / 2, 0.0), (0.0, W / 2)] {
                let a = at(s0, t0, lift: Layer.runway), b = at(s1, t0, lift: Layer.runway)
                let c = at(s1, t1, lift: Layer.runway), d = at(s0, t1, lift: Layer.runway)
                let uv: (SIMD3<Double>) -> SIMD2<Double> = { p in
                    let l = f.local(SIMD2(p.x, p.y)); return SIMD2(l.x - L / 2, l.y)
                }
                surface.ground(a, b, c, uv: uv)
                surface.ground(a, c, d, uv: uv)
            }
        }
        return RunwayMesh(name: r.name, surface: surface, markings: runwayMarkings(r, f, site),
                          length: L, width: W, asphalt: r.surface == .asphalt)
    }

    /// FAA precision instrument runway markings (AC 150/5340-1, dimensions as recalled; see
    /// PROGRESS.md): side stripes, threshold stripes, designation with side letter, touchdown
    /// zone and aiming point markings, centreline, and displaced-threshold arrows and bar.
    static func runwayMarkings(_ r: Runway, _ f: RunwayFrame, _ site: AirportSite) -> MeshData {
        var m = MeshData()
        let L = f.length, W = r.width
        let solid = MarkingCells.uvRect(cell: 0)
        /// A rectangle given in a runway end's own axes: `d` metres in from that end along the
        /// landing direction, `y` metres to the landing pilot's left.
        func rect(end: Int, d0: Double, d1: Double, y0: Double, y1: Double, uv: SIMD4<Double> = solid, flipU: Bool = false) {
            func pt(_ d: Double, _ y: Double) -> SIMD3<Double> {
                let s = end == 0 ? d : L - d, t = end == 0 ? y : -y
                let p = f.point(s, t)
                return SIMD3(p.x, p.y, site.z(p) + Layer.paint)
            }
            // Corners: near-left, near-right, far-right, far-left (as the landing pilot sees it).
            let nl = pt(d0, y1), nr = pt(d0, y0), fr = pt(d1, y0), fl = pt(d1, y1)
            let u0 = flipU ? uv.z : uv.x, u1 = flipU ? uv.x : uv.z
            // The glyph's top (v = v0) is farthest from the pilot.
            let up = SIMD3<Double>(0, 0, 1)
            m.add(nl, up, SIMD2(u0, uv.w)); m.add(nr, up, SIMD2(u1, uv.w)); m.add(fr, up, SIMD2(u1, uv.y))
            m.add(nl, up, SIMD2(u0, uv.w)); m.add(fr, up, SIMD2(u1, uv.y)); m.add(fl, up, SIMD2(u0, uv.y))
        }

        /// A solid triangle given in a runway end's axes (d in from the end, y to the left).
        func tri(end: Int, _ pts: [SIMD2<Double>]) {
            let p = pts.map { q -> SIMD3<Double> in
                let s = end == 0 ? q.x : L - q.x, t = end == 0 ? q.y : -q.y
                let w = f.point(s, t)
                return SIMD3(w.x, w.y, site.z(w) + Layer.paint)
            }
            m.ground(p[0], p[1], p[2]) { _ in SIMD2(solid.x, solid.y) }
        }

        // Side stripes along the full length, 0.9 m wide at the edges.
        for y in [W / 2 - 1.2, -W / 2 + 0.3] { rect(end: 0, d0: 0, d1: L, y0: y, y1: y + 0.9) }

        for (k, end) in r.ends.enumerated() {
            let disp = end.displacedThreshold
            // Displaced threshold: arrows on the centreline and a 3 m bar across the runway.
            if disp > 1 {
                var d = 6.0
                while d + 36.6 < disp - 15 {
                    rect(end: k, d0: d, d1: d + 36.6, y0: -0.45, y1: 0.45)
                    d += 36.6 + 24.4
                }
                // Arrowheads (13.7 m long, 4.6 m wide) pointing at the threshold, 1.5 m short of
                // the bar.
                tri(end: k, [SIMD2(disp - 1.5, 0), SIMD2(disp - 15.2, -2.3), SIMD2(disp - 15.2, 2.3)])
                rect(end: k, d0: disp - 3, d1: disp, y0: -W / 2 + 1, y1: W / 2 - 1)
            }
            let t0 = disp + 6.1
            // Threshold stripes: 45.7 m long, 1.75 m wide and apart; 12 on a 45 m runway, 16 on 60 m.
            let pairs = W >= 59 ? 8 : (W >= 44 ? 6 : 4)
            for i in 0..<pairs {
                let o = 1.75 + Double(i) * 3.5
                for side in [-1.0, 1.0] {
                    rect(end: k, d0: t0, d1: t0 + 45.7, y0: min(side * o, side * (o + 1.75)), y1: max(side * o, side * (o + 1.75)))
                }
            }
            // Designation: the side letter nearer the threshold, the number beyond it.
            var cursor = t0 + 45.7 + 6.1
            let glyphH = 18.3, glyphW = 6.1, gap = 3.0
            let rows: [String] = end.side.isEmpty ? [end.number] : [end.side, end.number]
            for row in rows {
                let chars = Array(row)
                let total = Double(chars.count) * glyphW + Double(chars.count - 1) * gap
                for (i, ch) in chars.enumerated() {
                    // Left to right as the pilot reads it: the first glyph is on the pilot's left.
                    let leftY = total / 2 - Double(i) * (glyphW + gap)
                    rect(end: k, d0: cursor, d1: cursor + glyphH, y0: leftY - glyphW, y1: leftY,
                         uv: MarkingCells.uvRect(cell: MarkingCells.cell(for: ch)), flipU: true)
                }
                cursor += glyphH + 6.1
            }
            // Touchdown zone (500, 1500-3000 ft) and aiming point (1,020 ft), from the threshold.
            if end.markings == "PIR" {
                for (dist, bars) in [(152.4, 3), (457.2, 2), (609.6, 2), (762.0, 1), (914.4, 1)] {
                    for b in 0..<bars {
                        let o = 10.97 + Double(b) * (1.83 + 1.52)
                        for side in [-1.0, 1.0] {
                            rect(end: k, d0: disp + dist, d1: disp + dist + 22.9,
                                 y0: min(side * o, side * (o + 1.83)), y1: max(side * o, side * (o + 1.83)))
                        }
                    }
                }
            }
            for side in [-1.0, 1.0] {
                let o = 10.97
                rect(end: k, d0: disp + 310.9, d1: disp + 310.9 + 45.7,
                     y0: min(side * o, side * (o + 9.1)), y1: max(side * o, side * (o + 9.1)))
            }
        }

        // Centreline: 36.6 m stripes, 24.4 m gaps, 0.9 m wide, between the designations.
        let lowClear = r.ends[0].displacedThreshold + 6.1 + 45.7 + 6.1 + (r.ends[0].side.isEmpty ? 18.3 : 42.7) + 12.2
        let highClear = r.ends[1].displacedThreshold + 6.1 + 45.7 + 6.1 + (r.ends[1].side.isEmpty ? 18.3 : 42.7) + 12.2
        var d = lowClear
        while d + 36.6 <= L - highClear {
            rect(end: 0, d0: d, d1: d + 36.6, y0: -0.45, y1: 0.45)
            d += 36.6 + 24.4
        }
        return m
    }

    // MARK: Taxiways and aprons

    static func apron(_ a: Area, _ site: AirportSite, into g: inout AirportGeometry) {
        let outer = a.outer.map(site.xy), holes = a.holes.map { $0.map(site.xy) }
        let tris = Polygon2D.subdivide(Polygon2D.triangulate(outer: outer, holes: holes), maxEdge: 40)
        var mesh = MeshData()
        for (p, q, r) in tris {
            mesh.ground(site.onSurface(p) + SIMD3(0, 0, Layer.apron), site.onSurface(q) + SIMD3(0, 0, Layer.apron),
                        site.onSurface(r) + SIMD3(0, 0, Layer.apron)) { SIMD2($0.x, $0.y) }
        }
        if a.surface == .asphalt { g.apronAsphalt.append(mesh) } else { g.apronConcrete.append(mesh) }
    }

    /// A ribbon of `width` along a polyline with round joins and caps, on the airport surface.
    static func ribbon(_ pts: [SIMD2<Double>], width: Double, lift: Double, site: AirportSite, into m: inout MeshData) {
        let h = width / 2
        func p3(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x, p.y, site.z(p) + lift) }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let d = b - a
            let len = (d * d).sum().squareRoot()
            guard len > 0.01 else { continue }
            let n = SIMD2(-d.y, d.x) / len * h
            // Long segments are split so the ribbon follows the surface.
            let parts = max(1, Int(len / 30))
            for k in 0..<parts {
                let s0 = a + d * (Double(k) / Double(parts)), s1 = a + d * (Double(k + 1) / Double(parts))
                let q0 = p3(s0 + n), q1 = p3(s0 - n), q2 = p3(s1 - n), q3 = p3(s1 + n)
                m.ground(q0, q1, q2) { SIMD2($0.x, $0.y) }
                m.ground(q0, q2, q3) { SIMD2($0.x, $0.y) }
            }
        }
        // Round caps at the ends and round joins where the line turns.
        let segments = width > 2 ? 12 : 6
        for (i, p) in pts.enumerated() {
            if i > 0 && i < pts.count - 1 {
                let d0 = simd_normalize(p - pts[i - 1]), d1 = simd_normalize(pts[i + 1] - p)
                if simd_dot(d0, d1) > 0.9986 { continue }   // straighter than 3 degrees
            }
            let c = p3(p)
            for k in 0..<segments {
                let a0 = Double(k) / Double(segments) * 2 * .pi, a1 = Double(k + 1) / Double(segments) * 2 * .pi
                let e0 = p + SIMD2(cos(a0), sin(a0)) * h, e1 = p + SIMD2(cos(a1), sin(a1)) * h
                m.ground(c, p3(e0), p3(e1)) { SIMD2($0.x, $0.y) }
            }
        }
    }

    static func taxiway(_ t: Taxiway, _ site: AirportSite, into g: inout AirportGeometry) {
        ribbon(t.points.map(site.xy), width: t.width, lift: Layer.taxiway, site: site, into: &g.concrete)
    }

    /// Taxiway centreline (0.15 m yellow), stopping 2 m short of runway edges.
    static func centreline(_ t: Taxiway, _ site: AirportSite, runways: [RunwayFrame], into m: inout MeshData) {
        let pts = t.points.map(site.xy)
        var run: [SIMD2<Double>] = []
        func flush() {
            if run.count >= 2 { ribbon(run, width: 0.15, lift: Layer.paint, site: site, into: &m) }
            run = []
        }
        // Walk each segment in 2 m steps to find where it enters and leaves runways; keep only
        // the original vertices and those transition points.
        func onRunway(_ p: SIMD2<Double>) -> Bool { runways.contains { $0.contains(p, margin: 2) } }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let n = max(1, Int(simd_distance(a, b) / 2))
            var was = onRunway(a)
            if i == 0 && !was { run.append(a) }
            for k in 1...n {
                let p = a + (b - a) * (Double(k) / Double(n))
                let now = onRunway(p)
                if now != was {
                    if now { run.append(p); flush() } else { run.append(p) }
                    was = now
                } else if k == n && !now {
                    run.append(p)
                }
            }
        }
        flush()
    }

    /// FAA runway holding position marking: four 0.15 m yellow lines 0.15 m apart, the two solid
    /// lines on the holding side, the two dashed (0.9 m dash, 0.9 m gap) facing the runway.
    /// Intermediate holding positions are a single dashed line.
    static func hold(_ h: HoldPosition, _ site: AirportSite, into m: inout MeshData) {
        let c = site.xy(h.position)
        let a = h.towardRunway * .pi / 180
        let fwd = SIMD2(sin(a), cos(a)), across = SIMD2(fwd.y, -fwd.x)
        let half = h.width / 2
        func bar(_ along0: Double, _ along1: Double, _ x0: Double, _ x1: Double) {
            let p = [c + fwd * along0 + across * x0, c + fwd * along0 + across * x1,
                     c + fwd * along1 + across * x1, c + fwd * along1 + across * x0].map { SIMD3($0.x, $0.y, site.z($0) + Layer.paint) }
            m.ground(p[0], p[1], p[2]) { _ in .zero }
            m.ground(p[0], p[2], p[3]) { _ in .zero }
        }
        func dashed(_ along: Double) {
            var x = -half
            while x < half { bar(along, along + 0.15, x, min(x + 0.9, half)); x += 1.8 }
        }
        switch h.kind {
        case .runway, .ils:
            bar(-0.525, -0.375, -half, half)
            bar(-0.225, -0.075, -half, half)
            dashed(0.075)
            dashed(0.375)
        case .intermediate:
            dashed(-0.075)
        }
        // Enhanced taxiway centreline: dashed lines 0.15 m either side of the centreline for
        // 45 m on the holding side of a runway holding position.
        if h.kind != .intermediate {
            var d = 1.5
            while d < 45 {
                for side in [-1.0, 1.0] { bar(-d - 2.7, -d, side * 0.225, side * 0.375) }
                d += 3.6
            }
        }
    }

    /// Stand lead-in line (0.15 m yellow) with a stop bar across its end.
    static func leadIn(_ s: Stand, _ site: AirportSite, into m: inout MeshData) {
        let pts = s.line.map(site.xy)
        ribbon(pts, width: 0.15, lift: Layer.paint, site: site, into: &m)
        guard let end = pts.last, let before = pts.dropLast().last else { return }
        let d = simd_normalize(end - before), across = SIMD2(d.y, -d.x)
        ribbon([end + across * 2, end - across * 2], width: 0.3, lift: Layer.paint, site: site, into: &m)
    }

    // MARK: Boarding bridges and windsocks

    /// Mapped bridges, plus one for every stand that stops within 60 m of a terminal and has no
    /// mapped bridge: from the nearest terminal wall to the aircraft's forward left door (about
    /// 4 m behind and 2.5 m left of the stop position).
    public static func jetBridges(_ site: AirportSite) -> [[SIMD2<Double>]] {
        var out = (site.layout.jetBridges ?? []).map { $0.map(site.xy) }
        let terminals = site.layout.buildings.filter { $0.kind == .terminal }.map { Polygon2D.open($0.outer.map(site.xy)) }
        let mappedEnds = out.compactMap(\.last)
        for s in site.layout.stands where s.line.count >= 2 {
            let pts = s.line.map(site.xy)
            let stop = pts[pts.count - 1], dir = simd_normalize(stop - pts[pts.count - 2])
            let left = SIMD2(-dir.y, dir.x)
            let door = stop - dir * 4 + left * 2.5
            if mappedEnds.contains(where: { simd_distance($0, door) < 25 }) { continue }
            var best: (SIMD2<Double>, Double) = (.zero, .infinity)
            for ring in terminals {
                for i in 0..<ring.count {
                    let a = ring[i], ab = ring[(i + 1) % ring.count] - a
                    let t = max(0, min(1, simd_dot(door - a, ab) / max(simd_length_squared(ab), 1e-9)))
                    let q = a + ab * t
                    let d = simd_distance(door, q)
                    if d < best.1 { best = (q, d) }
                }
            }
            guard best.1 < 60, best.1 > 6 else { continue }
            out.append([best.0, door])
        }
        return out
    }

    /// A boarding bridge: a 3 m by 3 m tunnel at floor height 3.2 m, a support leg near the
    /// aircraft end.
    static func bridge(_ line: [SIMD2<Double>], _ site: AirportSite, into m: inout MeshData) {
        guard line.count >= 2 else { return }
        let floor = 3.2, height = 3.0, half = 1.5
        func box(_ a: SIMD2<Double>, _ b: SIMD2<Double>, z0: Double, z1: Double, half: Double) {
            let d = b - a, len = simd_length(d)
            guard len > 0.1 else { return }
            let f = d / len, n = SIMD2(-f.y, f.x)
            let base = site.z((a + b) / 2)
            let corners = [a + n * half, b + n * half, b - n * half, a - n * half]
            func p(_ q: SIMD2<Double>, _ z: Double) -> SIMD3<Double> { SIMD3(q.x, q.y, base + z) }
            // Four sides, uv in metres.
            let sides: [(Int, Int, SIMD2<Double>)] = [(0, 1, n), (1, 2, f), (2, 3, -n), (3, 0, -f)]
            for (i, j, out) in sides {
                let w = simd_distance(corners[i], corners[j])
                let normal = SIMD3(out.x, out.y, 0)
                m.add(p(corners[i], z0), normal, SIMD2(0, 0)); m.add(p(corners[j], z0), normal, SIMD2(w, 0)); m.add(p(corners[j], z1), normal, SIMD2(w, z1 - z0))
                m.add(p(corners[i], z0), normal, SIMD2(0, 0)); m.add(p(corners[j], z1), normal, SIMD2(w, z1 - z0)); m.add(p(corners[i], z1), normal, SIMD2(0, z1 - z0))
            }
            let up = SIMD3<Double>(0, 0, 1)
            m.add(p(corners[0], z1), up, .zero); m.add(p(corners[1], z1), up, .zero); m.add(p(corners[2], z1), up, .zero)
            m.add(p(corners[0], z1), up, .zero); m.add(p(corners[2], z1), up, .zero); m.add(p(corners[3], z1), up, .zero)
        }
        for i in 0..<(line.count - 1) { box(line[i], line[i + 1], z0: floor, z1: floor + height, half: half) }
        // Support leg and wheel bogie 4 m from the aircraft end.
        let end = line[line.count - 1], prev = line[line.count - 2]
        let leg = end + simd_normalize(prev - end) * 4
        box(leg - SIMD2(0.3, 0), leg + SIMD2(0.3, 0), z0: 0, z1: floor, half: 0.3)
    }

    /// A 25 m floodlight mast: a tapered pole and a lamp head.
    static func mast(_ c: SIMD2<Double>, _ site: AirportSite, into m: inout MeshData) {
        let z = site.z(c)
        func prism(_ half0: Double, _ half1: Double, _ z0: Double, _ z1: Double) {
            let corners = [SIMD2(1.0, 1.0), SIMD2(-1.0, 1.0), SIMD2(-1.0, -1.0), SIMD2(1.0, -1.0)]
            for i in 0..<4 {
                let a = corners[i], b = corners[(i + 1) % 4]
                let n2 = simd_normalize(a + b)
                let n = SIMD3(n2.x, n2.y, 0)
                let p0 = SIMD3(c.x + a.x * half0, c.y + a.y * half0, z + z0), p1 = SIMD3(c.x + b.x * half0, c.y + b.y * half0, z + z0)
                let p2 = SIMD3(c.x + b.x * half1, c.y + b.y * half1, z + z1), p3 = SIMD3(c.x + a.x * half1, c.y + a.y * half1, z + z1)
                m.add(p0, n, SIMD2(0, 0)); m.add(p1, n, SIMD2(1, 0)); m.add(p2, n, SIMD2(1, z1 - z0))
                m.add(p0, n, SIMD2(0, 0)); m.add(p2, n, SIMD2(1, z1 - z0)); m.add(p3, n, SIMD2(0, z1 - z0))
            }
        }
        prism(0.25, 0.12, 0, 24.5)
        prism(0.9, 0.9, 24.5, 25.3)
    }

    /// A windsock: a 6 m pole and a striped cone hanging limp (there is no wind until M7).
    static func windsock(_ p: SIMD2<Double>, _ site: AirportSite, into m: inout MeshData) {
        let base = site.z(p)
        let top = SIMD3(p.x, p.y, base + 6)
        // Pole: a thin square post.
        for (dx, dy) in [(0.08, 0.0), (0.0, 0.08), (-0.08, 0.0), (0.0, -0.08)] {
            let o = SIMD3(dx, dy, 0.0), side = SIMD3(-dy, dx, 0.0)
            let n = simd_normalize(o)
            let a = SIMD3(p.x, p.y, base) + o - side, b = SIMD3(p.x, p.y, base) + o + side
            m.add(a, n, SIMD2(0, -1)); m.add(b, n, SIMD2(0, -1)); m.add(b + SIMD3(0, 0, 6), n, SIMD2(0, -1))
            m.add(a, n, SIMD2(0, -1)); m.add(b + SIMD3(0, 0, 6), n, SIMD2(0, -1)); m.add(a + SIMD3(0, 0, 6), n, SIMD2(0, -1))
        }
        // Cone: 3.6 m long, 0.45 m to 0.15 m radius, drooping 55 degrees toward the north-east.
        let droop = 55.0 * .pi / 180, az = 45.0 * .pi / 180
        let axis = SIMD3(cos(droop) * sin(az), cos(droop) * cos(az), -sin(droop))
        let u = simd_normalize(simd_cross(axis, SIMD3(0, 0, 1))), v = simd_cross(u, axis)
        let segments = 10
        for k in 0..<segments {
            let a0 = Double(k) / Double(segments) * 2 * .pi, a1 = Double(k + 1) / Double(segments) * 2 * .pi
            func ring(_ a: Double, _ r: Double, _ along: Double) -> SIMD3<Double> { top + axis * along + (u * cos(a) + v * sin(a)) * r }
            let n0 = u * cos(a0) + v * sin(a0), n1 = u * cos(a1) + v * sin(a1)
            m.add(ring(a0, 0.45, 0), n0, SIMD2(0, 0)); m.add(ring(a1, 0.45, 0), n1, SIMD2(0, 0)); m.add(ring(a1, 0.15, 3.6), n1, SIMD2(3.6, 0))
            m.add(ring(a0, 0.45, 0), n0, SIMD2(0, 0)); m.add(ring(a1, 0.15, 3.6), n1, SIMD2(3.6, 0)); m.add(ring(a0, 0.15, 3.6), n0, SIMD2(3.6, 0))
        }
    }

    // MARK: Buildings

    static func building(_ b: Building, _ site: AirportSite, into g: inout AirportGeometry) {
        var ring = Polygon2D.open(b.outer.map(site.xy))
        guard ring.count >= 3 else { return }
        if Polygon2D.signedArea(ring) < 0 { ring.reverse() }
        // The base sits on the lowest ground under the footprint (sunk 0.5 m); the roof is level.
        let base = ring.map { site.z($0) }.min()! - 0.5
        var mesh = g.buildings[b.kind] ?? MeshData()
        func extrude(_ ring: [SIMD2<Double>], from z0: Double, to z1: Double, into m: inout MeshData) {
            var u = 0.0
            for i in 0..<ring.count {
                let p = ring[i], q = ring[(i + 1) % ring.count]
                let d = q - p, len = simd_length(d)
                guard len > 0.01 else { continue }
                let n = SIMD3(d.y / len, -d.x / len, 0)   // outward for a counter-clockwise ring
                let a = SIMD3(p.x, p.y, z0), bq = SIMD3(q.x, q.y, z0), c = SIMD3(q.x, q.y, z1), e = SIMD3(p.x, p.y, z1)
                let h = z1 - z0
                m.add(a, n, SIMD2(u, 0)); m.add(bq, n, SIMD2(u + len, 0)); m.add(c, n, SIMD2(u + len, h))
                m.add(a, n, SIMD2(u, 0)); m.add(c, n, SIMD2(u + len, h)); m.add(e, n, SIMD2(u, h))
                u += len
            }
        }
        func roof(_ ring: [SIMD2<Double>], holes: [[SIMD2<Double>]], at z: Double, into m: inout MeshData) {
            for (p, q, r) in Polygon2D.triangulate(outer: ring, holes: holes) {
                m.ground(SIMD3(p.x, p.y, z), SIMD3(q.x, q.y, z), SIMD3(r.x, r.y, z)) { SIMD2($0.x, $0.y) }
            }
        }
        let holes = b.holes.map { $0.map(site.xy) }
        if b.kind == .tower && b.height > 25 {
            // Shaft to 88% of the height, a wider glazed cab, then a roof cap.
            let c = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
            let cab = ring.map { c + ($0 - c) * 1.45 }
            let shaftTop = base + 0.5 + b.height * 0.88, cabTop = base + 0.5 + b.height * 0.97
            extrude(ring, from: base, to: shaftTop, into: &mesh)
            roof(cab, holes: [], at: shaftTop, into: &mesh)
            extrude(cab, from: shaftTop, to: cabTop, into: &g.glazing)
            extrude(cab, from: cabTop, to: base + 0.5 + b.height, into: &mesh)
            roof(cab, holes: [], at: base + 0.5 + b.height, into: &mesh)
        } else {
            let z0 = base + b.minHeight, z1 = base + 0.5 + b.height
            extrude(ring, from: z0, to: z1, into: &mesh)
            for h in holes { extrude(h.reversed(), from: z0, to: z1, into: &mesh) }
            roof(ring, holes: holes, at: z1, into: &mesh)
        }
        g.buildings[b.kind] = mesh
    }
}
