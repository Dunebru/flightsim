public import Foundation
public import SimCore
public import Terrain
import simd

/// Where a flight starts at an airport.
public enum StartSpot: Codable, Hashable, Sendable {
    /// Lined up at the start of a runway (end designator, "08").
    case runway(String)
    /// On a 3 degree approach, 3 nm from the runway's threshold.
    case final(String)
    /// Parked at a stand (its ref, "C12").
    case stand(String)

    public var label: String {
        switch self {
        case .runway(let id): "Runway \(id)"
        case .final(let id): "3 nm final \(id)"
        case .stand(let ref): "Gate \(ref)"
        }
    }
}

/// A resolved start: where (airport frame, on the surface), which way, and for an approach
/// the altitude above mean sea level to fly at.
public struct StartPlacement: Sendable {
    public var position: SIMD3<Double>
    /// True heading, degrees.
    public var heading: Double
    /// Airborne starts: altitude above mean sea level, metres. nil: on the ground.
    public var altitude: Double?

    public init(position: SIMD3<Double>, heading: Double, altitude: Double?) {
        self.position = position
        self.heading = heading
        self.altitude = altitude
    }
}

extension AirportLayout {
    /// Runway ends, finals for every end, then stands with a ref in natural order.
    public var startSpots: [StartSpot] {
        let ends = runways.flatMap(\.ends).map(\.ident).sorted()
        let refs = stands.compactMap(\.ref).filter { !$0.isEmpty }
        let unique = Array(Set(refs)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ends.map { .runway($0) } + ends.map { .final($0) } + unique.map { .stand($0) }
    }

    /// The airport's time zone, for the time-of-day control.
    public var timeZone: TimeZone {
        TimeZone(identifier: ["KPHX": "America/Phoenix", "KLAX": "America/Los_Angeles"][icao] ?? "UTC") ?? .gmt
    }
}

extension AirportSite {
    public var startSpots: [StartSpot] { layout.startSpots }

    /// The runway and end index for an end designator.
    func runwayEnd(_ ident: String) -> (Runway, Int)? {
        for r in layout.runways { if let i = r.ends.firstIndex(where: { $0.ident == ident }) { return (r, i) } }
        return nil
    }

    public func placement(_ spot: StartSpot) -> StartPlacement? {
        switch spot {
        case .runway(let id):
            guard let (r, k) = runwayEnd(id) else { return nil }
            let f = runwayFrame(r)
            // 30 m in from the pavement end, on the centreline, facing down the runway.
            let s = k == 0 ? 30 : f.length - 30
            let heading = k == 0 ? f.heading : (f.heading + 180).truncatingRemainder(dividingBy: 360)
            return StartPlacement(position: onSurface(f.point(s, 0)), heading: heading, altitude: nil)
        case .final(let id):
            guard let (r, k) = runwayEnd(id) else { return nil }
            let f = runwayFrame(r)
            let end = r.ends[k]
            let threshold = k == 0 ? end.displacedThreshold : f.length - end.displacedThreshold
            let out = 5_556.0
            let s = k == 0 ? threshold - out : threshold + out
            let heading = k == 0 ? f.heading : (f.heading + 180).truncatingRemainder(dividingBy: 360)
            let angle = (end.glidePathAngle ?? 3) * .pi / 180
            // Threshold elevation: the published end elevation, plus the runway's slope to a
            // displaced threshold.
            let other = r.ends[1 - k]
            let thresholdElevation = end.elevation + (other.elevation - end.elevation) * (end.displacedThreshold / f.length)
            let altitude = thresholdElevation + (end.thresholdCrossingHeight ?? 15) + out * tan(angle)
            let p = f.point(s, 0)
            return StartPlacement(position: SIMD3(p.x, p.y, z(p)), heading: heading, altitude: altitude)
        case .stand(let ref):
            guard let st = layout.stands.first(where: { $0.ref == ref }) else { return nil }
            let p = xy(st.position)
            var heading = 0.0
            if st.line.count >= 2 {
                let a = xy(st.line[st.line.count - 2]), b = xy(st.line[st.line.count - 1])
                heading = (atan2(b.x - a.x, b.y - a.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            }
            return StartPlacement(position: onSurface(p), heading: heading, altitude: nil)
        }
    }

    /// The control tower's cab (airport frame), when the tower is mapped.
    public var towerCab: SIMD3<Double>? {
        guard let t = layout.buildings.filter({ $0.kind == .tower }).max(by: { $0.height < $1.height }) else { return nil }
        let ring = t.outer.map(xy)
        let c = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
        return SIMD3(c.x, c.y, z(c) + t.height * 0.93)
    }

    /// Ground overrides placed in another scene frame (another airport's), so every airport
    /// flattens the terrain correctly whichever airport the scene is centred on.
    public func overrides(in scene: LocalFrame) -> [GroundOverride] {
        if scene == frame { return overrides }
        func toScene(_ p: SIMD3<Double>) -> SIMD3<Double> { scene.enu(frame.geodetic(p)) }
        let ring = surface.ring.map { p -> SIMD2<Double> in let q = toScene(SIMD3(p.x, p.y, 0)); return SIMD2(q.x, q.y) }
        let samples = surface.samples.map(toScene)
        return [.polygon(FlattenPolygon(ring: ring, samples: samples, margin: surface.margin))]
    }

    /// An airport-frame point in another scene frame.
    public func position(_ p: SIMD3<Double>, in scene: LocalFrame) -> SIMD3<Double> {
        scene == frame ? p : scene.enu(frame.geodetic(p))
    }
}
