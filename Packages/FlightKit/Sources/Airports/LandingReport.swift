import Foundation
import simd

/// How a landing went: the touchdown (sink rate, load, speed, attitude, where on the runway) and
/// the rollout (how far to taxi speed). Fed one sample per frame; reports once the aircraft has
/// touched down, and again when the rollout ends.
public struct LandingReport: Sendable, Equatable {
    public var runway: String?
    /// Sink rate at contact, feet per minute (positive down).
    public var sinkRate: Double
    /// Peak load factor in the second after contact.
    public var peakG: Double
    public var airspeedKnots: Double
    public var pitchDegrees: Double
    public var bankDegrees: Double
    /// Heading minus track at contact, degrees (crab not taken out).
    public var crabDegrees: Double
    /// Metres past the landing threshold, and left (+) or right (-) of the centreline.
    public var pastThreshold: Double?
    public var offCentreline: Double?
    /// Metres from touchdown to taxi speed (30 kt), once reached.
    public var rollout: Double?

    public enum Grade: String, Sendable { case butter = "Butter", smooth = "Smooth", firm = "Firm", hard = "Hard", veryHard = "Very hard" }
    public var grade: Grade {
        switch sinkRate {
        case ..<120: .butter
        case ..<240: .smooth
        case ..<420: .firm
        case ..<600: .hard
        default: .veryHard
        }
    }

    /// In the touchdown zone: the first 900 m past the threshold, not short of it.
    public var inTouchdownZone: Bool? { pastThreshold.map { $0 >= 0 && $0 <= 900 } }
}

/// Watches a flight for touchdowns.
public struct LandingMonitor: Sendable {
    public struct Sample: Sendable {
        public var time: Double
        /// Airport frame, metres.
        public var position: SIMD2<Double>
        public var heightAboveGroundFeet: Double
        public var verticalSpeedFPM: Double
        public var onGround: Bool
        public var groundSpeedKnots: Double
        public var airspeedKnots: Double
        public var loadFactor: Double
        public var pitch: Double, roll: Double, heading: Double, track: Double   // radians

        public init(time: Double, position: SIMD2<Double>, heightAboveGroundFeet: Double, verticalSpeedFPM: Double, onGround: Bool,
                    groundSpeedKnots: Double, airspeedKnots: Double, loadFactor: Double, pitch: Double, roll: Double, heading: Double, track: Double) {
            self.time = time; self.position = position; self.heightAboveGroundFeet = heightAboveGroundFeet
            self.verticalSpeedFPM = verticalSpeedFPM; self.onGround = onGround; self.groundSpeedKnots = groundSpeedKnots
            self.airspeedKnots = airspeedKnots; self.loadFactor = loadFactor; self.pitch = pitch; self.roll = roll
            self.heading = heading; self.track = track
        }
    }

    private let runways: [(ident: String, frame: RunwayFrame, threshold: Double, reversed: Bool)]
    /// Recent airborne samples (the last half second), for the sink rate at contact.
    private var recent: [Sample] = []
    private var airborneSince: Double?
    private var touchdown: (time: Double, position: SIMD2<Double>)?
    public private(set) var report: LandingReport?

    /// `site`: the airport whose runways are checked (nil: no runway placement).
    public init(site: AirportSite?) {
        var r: [(String, RunwayFrame, Double, Bool)] = []
        if let site {
            for rw in site.layout.runways where rw.ends.count == 2 {
                let f = site.runwayFrame(rw)
                // Each end as its own landing direction: the frame from that end.
                r.append((rw.ends[0].ident, f, rw.ends[0].displacedThreshold, false))
                r.append((rw.ends[1].ident, RunwayFrame(low: f.high, high: f.low, width: f.width), rw.ends[1].displacedThreshold, true))
            }
        }
        runways = r.map { (ident: $0.0, frame: $0.1, threshold: $0.2, reversed: $0.3) }
    }

    /// Feeds one sample; returns a report when one is new or updated (touchdown, then rollout).
    public mutating func update(_ s: Sample) -> LandingReport? {
        if !s.onGround {
            if airborneSince == nil { airborneSince = s.time }
            recent.append(s)
            recent.removeAll { s.time - $0.time > 0.5 }
            if s.heightAboveGroundFeet > 50 { touchdown = nil }
            return nil
        }
        defer { if s.onGround { recent.removeAll() } }
        // A touchdown: on the ground after at least five seconds in the air.
        if let since = airborneSince, s.time - since > 5 {
            airborneSince = nil
            let sink = max(0, -(recent.map(\.verticalSpeedFPM).min() ?? s.verticalSpeedFPM))
            var crab = (s.heading - s.track) * 180 / .pi
            crab = (crab + 540).truncatingRemainder(dividingBy: 360) - 180
            var r = LandingReport(runway: nil, sinkRate: sink, peakG: s.loadFactor, airspeedKnots: s.airspeedKnots,
                                  pitchDegrees: s.pitch * 180 / .pi, bankDegrees: s.roll * 180 / .pi, crabDegrees: crab)
            // The runway landed on: the one containing the point whose direction is nearest the
            // aircraft's heading.
            let along = SIMD2(sin(s.heading), cos(s.heading))
            if let best = runways.filter({ $0.frame.contains(s.position, margin: 30) })
                .max(by: { ($0.frame.axis * along).sum() < ($1.frame.axis * along).sum() }) {
                let l = best.frame.local(s.position)
                r.runway = best.ident
                r.pastThreshold = l.x - best.threshold
                r.offCentreline = l.y
            }
            report = r
            touchdown = (s.time, s.position)
            return r
        }
        airborneSince = nil
        guard var r = report, let td = touchdown else { return nil }
        if s.time - td.time < 1 {
            if s.loadFactor > r.peakG { r.peakG = s.loadFactor; report = r; return r }
            return nil
        }
        if r.rollout == nil, s.groundSpeedKnots < 30 {
            r.rollout = simd_distance(s.position, td.position)
            report = r
            touchdown = nil
            return r
        }
        return nil
    }
}
