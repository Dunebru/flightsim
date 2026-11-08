public import Airports
public import simd
import Foundation

/// The taxiway network as a graph, in the airport frame: nodes where centrelines bend or meet,
/// edges along them. Centrelines that end on another's side without a shared point (a common
/// gap in mapped data) are joined there.
public struct TaxiGraph: Sendable {
    public private(set) var nodes: [SIMD2<Double>] = []
    public private(set) var edges: [[Int]] = []

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
        func link(_ a: Int, _ b: Int) {
            guard a != b, !edges[a].contains(b) else { return }
            edges[a].append(b)
            edges[b].append(a)
        }
        for tw in site.layout.taxiways where tw.points.count >= 2 {
            let pts = tw.points.map(site.xy)
            var previous = node(pts[0])
            for p in pts.dropFirst() {
                let n = node(p)
                link(previous, n)
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
                edges[best.a].removeAll { $0 == best.b }
                edges[best.b].removeAll { $0 == best.a }
                link(best.a, m)
                link(m, best.b)
                link(d, m)
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

    /// Shortest path between two nodes (A*), as node indices, or nil when they are not connected.
    public func path(from start: Int, to goal: Int, avoiding blocked: Set<Int> = []) -> [Int]? {
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
                let cost = g[current]! + simd_distance(nodes[current], nodes[next])
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
