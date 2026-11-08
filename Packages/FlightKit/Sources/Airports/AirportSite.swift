public import Foundation
import simd
public import SimCore
public import Terrain

/// An airport placed in a scene: its local frame (origin at the airport reference point, at the
/// published field elevation), and one smooth surface that runways, taxiways, aprons, the
/// flattened terrain and the physics ground all share. The surface interpolates the published
/// runway-end elevations along each runway's centreline.
public struct AirportSite: Sendable {
    public let layout: AirportLayout
    public let frame: LocalFrame
    public let surface: FlattenPolygon

    public init(layout: AirportLayout) {
        self.layout = layout
        frame = LocalFrame(origin: Geodetic(latitude: layout.reference.lat, longitude: layout.reference.lon, height: layout.elevation))
        let f = frame
        // Samples every 100 m along each runway, elevations linear between its ends.
        var samples: [SIMD3<Double>] = []
        for r in layout.runways {
            let a = r.ends[0], b = r.ends[1]
            let pa = f.enu(Geodetic(latitude: a.position.lat, longitude: a.position.lon, height: a.elevation))
            let pb = f.enu(Geodetic(latitude: b.position.lat, longitude: b.position.lon, height: b.elevation))
            let n = max(2, Int(simd_distance(SIMD2(pa.x, pa.y), SIMD2(pb.x, pb.y)) / 100))
            for i in 0...n { samples.append(pa + (pb - pa) * (Double(i) / Double(n))) }
        }
        let ring = (layout.boundary.first ?? []).map { p in
            let e = f.enu(Geodetic(latitude: p.lat, longitude: p.lon, height: layout.elevation))
            return SIMD2(e.x, e.y)
        }
        surface = FlattenPolygon(ring: ring, samples: samples, margin: 150)
    }

    public static func load(_ url: URL) throws -> AirportSite { AirportSite(layout: try AirportLayout.load(url)) }

    public var overrides: [GroundOverride] { [.polygon(surface)] }

    /// ENU position (metres) of a ground point, horizontally.
    public func xy(_ p: LatLon) -> SIMD2<Double> {
        let e = frame.enu(Geodetic(latitude: p.lat, longitude: p.lon, height: layout.elevation))
        return SIMD2(e.x, e.y)
    }

    /// The airport surface's ENU height at a point.
    public func z(_ p: SIMD2<Double>) -> Double { surface.height(at: p) }

    /// A point on the airport surface, ENU.
    public func onSurface(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x, p.y, z(p)) }

    public func runwayFrame(_ r: Runway) -> RunwayFrame {
        RunwayFrame(low: xy(r.ends[0].position), high: xy(r.ends[1].position), width: r.width)
    }
}

/// A runway's own axes in the scene: `s` metres from the low end toward the high end, `t`
/// metres to the left of a pilot landing on the low end.
public struct RunwayFrame: Sendable {
    public let low: SIMD2<Double>
    public let high: SIMD2<Double>
    public let width: Double
    public let length: Double
    public let axis: SIMD2<Double>
    public let left: SIMD2<Double>

    public init(low: SIMD2<Double>, high: SIMD2<Double>, width: Double) {
        self.low = low
        self.high = high
        self.width = width
        let d = high - low
        length = (d * d).sum().squareRoot()
        axis = d / length
        left = SIMD2(-axis.y, axis.x)
    }

    public func point(_ s: Double, _ t: Double) -> SIMD2<Double> { low + axis * s + left * t }

    /// Runway-local (s, t) of a scene point.
    public func local(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let d = p - low
        return SIMD2((d * axis).sum(), (d * left).sum())
    }

    /// True heading of the low end's landing direction, degrees.
    public var heading: Double { (atan2(axis.x, axis.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) }

    public func contains(_ p: SIMD2<Double>, margin: Double = 0) -> Bool {
        let l = local(p)
        return l.x >= -margin && l.x <= length + margin && abs(l.y) <= width / 2 + margin
    }
}
