import Foundation
import simd

/// One light fixture in the airport frame.
public struct LightPoint: Sendable {
    public enum Behaviour: Sendable, Equatable {
        case steady
        /// Flashes `perSecond` times a second, offset by `phase` (0-1) of the period.
        case flashing(perSecond: Double, phase: Double)
        /// A PAPI unit: white above `angle` degrees of elevation, red below.
        case papi(angle: Double)
    }
    public var position: SIMD3<Double>
    /// Linear RGB colour (unit luminance-ish).
    public var colour: SIMD3<Double>
    /// Peak intensity, candela.
    public var candela: Double
    /// Beam axis (unit) and half-width; a zero axis is omnidirectional.
    public var direction: SIMD3<Double>
    public var beamDegrees: Double
    public var behaviour: Behaviour
    /// Switched on only after sunset (apron floodlights).
    public var nightOnly = false

    public init(position: SIMD3<Double>, colour: SIMD3<Double>, candela: Double, direction: SIMD3<Double> = .zero,
                beamDegrees: Double = 180, behaviour: Behaviour = .steady, nightOnly: Bool = false) {
        self.nightOnly = nightOnly
        self.position = position
        self.colour = colour
        self.candela = candela
        self.direction = direction
        self.beamDegrees = beamDegrees
        self.behaviour = behaviour
    }
}

/// Airport lighting from the NASR attributes, laid out per FAA AC 150/5340-30 as recalled
/// (spacings and colours below; see PROGRESS.md for what is approximate).
public enum AirportLights {
    static let white = SIMD3<Double>(1, 0.95, 0.85)
    static let yellow = SIMD3<Double>(1, 0.75, 0.25)
    static let green = SIMD3<Double>(0.25, 1, 0.45)
    static let red = SIMD3<Double>(1, 0.12, 0.08)
    static let blue = SIMD3<Double>(0.2, 0.35, 1)
    static let ft = 0.3048

    public static func build(_ site: AirportSite) -> [LightPoint] {
        var out: [LightPoint] = []
        let frames = site.layout.runways.map(site.runwayFrame)
        for (r, f) in zip(site.layout.runways, frames) { runway(r, f, site, into: &out) }
        taxiwayEdges(site, runways: frames, into: &out)
        apronMasts(site, into: &out)
        for h in site.layout.holdPositions where h.kind != .intermediate { guardLights(h, site, into: &out) }
        return out
    }

    static func runway(_ r: Runway, _ f: RunwayFrame, _ site: AirportSite, into out: inout [LightPoint]) {
        let L = f.length, W = r.width
        func p(_ s: Double, _ t: Double, _ h: Double = 0.35) -> SIMD3<Double> {
            let q = f.point(s, t)
            return SIMD3(q.x, q.y, site.z(q) + h)
        }
        // Beam directions (where the light points) that face pilots landing on end 0 / end 1.
        let toward = [SIMD3(-f.axis.x, -f.axis.y, 0), SIMD3(f.axis.x, f.axis.y, 0)]
        let instrument = r.ends.contains { $0.markings == "PIR" || $0.ils }

        // Edge lights every 60 m, 3 m outside the edge; each fixture shows white to both
        // directions, yellow in the last 610 m (2,000 ft) as seen landing toward that end.
        if r.edgeLights != nil {
            let n = Int(L / 60)
            for i in 0...n {
                let s = L * Double(i) / Double(n)
                for side in [-1.0, 1.0] {
                    let pos = p(s, side * (W / 2 + 3))
                    // Seen by pilots landing on end 0 (heading +axis): yellow near end 1.
                    let c0 = instrument && L - s < 610 ? yellow : white
                    let c1 = instrument && s < 610 ? yellow : white
                    out.append(LightPoint(position: pos, colour: c0, candela: 2_500, direction: toward[0], beamDegrees: 70))
                    out.append(LightPoint(position: pos, colour: c1, candela: 2_500, direction: toward[1], beamDegrees: 70))
                }
            }
        }

        for (k, end) in r.ends.enumerated() {
            // `along(d)`: s of a point d metres in from this end along its landing direction.
            func along(_ d: Double) -> Double { k == 0 ? d : L - d }
            func at(_ d: Double, _ y: Double, _ h: Double = 0.35) -> SIMD3<Double> { p(along(d), k == 0 ? y : -y, h) }
            let inbound = -toward[k]          // the direction a landing pilot flies
            let face = toward[k]              // facing that pilot
            let disp = end.displacedThreshold

            // Threshold: green across the threshold facing the approach; red end lights facing
            // the runway at the pavement end.
            for i in 0...10 {
                let y = -W / 2 + W * Double(i) / 10
                out.append(LightPoint(position: at(disp, y, 0.2), colour: green, candela: 3_000, direction: face, beamDegrees: 60))
                out.append(LightPoint(position: at(0, y, 0.2), colour: red, candela: 1_500, direction: inbound, beamDegrees: 60))
            }
            // Centreline every 15 m: white, then alternating red and white for the last 914 m,
            // red for the last 305 m, as seen landing on this end.
            if end.centerlineLights {
                var d = disp + 23
                while d < L - 23 {
                    let remaining = L - d
                    let colour = remaining < 305 ? red : (remaining < 914 ? (Int(d / 15) % 2 == 0 ? red : white) : white)
                    out.append(LightPoint(position: at(d, 0, 0.05), colour: colour, candela: 1_000, direction: face, beamDegrees: 30))
                    d += 15
                }
            }
            // Touchdown zone: barrettes of three, 1.5 m apart, either side, every 30 m to 914 m.
            if end.touchdownZoneLights {
                var d = disp + 30
                while d <= disp + 914 {
                    for side in [-1.0, 1.0] {
                        for b in 0..<3 { out.append(LightPoint(position: at(d, side * (11 + Double(b) * 1.5), 0.05), colour: white,
                                                               candela: 1_500, direction: face, beamDegrees: 30)) }
                    }
                    d += 30
                }
            }
            // REIL: a synchronized pair of white strobes either side of the threshold.
            if end.endIdentifierLights {
                for side in [-1.0, 1.0] {
                    out.append(LightPoint(position: at(disp, side * (W / 2 + 12), 0.6), colour: white, candela: 15_000,
                                          direction: face, beamDegrees: 30, behaviour: .flashing(perSecond: 2, phase: 0)))
                }
            }
            approach(end, at: at, face: face, into: &out)
            papi(end, r: r, at: at, face: face, into: &out)
        }
    }

    /// Approach lighting systems before the threshold (negative distances).
    static func approach(_ end: RunwayEnd, at: (Double, Double, Double) -> SIMD3<Double>, face: SIMD3<Double>,
                         into out: inout [LightPoint]) {
        guard let kind = end.approachLights else { return }
        let thr = end.displacedThreshold
        func barrette(_ d: Double, half: Double = 2.1, colour: SIMD3<Double> = white, cd: Double = 6_000) {
            for i in 0..<5 {
                let y = -half + Double(i) * half / 2
                out.append(LightPoint(position: at(thr - d, y, 1.0 + d * 0.002), colour: colour, candela: cd, direction: face, beamDegrees: 25))
            }
        }
        func flashers(from: Double, to: Double) {
            var d = from, n = 0
            let count = Int((from - to) / 61) + 1
            while d >= to {
                out.append(LightPoint(position: at(thr - d, 0, 1.5 + d * 0.002), colour: white, candela: 25_000, direction: face,
                                      beamDegrees: 20, behaviour: .flashing(perSecond: 2, phase: Double(n) / Double(max(count, 1)) * 0.5)))
                d -= 61; n += 1
            }
        }
        switch kind {
        case "ALSF2", "ALSF1":
            // 2,400 ft: barrettes every 100 ft, crossbars at 500 and 1,000 ft, red side rows in the
            // inner 1,000 ft, sequenced flashers from 2,400 ft to 1,000 ft.
            var d = 30.5
            while d <= 731.5 { barrette(d); d += 30.5 }
            for y in stride(from: -15.0, through: 15.0, by: 1.5) where abs(y) > 3 {
                out.append(LightPoint(position: at(thr - 304.8, y, 1.4), colour: white, candela: 6_000, direction: face, beamDegrees: 25))
                out.append(LightPoint(position: at(thr - 152.4, y, 1.2), colour: white, candela: 6_000, direction: face, beamDegrees: 25))
            }
            d = 30.5
            while d <= 304.8 {
                for side in [-1.0, 1.0] {
                    for i in 0..<3 {
                        out.append(LightPoint(position: at(thr - d, side * (11 + Double(i) * 1.5), 1.0), colour: red,
                                              candela: 3_000, direction: face, beamDegrees: 25))
                    }
                }
                d += 30.5
            }
            flashers(from: 731.5, to: 335)
        case "MALSR", "MALSF", "MALS", "SSALR", "SSALF":
            // 1,400 ft: barrettes every 200 ft, a crossbar at 1,000 ft; MALSR adds sequenced
            // flashers out to 2,400 ft, MALSF flashes the outer three barrettes.
            var d = 61.0
            while d <= 426.7 { barrette(d, half: 1.8); d += 61 }
            for y in stride(from: -9.1, through: 9.1, by: 1.5) where abs(y) > 2.5 {
                out.append(LightPoint(position: at(thr - 304.8, y, 1.4), colour: white, candela: 6_000, direction: face, beamDegrees: 25))
            }
            if kind.hasSuffix("R") { flashers(from: 731.5, to: 487.7) }
            if kind == "MALSF" || kind == "SSALF" { flashers(from: 426.7, to: 304.8) }
        default:
            var d = 61.0
            while d <= 426.7 { barrette(d, half: 1.8); d += 61 }
        }
    }

    /// PAPI: four units 9 m apart beside the runway, placed so the 3 degree path crosses the
    /// threshold at the published crossing height; settings 2.5, 2.83, 3.17, 3.5 degrees from
    /// the outer unit to the inner one.
    static func papi(_ end: RunwayEnd, r: Runway, at: (Double, Double, Double) -> SIMD3<Double>, face: SIMD3<Double>,
                     into out: inout [LightPoint]) {
        guard let code = end.visualGlideSlope, code.hasPrefix("P") else { return }
        let units = code.contains("2") ? 2 : 4
        let angle = end.glidePathAngle ?? 3
        let tch = end.thresholdCrossingHeight ?? 15
        let d = end.displacedThreshold + tch / tan(angle * .pi / 180)
        let left = !code.hasSuffix("R")
        let inner = r.width / 2 + 15
        let settings = units == 4 ? [angle + 0.5, angle + 0.17, angle - 0.17, angle - 0.5] : [angle + 0.25, angle - 0.25]
        for (i, a) in settings.enumerated() {
            let y = inner + Double(i) * 9
            out.append(LightPoint(position: at(d, left ? y : -y, 0.8), colour: white, candela: 8_000, direction: face,
                                  beamDegrees: 15, behaviour: .papi(angle: a)))
        }
    }

    /// Blue taxiway edge lights every 60 m along both edges, left out where the edge lies on
    /// other pavement (runways, other taxiways) so intersections stay clear.
    static func taxiwayEdges(_ site: AirportSite, runways: [RunwayFrame], into out: inout [LightPoint]) {
        // A coarse grid of taxiway segments for "is this point on a taxiway?".
        let cell = 100.0
        var grid: [SIMD2<Int>: [(SIMD2<Double>, SIMD2<Double>, Double)]] = [:]
        let lines = site.layout.taxiways.map { t in (t.points.map(site.xy), t.width) }
        for (pts, w) in lines {
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let lo = SIMD2<Int>(Int(floor(min(a.x, b.x) / cell)), Int(floor(min(a.y, b.y) / cell)))
                let hi = SIMD2<Int>(Int(floor(max(a.x, b.x) / cell)), Int(floor(max(a.y, b.y) / cell)))
                for x in lo.x...hi.x { for y in lo.y...hi.y { grid[SIMD2(x, y), default: []].append((a, b, w)) } }
            }
        }
        func onPavement(_ p: SIMD2<Double>) -> Bool {
            if runways.contains(where: { $0.contains(p, margin: 5) }) { return true }
            for (a, b, w) in grid[SIMD2(Int(floor(p.x / cell)), Int(floor(p.y / cell)))] ?? [] {
                let ab = b - a
                let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9)))
                if simd_distance(p, a + ab * t) < w / 2 - 0.5 { return true }
            }
            return false
        }
        for (pts, w) in lines {
            var carry = 0.0
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let len = simd_distance(a, b)
                guard len > 0.1 else { continue }
                let dir = (b - a) / len, n = SIMD2(-dir.y, dir.x)
                var s = 60 - carry
                while s < len {
                    let c = a + dir * s
                    for side in [-1.0, 1.0] {
                        let q = c + n * side * (w / 2 + 1)
                        if !onPavement(q) {
                            out.append(LightPoint(position: SIMD3(q.x, q.y, site.z(q) + 0.35), colour: blue, candela: 60))
                        }
                    }
                    s += 60
                }
                carry = len - (s - 60)
            }
        }
    }

    /// High-mast apron floodlights every 150 m around each apron, 8 m inside its edge, 25 m up,
    /// on at night only.
    static func apronMasts(_ site: AirportSite, into out: inout [LightPoint]) {
        for c in mastPositions(site) {
            out.append(LightPoint(position: SIMD3(c.x, c.y, site.z(c) + 25), colour: SIMD3(1, 0.86, 0.66), candela: 40_000, nightOnly: true))
        }
    }

    public static func mastPositions(_ site: AirportSite) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for a in site.layout.aprons {
            var ring = Polygon2D.open(a.outer.map(site.xy))
            guard ring.count >= 3 else { continue }
            if Polygon2D.signedArea(ring) < 0 { ring.reverse() }
            var carry = 0.0
            for i in 0..<ring.count {
                let p = ring[i], q = ring[(i + 1) % ring.count]
                let len = simd_distance(p, q)
                guard len > 1 else { continue }
                let d = (q - p) / len, inward = SIMD2(-d.y, d.x)
                var s = 150 - carry
                while s < len {
                    out.append(p + d * s + inward * 8)
                    s += 150
                }
                carry = len - (s - 150)
            }
        }
        return out
    }

    /// Runway guard lights: a pair of yellow lights either side of a runway holding position,
    /// flashing alternately ("wig-wag"), facing traffic approaching the runway.
    static func guardLights(_ h: HoldPosition, _ site: AirportSite, into out: inout [LightPoint]) {
        let c = site.xy(h.position)
        let a = h.towardRunway * .pi / 180
        let fwd = SIMD2(sin(a), cos(a)), across = SIMD2(fwd.y, -fwd.x)
        for side in [-1.0, 1.0] {
            for (j, offset) in [-0.25, 0.25].enumerated() {
                let q = c - fwd * 1 + across * side * (h.width / 2 + 3 + offset)
                out.append(LightPoint(position: SIMD3(q.x, q.y, site.z(q) + 0.8), colour: yellow, candela: 3_000,
                                      direction: SIMD3(-fwd.x, -fwd.y, 0), beamDegrees: 40,
                                      behaviour: .flashing(perSecond: 0.8, phase: j == 0 ? 0 : 0.5)))
            }
        }
    }
}
