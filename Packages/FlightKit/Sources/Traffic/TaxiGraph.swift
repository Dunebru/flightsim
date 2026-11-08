public import Airports
import simd
import Foundation

/// The taxiway network as a graph, in the airport frame: nodes where centrelines bend or meet,
/// edges along them. Centrelines that end on another's side without a shared point (a common
/// gap in mapped data) are joined there.
public struct TaxiGraph: Sendable {
    public private(set) var nodes: [SIMD2<Double>] = []
    public private(set) var edges: [[Int]] = []
    /// Taxiway names along edges (keyed by the lower node index, then the higher).
    private var refs: [Int: [Int: String]] = [:]

    /// The taxiway an edge belongs to, when it is named.
    public func ref(_ a: Int, _ b: Int) -> String? { refs[min(a, b)]?[max(a, b)] }

    public init(site: AirportSite) {
        var cells: [SIMD2<Int>: [Int]] = [:]
        func cell(_ p: SIMD2<Double>) -> SIMD2<Int> { SIMD2(Int((p.x / 5).rounded(.down)), Int((p.y / 5).rounded(.down))) }
        func node(_ p: SIMD2<Double>) -> Int {
            let c = cell(p)
            for dx in -1...1 {
                for dy in -1...1 {
                    for i in cells[c &+ SIMD2(dx, dy)] ?? [] where simd_distance(nodes[i], p) < 2.5 { return i }
                }
            }
            nodes.append(p)
            edges.append([])
            cells[c, default: []].append(nodes.count - 1)
            return nodes.count - 1
        }
        func link(_ a: Int, _ b: Int, _ name: String?) {
            guard a != b, !edges[a].contains(b) else { return }
            edges[a].append(b)
            edges[b].append(a)
            if let name, !name.isEmpty { refs[min(a, b), default: [:]][max(a, b)] = name }
        }
        for tw in site.layout.taxiways where tw.points.count >= 2 {
            let pts = tw.points.map(site.xy)
            var previous = node(pts[0])
            for p in pts.dropFirst() {
                let n = node(p)
                link(previous, n, tw.ref)
                previous = n
            }
        }
        // Dead ends lying on another centreline's side: split that segment there and join.
        let deadEnds = edges.indices.filter { edges[$0].count == 1 }
        for d in deadEnds {
            let p = nodes[d]
            var best: (a: Int, b: Int, q: SIMD2<Double>, dist: Double)?
            for a in nodes.indices {
                for b in edges[a] where b > a && a != d && b != d && !edges[d].contains(a) && !edges[d].contains(b) {
                    let ab = nodes[b] - nodes[a]
                    let len2 = simd_length_squared(ab)
                    guard len2 > 1 else { continue }
                    let t = simd_dot(p - nodes[a], ab) / len2
                    guard t > 0.02, t < 0.98 else { continue }
                    let q = nodes[a] + ab * t
                    let dist = simd_distance(p, q)
                    if dist < 10, dist < (best?.dist ?? .infinity) { best = (a, b, q, dist) }
                }
            }
            if let best {
                let m = nodes.count
                nodes.append(best.q)
                edges.append([])
                let name = refs[min(best.a, best.b)]?[max(best.a, best.b)]
                edges[best.a].removeAll { $0 == best.b }
                edges[best.b].removeAll { $0 == best.a }
                link(best.a, m, name)
                link(m, best.b, name)
                link(d, m, edges[d].first.flatMap { refs[min(d, $0)]?[max(d, $0)] })
            }
        }
    }

    /// The node nearest a point, if one is within `limit` metres.
    public func nearest(_ p: SIMD2<Double>, within limit: Double = 80, where accept: (Int) -> Bool = { _ in true }) -> Int? {
        var best: (Int, Double)?
        for i in nodes.indices where accept(i) {
            let d = simd_distance(nodes[i], p)
            if d < limit, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    /// The taxiway names along a path, in order, each once per stretch ("C", "B", "B3").
    public func names(along path: [Int]) -> [String] {
        var out: [String] = []
        for (a, b) in zip(path, path.dropFirst()) {
            if let r = ref(a, b), r != out.last { out.append(r) }
        }
        return out
    }

    /// Shortest path between two nodes (A*), as node indices, or nil when they are not connected.
    /// `turnPenalty`: metres added for each change of taxiway name, so a route keeps to one
    /// taxiway the way a controller's clearance does rather than hopping between parallels.
    public func path(from start: Int, to goal: Int, avoiding blocked: Set<Int> = [], turnPenalty: Double = 0) -> [Int]? {
        if start == goal { return [start] }
        var g = [Int: Double](), came = [Int: Int]()
        g[start] = 0
        var open: [(Int, Double)] = [(start, simd_distance(nodes[start], nodes[goal]))]
        var closed = Set<Int>()
        while !open.isEmpty {
            // Small graphs: a linear scan for the best open node is fast enough.
            let k = open.indices.min { open[$0].1 < open[$1].1 }!
            let (current, _) = open.remove(at: k)
            if current == goal {
                var path = [goal], n = goal
                while let p = came[n] { path.append(p); n = p }
                return path.reversed()
            }
            guard closed.insert(current).inserted else { continue }
            for next in edges[current] where !closed.contains(next) && (!blocked.contains(next) || next == goal) {
                var cost = g[current]! + simd_distance(nodes[current], nodes[next])
                if turnPenalty > 0, let before = came[current], let r1 = ref(before, current), let r2 = ref(current, next), r1 != r2 {
                    cost += turnPenalty
                }
                if cost < g[next] ?? .infinity {
                    g[next] = cost
                    came[next] = current
                    open.append((next, cost + simd_distance(nodes[next], nodes[goal])))
                }
            }
        }
        return nil
    }
}
