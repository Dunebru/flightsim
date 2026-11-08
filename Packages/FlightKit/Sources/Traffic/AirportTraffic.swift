public import Airports
public import simd
import Foundation

/// AI airliners at one airport: arrivals down the ILS to a free gate, departures from a gate to
/// takeoff, on the runways the wind favours. Positions are in the airport frame (metres east,
/// north and up from the reference point).
/// Used from one thread at a time (built off the main thread, then updated on it).
public final class AirportTraffic: @unchecked Sendable {
    /// One aircraft for the renderer: position, heading (radians from north), pitch and roll
    /// (radians), whether it is a widebody, and a per-aircraft number (livery).
    public struct Snapshot: Sendable {
        public var position: SIMD3<Double>
        public var heading: Double
        public var pitch: Double
        public var roll: Double
        public var widebody: Bool
        public var seed: Double
        public var onGround: Bool
    }

    /// A runway end in use: where its threshold is, which way it points, how long it is.
    struct RunwayEnd {
        var ident: String
        var threshold: SIMD2<Double>
        var direction: SIMD2<Double>
        var length: Double
        var width: Double
        var elevation: Double
        /// Taxi graph nodes on this runway: where to leave it after landing (beyond the first
        /// 1,300 m) and where to enter it to depart (within 400 m of the threshold).
        var exits: [(node: Int, off: Int, along: Double)]
        var entries: [(node: Int, off: Int, along: Double)]

        func along(_ p: SIMD2<Double>) -> Double { simd_dot(p - threshold, direction) }
        func point(_ s: Double) -> SIMD2<Double> { threshold + direction * s }
    }

    enum Phase {
        case approach, rollout, taxiIn, parked(until: Double), pushback, taxiOut, holding, lineup(until: Double), takeoff, climb
    }

    struct Aircraft {
        var id: Int
        var widebody: Bool
        var seed: Double
        var phase: Phase
        var runway: Int
        var stand: Int
        var position: SIMD3<Double>
        var heading: Double
        var pitch = 0.0
        var speed: Double
        /// Ground path being followed and progress along it.
        var path: [SIMD2<Double>] = []
        var leg = 0
        var stopped = 0.0
        var withdrawn = false
        /// Waiting in the line for a runway.
        var queued = false
        /// Given the right of way to break a deadlock, and for how long it has moved freely since.
        var rightOfWay = false
        var rightOfWayFor = 0.0
    }

    public let site: AirportSite
    let graph: TaxiGraph
    let stands: [StandSlot]
    /// Gates free for traffic: no parked aircraft and not the player's.
    let freeStands: [Int]
    private(set) var runways: [RunwayEnd] = []
    private var active: [Int] = []
    private var aircraft: [Aircraft] = []
    private var reserved = Set<Int>()
    /// Each ground aircraft's next 60 m, taken at the start of the step.
    private var aheadCache: [Int: [SIMD2<Double>]] = [:]
    private var nextID = 0
    private var rng: UInt64
    private(set) var clock = 0.0
    /// Events for tests and the log: landings, gate arrivals, takeoffs.
    public private(set) var landings = 0, arrivedAtGate = 0, takeoffs = 0, withdrawals = 0
    /// Smallest distance seen between two aircraft on the ground (metres), for tests.
    public private(set) var closestOnGround = Double.infinity
    /// What was happening the times two came within 25 m on the ground (tests).
    public private(set) var closeCalls: [String] = []
    public private(set) var withdrawalNotes: [String] = []
    private(set) var withdrawnPositions: [SIMD2<Double>] = []
    public var maxAircraft = 14

    public init(site: AirportSite, excludingStand: String?, windFromDegrees: Double = 0, windKnots: Double = 0, seed: UInt64 = 1) {
        self.site = site
        graph = TaxiGraph(site: site)
        let slots = site.airlinerStands
        stands = slots
        freeStands = slots.indices.filter { !slots[$0].occupied && slots[$0].ref != excludingStand }
        rng = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        runways = Self.runwayEnds(site: site, graph: graph)
        setWind(fromDegrees: windFromDegrees, knots: windKnots)
    }

    /// Picks the runway ends in use: into the wind, or the west-facing ends when it is light (the
    /// usual flow at both KPHX and KLAX).
    public func setWind(fromDegrees: Double, knots: Double) {
        var chosen: [Int] = []
        for rw in site.layout.runways where rw.ends.count == 2 {
            let ids = rw.ends.map(\.ident)
            let candidates = runways.indices.filter { ids.contains(runways[$0].ident) }
            guard !candidates.isEmpty else { continue }
            let best = candidates.max { a, b in score(runways[a], fromDegrees, knots) < score(runways[b], fromDegrees, knots) }!
            chosen.append(best)
        }
        active = chosen
    }

    private func score(_ r: RunwayEnd, _ from: Double, _ knots: Double) -> Double {
        let course = atan2(r.direction.x, r.direction.y)
        let headwind = cos(from * .pi / 180 - course) * knots
        let westward = r.direction.x < 0 ? 1.0 : 0.0
        return knots < 5 ? westward + headwind * 0.01 : headwind
    }

    public var activeRunways: [String] { active.map { runways[$0].ident } }

    // MARK: Runways and the graph

    static func runwayEnds(site: AirportSite, graph: TaxiGraph) -> [RunwayEnd] {
        var out: [RunwayEnd] = []
        for rw in site.layout.runways where rw.ends.count == 2 {
            for i in 0..<2 {
                let end = rw.ends[i], far = rw.ends[1 - i]
                let a = site.xy(end.position), b = site.xy(far.position)
                let full = simd_distance(a, b)
                guard full > 500 else { continue }
                let dir = (b - a) / full
                let threshold = a + dir * end.displacedThreshold
                var r = RunwayEnd(ident: end.ident, threshold: threshold, direction: dir, length: full - end.displacedThreshold,
                                  width: rw.width, elevation: site.z(threshold), exits: [], entries: [])
                let half = rw.width / 2
                func cross(_ p: SIMD2<Double>) -> Double {
                    let d = p - threshold
                    return abs(d.x * dir.y - d.y * dir.x)
                }
                for n in graph.nodes.indices {
                    let p = graph.nodes[n]
                    let s = r.along(p)
                    guard cross(p) < half + 4, s > -end.displacedThreshold - 50, s < r.length + 50 else { continue }
                    // A neighbour well off the runway: this node joins a taxiway to it.
                    for m in graph.edges[n] where cross(graph.nodes[m]) > half + 8 {
                        let forward = r.along(graph.nodes[m]) - s
                        if s > 1_300, s < r.length - 200, forward > -40 { r.exits.append((n, m, s)) }
                        if s < 400 { r.entries.append((n, m, s)) }
                    }
                }
                r.exits.sort { $0.along < $1.along }
                r.entries.sort { $0.along < $1.along }
                out.append(r)
            }
        }
        return out
    }

    /// The node where a stand's lead-in line meets the taxilanes.
    func standNode(_ s: Int) -> Int? { graph.nearest(stands[s].line[0], within: 70) }

    // MARK: Simulation

    private func random() -> Double {
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        return Double(rng % 1_000_000) / 1_000_000
    }

    /// Fills the airport with traffic already under way, as if it had been running for a while.
    public func warmUp(seconds: Double = 600) {
        var t = 0.0
        while t < seconds { update(dt: 0.5); t += 0.5 }
    }

    /// Where the player is watching from (airport frame), so a stuck aircraft is never withdrawn
    /// in view.
    public var viewer: SIMD2<Double>?
    /// The player's aircraft (airport frame) and whether it is on the ground: traffic stops for
    /// it, and an arrival goes around when it is on that runway.
    public var player: (position: SIMD2<Double>, onGround: Bool)?
    public private(set) var goArounds = 0

    private func outOfSight(_ p: SIMD2<Double>) -> Bool {
        guard let viewer else { return true }
        return simd_distance(p, viewer) > 2_000
    }

    public func update(dt: Double) {
        clock += dt
        schedule()
        aheadCache = Dictionary(uniqueKeysWithValues: aircraft.filter { isGround($0.phase) }.map { ($0.id, ahead($0, metres: 60)) })
        // Each aircraft steps on a copy: stepping reads the others (for spacing).
        for i in aircraft.indices {
            var a = aircraft[i]
            step(&a, dt: dt, index: i)
            aircraft[i] = a
        }
        for a in aircraft where a.withdrawn {
            reserved.remove(a.stand)
            withdrawals += 1
            withdrawnPositions.append(SIMD2(a.position.x, a.position.y))
        }
        aircraft.removeAll { a in
            if a.withdrawn { return true }
            if case .climb = a.phase, simd_length(SIMD2(a.position.x, a.position.y)) > 15_000 { return true }
            return false
        }
        // Ground separation bookkeeping (tests).
        let ground = aircraft.filter { isGround($0.phase) }
        for i in ground.indices {
            for j in ground.indices where j > i {
                let d = simd_distance(SIMD2(ground[i].position.x, ground[i].position.y), SIMD2(ground[j].position.x, ground[j].position.y))
                closestOnGround = min(closestOnGround, d)
                if d < 25, closeCalls.count < 12 {
                    closeCalls.append("\(ground[i].phase)/\(ground[j].phase) \(Int(d)) m stopped \(Int(ground[i].stopped))/\(Int(ground[j].stopped))")
                }
            }
        }
    }

    private func isGround(_ p: Phase) -> Bool {
        switch p {
        case .taxiIn, .taxiOut, .pushback, .holding, .lineup: true
        default: false
        }
    }

    /// About an arrival and a departure every two minutes in all (a busy hour at either
    /// airport is around 60 to 80 movements), taking the active runways in turn.
    private func schedule() {
        guard !active.isEmpty else { return }
        if clock >= arrivalDue {
            arrivalDue = clock + 90 + random() * 60
            if aircraft.count < maxAircraft { spawnArrival(runway: active[arrivals % active.count]) }
            arrivals += 1
        }
        if clock >= departureDue {
            departureDue = clock + 90 + random() * 60
            if aircraft.count < maxAircraft { spawnDeparture(runway: active[departures % active.count]) }
            departures += 1
        }
    }
    private var arrivalDue = 0.0, departureDue = 45.0
    private var arrivals = 0, departures = 0

    private func freeStand(widebody: Bool) -> Int? {
        let options = freeStands.filter { !reserved.contains($0) && (!widebody || stands[$0].fitsWidebody) && standNode($0) != nil }
        guard !options.isEmpty else { return nil }
        return options[Int(random() * Double(options.count)) % options.count]
    }

    private func spawnArrival(runway r: Int) {
        let rw = runways[r]
        let wide = random() < 0.25
        guard let stand = freeStand(widebody: wide) else { return }
        reserved.insert(stand)
        let start = rw.point(-15_000)
        let z = rw.elevation + 15 + 15_000 * tan(3 * Double.pi / 180)
        aircraft.append(Aircraft(id: nextID, widebody: wide, seed: random(), phase: .approach, runway: r, stand: stand,
                                 position: SIMD3(start.x, start.y, z), heading: atan2(rw.direction.x, rw.direction.y),
                                 pitch: 2 * .pi / 180, speed: 72))
        nextID += 1
    }

    private func spawnDeparture(runway r: Int) {
        let wide = random() < 0.25
        guard let stand = freeStand(widebody: wide) else { return }
        reserved.insert(stand)
        let s = stands[stand]
        aircraft.append(Aircraft(id: nextID, widebody: wide, seed: random(), phase: .parked(until: clock + 20 + random() * 60),
                                 runway: r, stand: stand, position: site.onSurface(s.position), heading: s.heading, speed: 0))
        nextID += 1
    }

    private func step(_ a: inout Aircraft, dt: Double, index: Int) {
        let rw = runways[a.runway]
        switch a.phase {
        case .approach:
            let p = SIMD2(a.position.x, a.position.y) + rw.direction * a.speed * dt
            let s = rw.along(p)
            // Someone on the runway (the player): go around.
            if let pl = player, pl.onGround, s > -4_000, s < 0 {
                let d = pl.position - rw.threshold
                let cross = abs(d.x * rw.direction.y - d.y * rw.direction.x)
                let along = rw.along(pl.position)
                if cross < rw.width / 2 + 15, along > -100, along < rw.length {
                    a.phase = .climb
                    a.pitch = 6 * .pi / 180
                    goArounds += 1
                    return
                }
            }
            let touchdown = 400.0
            // On the 3 degree path through 15 m over the threshold, flaring over the last 15 m.
            var height = 15 + (-s) * tan(3 * Double.pi / 180)
            if s > -290 {
                let k = min(max((s + 290) / (touchdown + 290), 0), 1)
                height = (15 + 290 * tan(3 * Double.pi / 180)) * (1 - k) * (1 - k)
                a.pitch = (2 + 3 * k) * .pi / 180
            }
            a.position = SIMD3(p.x, p.y, site.z(p) + max(height, 0))
            if s >= touchdown {
                a.phase = .rollout
                landings += 1
            }
        case .rollout:
            a.pitch = max(a.pitch - dt * 0.05, 0)
            let s = rw.along(SIMD2(a.position.x, a.position.y))
            // The first exit with room to slow to 15 m/s at 1.8 m/s^2.
            let need = s + (a.speed * a.speed - 225) / (2 * 1.8)
            let exit = rw.exits.first { $0.along > need } ?? rw.exits.last
            a.speed = max(a.speed - 1.8 * dt, 15)
            let p = SIMD2(a.position.x, a.position.y) + rw.direction * a.speed * dt
            a.position = site.onSurface(p)
            if let exit, rw.along(p) >= exit.along - 5 {
                // Off the runway onto the taxiway, then to the gate.
                guard let goal = standNode(a.stand), let route = graph.path(from: exit.off, to: goal) else {
                    a.phase = .climb      // nowhere to go: leave (should not happen)
                    return
                }
                a.path = [graph.nodes[exit.node]] + route.map { graph.nodes[$0] } + stands[a.stand].line.dropFirst()
                a.leg = 0
                a.phase = .taxiIn
            } else if exit == nil && rw.along(p) > rw.length - 100 {
                a.phase = .climb
            }
        case .taxiIn:
            if follow(&a, dt: dt, index: index, cruise: 10) {
                a.phase = .parked(until: clock + 600 + random() * 900)
                arrivedAtGate += 1
                a.speed = 0
            }
        case .parked(let until):
            if clock >= until {
                // Push back along the lead-in line, nose still to the gate.
                a.path = Array(stands[a.stand].line.reversed())
                a.leg = 0
                a.phase = .pushback
                // An arrival that parked turns around as a departure from its own runway end.
                if !active.contains(a.runway), let r = active.first { a.runway = r }
            }
        case .pushback:
            let heading = a.heading
            if follow(&a, dt: dt, index: index, cruise: 1.5, reverse: true) {
                a.heading = heading
                let rwy = runways[a.runway]
                guard let from = standNode(a.stand), let entry = rwy.entries.first,
                      let route = graph.path(from: from, to: entry.off) else {
                    a.phase = .parked(until: clock + 120)
                    return
                }
                reserved.remove(a.stand)
                a.path = route.map { graph.nodes[$0] }
                a.leg = 0
                a.phase = .taxiOut
            }
            a.heading = heading
        case .taxiOut:
            if follow(&a, dt: dt, index: index, cruise: 9) {
                a.phase = .holding
                a.speed = 0
            }
        case .holding:
            // Wait for the runway: nothing on it, no arrival within 5 km.
            let busy = aircraft.contains { o in
                guard o.id != a.id, o.runway == a.runway else { return false }
                switch o.phase {
                case .rollout, .takeoff, .lineup: return true
                case .approach: return rw.along(SIMD2(o.position.x, o.position.y)) > -5_000
                default: return false
                }
            }
            if !busy, let entry = rw.entries.first {
                let p = rw.point(max(entry.along, 0))
                a.path = [graph.nodes[entry.node], p, p + rw.direction * 40]
                a.leg = 0
                a.phase = .lineup(until: .infinity)
            }
        case .lineup(let until):
            if until == .infinity {
                if follow(&a, dt: dt, index: index, cruise: 5) {
                    a.phase = .lineup(until: clock + 15)
                    a.speed = 0
                }
            } else if clock >= until {
                a.phase = .takeoff
            }
        case .takeoff:
            a.speed += 2.1 * dt
            a.heading = turn(a.heading, toward: atan2(rw.direction.x, rw.direction.y), rate: 0.2, dt: dt)
            let p = SIMD2(a.position.x, a.position.y) + rw.direction * a.speed * dt
            a.position = site.onSurface(p)
            if a.speed > 72 {
                a.pitch = min(a.pitch + dt * 0.05, 8 * .pi / 180)
                if a.pitch > 7 * .pi / 180 {
                    a.phase = .climb
                    takeoffs += 1
                }
            }
        case .climb:
            a.speed = min(a.speed + 1 * dt, 90)
            let p = SIMD2(a.position.x, a.position.y) + rw.direction * a.speed * dt
            a.position = SIMD3(p.x, p.y, a.position.z + 11 * dt)
        }
    }

    /// Follows the ground path at a cruise speed, slowing for corners and stopping behind traffic.
    /// Returns true at the end of the path.
    private func follow(_ a: inout Aircraft, dt: Double, index: Int, cruise: Double, reverse: Bool = false) -> Bool {
        guard a.leg + 1 < a.path.count else { return true }
        let here = SIMD2(a.position.x, a.position.y)
        var target = cruise
        // Slow for the corner at the end of this leg.
        if a.leg + 2 < a.path.count {
            let d1 = simd_normalize(a.path[a.leg + 1] - a.path[a.leg] + SIMD2(1e-9, 0))
            let d2 = simd_normalize(a.path[a.leg + 2] - a.path[a.leg + 1] + SIMD2(1e-9, 0))
            let sharp = simd_dot(d1, d2) < 0.85
            if sharp && simd_distance(here, a.path[a.leg + 1]) < 40 { target = min(target, 5) }
        }
        // Compare where each is going over the next 60 m: directly ahead, always stop (no
        // rear-ending); paths crossing, the one flying longer goes first and the other waits well
        // short; never drive at an aircraft that is standing still.
        if !reverse {
            let mine = ahead(a, metres: 60)
            let forward = SIMD2(sin(a.heading), cos(a.heading))
            // The player, on the ground near my path: always wait.
            if let pl = player, pl.onGround, simd_distance(pl.position, here) < 140,
               mine.contains(where: { simd_distance($0, pl.position) < 35 }) {
                a.speed = max(a.speed - 2 * dt, 0)
                a.position = site.onSurface(here)
                return false
            }
            let blocker = aircraft.indices.first { j in
                guard j != index, isGround(aircraft[j].phase) else { return false }
                let other = aircraft[j]
                let o = SIMD2(other.position.x, other.position.y)
                let rel = o - here
                let dist = simd_length(rel)
                guard dist < 140, dist > 0.5 else { return false }
                let theirs = aheadCache[other.id] ?? [o]
                let nearMyPath = mine.contains { simd_distance($0, o) < 30 }
                let inFront = simd_dot(rel / dist, forward) > 0.7
                // Given the right of way to break a deadlock: stop only for what is in front.
                if a.rightOfWay { return (nearMyPath && inFront && dist < 55) || mine.contains { simd_distance($0, o) < 26 } }
                if nearMyPath && (inFront || other.speed < 0.5) { return true }
                let crossing = mine.contains { p in theirs.contains { simd_distance(p, $0) < 30 } }
                return crossing && (other.id < a.id || other.rightOfWay)
            }
            if let blocker {
                target = 0
                let other = aircraft[blocker]
                let theirForward = SIMD2(sin(other.heading), cos(other.heading))
                let rel = SIMD2(other.position.x, other.position.y) - here
                // In line for the runway (behind one holding or lining up, or behind one in that
                // line, going the same way): just wait.
                let sameWay = simd_dot(forward, theirForward) > 0.3 && simd_dot(simd_normalize(rel), forward) > 0.7
                let theyQueue: Bool = {
                    switch other.phase {
                    case .holding, .lineup: return true
                    default: return other.queued
                    }
                }()
                a.queued = sameWay && theyQueue
                if !a.queued { a.stopped += dt }
                // Waiting on each other (head on, or across): the later one finds a way around.
                if a.stopped > 15, other.stopped > 5 || other.id < a.id {
                    if reroute(&a, around: SIMD2(aircraft[blocker].position.x, aircraft[blocker].position.y)) {
                        a.stopped = 0
                    } else if a.stopped > 30 && !aircraft.contains(where: { $0.rightOfWay }) {
                        // No way round: this one goes, everyone else gives way to it.
                        a.rightOfWay = true
                    } else if a.stopped > 120 && outOfSight(here) {
                        // Truly stuck with no way round: withdraw it rather than block the airport
                        // or drive through another aircraft.
                        a.withdrawn = true
                        if withdrawalNotes.count < 8 {
                            withdrawalNotes.append("\(a.phase) stuck behind \(other.phase) (theirs stopped \(Int(other.stopped)) s), \(Int(simd_length(rel))) m, headings \(Int(a.heading * 57.3)) / \(Int(other.heading * 57.3)), at \(Int(here.x)),\(Int(here.y))")
                        }
                    }
                }
            } else {
                a.stopped = 0
                a.queued = false
            }
            // The right of way lasts until it is moving freely again.
            if a.rightOfWay && blocker == nil && a.speed > 3 { a.rightOfWayFor += dt }
            if a.rightOfWayFor > 20 { a.rightOfWay = false; a.rightOfWayFor = 0 }
        }
        let accel = 1.0
        a.speed = a.speed < target ? min(a.speed + accel * dt, target) : max(a.speed - 2 * accel * dt, target)
        var remaining = a.speed * dt
        var p = here
        while remaining > 0, a.leg + 1 < a.path.count {
            let next = a.path[a.leg + 1]
            let d = simd_distance(p, next)
            if d <= remaining {
                p = next
                remaining -= d
                a.leg += 1
            } else {
                p += (next - p) / d * remaining
                remaining = 0
            }
        }
        if a.leg + 1 < a.path.count, !reverse {
            let dir = a.path[a.leg + 1] - p
            if simd_length(dir) > 0.5 { a.heading = turn(a.heading, toward: atan2(dir.x, dir.y), rate: 0.6, dt: dt) }
        }
        a.position = site.onSurface(p)
        return a.leg + 1 >= a.path.count
    }

    /// Points along an aircraft's ground path from where it is, about every 10 m.
    private func ahead(_ a: Aircraft, metres: Double) -> [SIMD2<Double>] {
        var last = SIMD2(a.position.x, a.position.y)
        var out = [last]
        var walked = 0.0, k = a.leg + 1
        while walked < metres, k < a.path.count {
            let d = simd_distance(last, a.path[k])
            let n = max(Int(d / 10), 1)
            for i in 1...n { out.append(last + (a.path[k] - last) * Double(i) / Double(n)) }
            walked += d
            last = a.path[k]
            k += 1
        }
        return out
    }

    /// A new route to the same place that keeps 70 m clear of a point; false when there is none.
    private func reroute(_ a: inout Aircraft, around obstacle: SIMD2<Double>) -> Bool {
        let here = SIMD2(a.position.x, a.position.y)
        let goal: Int?
        var tail: [SIMD2<Double>] = []
        switch a.phase {
        case .taxiIn:
            goal = standNode(a.stand)
            tail = Array(stands[a.stand].line.dropFirst())
        case .taxiOut:
            goal = runways[a.runway].entries.first?.off
        default:
            return false
        }
        guard let goal else { return false }
        let blocked = Set(graph.nodes.indices.filter { simd_distance(graph.nodes[$0], obstacle) < 70 })
        guard let start = graph.nearest(here, within: 60, where: { !blocked.contains($0) }),
              let route = graph.path(from: start, to: goal, avoiding: blocked) else { return false }
        a.path = [here] + route.map { graph.nodes[$0] } + tail
        a.leg = 0
        return true
    }

    private func turn(_ h: Double, toward target: Double, rate: Double, dt: Double) -> Double {
        var d = (target - h).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return h + max(-rate * dt, min(rate * dt, d))
    }

    /// Test helpers: ids now, ids of aircraft on the ground near a point, and how many were
    /// withdrawn near one.
    var snapshotIDs: [Int] { aircraft.map(\.id) }
    func idsNear(_ p: SIMD2<Double>, within r: Double) -> [Int] {
        aircraft.filter { isGround($0.phase) && simd_distance(SIMD2($0.position.x, $0.position.y), p) < r }.map(\.id)
    }
    func withdrawnNear(_ p: SIMD2<Double>, within r: Double) -> Int {
        withdrawnPositions.filter { simd_distance($0, p) < r }.count
    }

    /// Every aircraft now.
    public var snapshot: [Snapshot] {
        aircraft.map { a in
            let ground: Bool = {
                switch a.phase {
                case .approach, .climb: false
                default: true
                }
            }()
            return Snapshot(position: a.position, heading: a.heading, pitch: a.pitch, roll: 0, widebody: a.widebody,
                            seed: a.seed, onGround: ground)
        }
    }
}
