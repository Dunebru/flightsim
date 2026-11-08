import Foundation
import simd

/// An airport sign: a lit box on legs with one or two lettered faces.
public struct SignPlacement: Sendable {
    public enum Style: String, Sendable, Hashable {
        /// White on red: runway holding position ("08-26").
        case mandatory
        /// Yellow on black with a yellow border: the taxiway you are on.
        case location
        /// White on black: runway distance remaining, thousands of feet.
        case distance
        /// Black on yellow with an arrow: the taxiways branching off ahead.
        case direction
    }
    public struct Face: Sendable, Hashable {
        public var text: String
        public var style: Style
    }
    /// Base centre on the ground (airport frame).
    public var position: SIMD3<Double>
    /// True heading the front face looks toward (degrees): it is read by someone travelling
    /// the opposite way.
    public var facing: Double
    public var front: Face
    public var back: Face?
    /// Face height, metres (the legend panel).
    public var height: Double
}

/// Signs per FAA AC 150/5340-18 as recalled: holding position signs on the left of each
/// runway holding position with the taxiway location sign outboard of them, and distance
/// remaining signs every 1,000 ft along the left side of each runway. Direction signs at
/// taxiway junctions are not generated yet.
public enum AirportSigns {
    public static func build(_ site: AirportSite) -> [SignPlacement] {
        var out: [SignPlacement] = []
        let taxiways = site.layout.taxiways.map { t in (t.ref, t.points.map(site.xy)) }
        for h in site.layout.holdPositions where h.kind != .intermediate {
            guard let rw = site.layout.runways.first(where: { $0.name == h.runway }) else { continue }
            let c = site.xy(h.position)
            let a = h.towardRunway * .pi / 180
            let fwd = SIMD2(sin(a), cos(a)), left = SIMD2(-fwd.y, fwd.x)
            // The runway end on the pilot's left comes first: "08-26" means 08's threshold is to the left.
            let f = site.runwayFrame(rw)
            let lowOnLeft = simd_dot(f.low - c, left) > simd_dot(f.high - c, left)
            let text = lowOnLeft ? "\(rw.ends[0].ident)-\(rw.ends[1].ident)" : "\(rw.ends[1].ident)-\(rw.ends[0].ident)"
            let facing = (h.towardRunway + 180).truncatingRemainder(dividingBy: 360)
            let sideways: SIMD2<Double> = left * (h.width / 2 + 7)
            let base: SIMD2<Double> = c - fwd + sideways
            out.append(SignPlacement(position: site.onSurface(base), facing: facing,
                                     front: .init(text: text, style: .mandatory), back: nil, height: 0.9))
            // Location sign outboard, with the taxiway's name.
            if let ref = nearestRef(c, taxiways), !ref.isEmpty {
                let width = Double(text.count) * 0.65 + 0.8
                let gap: Double = width / 2 + Double(ref.count) * 0.35 + 0.8
                let outboard: SIMD2<Double> = base + left * gap
                out.append(SignPlacement(position: site.onSurface(outboard), facing: facing,
                                         front: .init(text: ref, style: .location), back: nil, height: 0.9))
            }
        }
        out += directionSigns(site)
        // Distance remaining: on the left of each landing direction, 18 m outside the edge.
        let thousand = 304.8
        for rw in site.layout.runways {
            let f = site.runwayFrame(rw)
            let n = Int(f.length / thousand)
            guard n >= 2 else { continue }
            for (k, end) in rw.ends.enumerated() {
                _ = end
                for remaining in 1..<n {
                    let d = f.length - Double(remaining) * thousand     // from this end
                    let s = k == 0 ? d : f.length - d
                    let t = (k == 0 ? 1.0 : -1.0) * (rw.width / 2 + 18)
                    let facing = (k == 0 ? f.heading + 180 : f.heading).truncatingRemainder(dividingBy: 360)
                    out.append(SignPlacement(position: site.onSurface(f.point(s, t)), facing: facing,
                                             front: .init(text: "\(remaining)", style: .distance), back: nil, height: 1.1))
                }
            }
        }
        return out
    }

    /// Arrow for a turn of `angle` degrees (positive to the right).
    static func arrow(_ angle: Double) -> String {
        switch angle {
        case ..<(-112): "\u{2199}"     // back left
        case ..<(-67): "\u{2190}"
        case ..<(-22): "\u{2196}"
        case ..<22: "\u{2191}"
        case ..<67: "\u{2197}"
        case ..<112: "\u{2192}"
        default: "\u{2198}"
        }
    }

    /// Direction sign arrays before taxiway junctions: where a named taxiway meets others with
    /// different names (a point shared by their centrelines), traffic arriving along it sees, on
    /// its left 25 m before the junction, its own location sign and a direction sign for each
    /// branch, left-hand branches to the left of the location sign.
    static func directionSigns(_ site: AirportSite) -> [SignPlacement] {
        struct Leg { let ref: String; let point: SIMD2<Double>; let next: SIMD2<Double>; let width: Double }
        // Legs leaving every vertex, keyed by rounded position.
        var legs: [SIMD2<Int>: [Leg]] = [:]
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int((p.x * 2).rounded()), Int((p.y * 2).rounded())) }
        for t in site.layout.taxiways {
            guard let ref = t.ref, !ref.isEmpty, t.kind == .taxiway else { continue }
            let pts = t.points.map(site.xy)
            for i in 0..<pts.count {
                if i + 1 < pts.count { legs[key(pts[i]), default: []].append(Leg(ref: ref, point: pts[i], next: pts[i + 1], width: t.width)) }
                if i > 0 { legs[key(pts[i]), default: []].append(Leg(ref: ref, point: pts[i], next: pts[i - 1], width: t.width)) }
            }
        }
        var out: [SignPlacement] = []
        let runways = site.layout.runways.map(site.runwayFrame)
        for (_, here) in legs {
            let refs = Set(here.map(\.ref))
            guard refs.count >= 2, let junction = here.first?.point,
                  !runways.contains(where: { $0.contains(junction, margin: 60) }) else { continue }
            for arriving in here {
                // Traffic arrives along this leg, toward the junction.
                let back = arriving.next - junction
                guard simd_length(back) > 30 else { continue }
                let inbound = -simd_normalize(back)
                let heading = atan2(inbound.x, inbound.y) * 180 / .pi
                var branches: [(String, Double)] = []
                for leg in here where leg.ref != arriving.ref {
                    let d = simd_normalize(leg.next - junction)
                    let turn = atan2(inbound.x * d.y - inbound.y * d.x, simd_dot(inbound, d)) * -180 / .pi
                    if !branches.contains(where: { $0.0 == leg.ref && abs($0.1 - turn) < 20 }) { branches.append((leg.ref, turn)) }
                }
                guard !branches.isEmpty else { continue }
                branches.sort { $0.1 < $1.1 }
                let left = SIMD2(-inbound.y, inbound.x)
                let base = junction - inbound * 25 + left * (arriving.width / 2 + 6)
                let facing = (heading + 180 + 360).truncatingRemainder(dividingBy: 360)
                // Lay the array out along the pilot's left-to-right axis (-left), centred on base.
                var faces: [SignPlacement.Face] = []
                for (ref, turn) in branches where turn < 0 { faces.append(.init(text: "\(arrow(turn)) \(ref)", style: .direction)) }
                faces.append(.init(text: arriving.ref, style: .location))
                for (ref, turn) in branches where turn >= 0 { faces.append(.init(text: "\(ref) \(arrow(turn))", style: .direction)) }
                let widths = faces.map { Double($0.text.count) * 0.62 + 0.9 }
                var x = -widths.reduce(0, +) / 2
                for (face, w) in zip(faces, widths) {
                    let p = base - left * (x + w / 2)
                    out.append(SignPlacement(position: site.onSurface(p), facing: facing, front: face, back: nil, height: 0.9))
                    x += w + 0.1
                }
            }
        }
        return out
    }

    static func nearestRef(_ p: SIMD2<Double>, _ taxiways: [(String?, [SIMD2<Double>])]) -> String? {
        var best: (String?, Double) = (nil, .infinity)
        for (ref, pts) in taxiways where ref != nil {
            for i in 0..<(pts.count - 1) {
                let a = pts[i], ab = pts[i + 1] - a
                let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9)))
                let d = simd_distance(p, a + ab * t)
                if d < best.1 { best = (ref, d) }
            }
        }
        return best.1 < 40 ? best.0 : nil
    }
}
