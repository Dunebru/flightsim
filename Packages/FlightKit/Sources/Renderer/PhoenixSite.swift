import Foundation
public import SimCore
public import Terrain

/// Phoenix Sky Harbor, runway 8/26, from OurAirports (public domain): runway 08 end
/// 33.44090 N 112.02999 W at 1,113 ft, runway 26 end 33.44080 N 111.99200 W at 1,135 ft.
/// The scene origin is the midpoint, at the mean of the two end elevations; the runway's true
/// heading and gradient come from the same two points (WGS84 inverse geodesic, PROJ `geod`).
/// Replaced by generated airports in M5.
public enum PhoenixSite {
    public static let origin = Geodetic(latitude: 33.44085076, longitude: -112.01099777, height: 342.60)
    /// True heading of runway 08, degrees.
    public static let runwayHeading = 90.168
    /// Rise per metre toward the 26 end (6.7 m over the runway's length).
    public static let runwayGradient = 0.0019
    public static let runwayLength = 3_502.0
    public static let runwayWidth = 45.7

    /// Unit vector along the runway toward the 26 end, ENU.
    public static var runwayAxis: SIMD2<Double> {
        let a = (90 - runwayHeading) * .pi / 180
        return SIMD2(cos(a), sin(a))
    }

    /// A point on the centreline, `s` metres from the midpoint toward the 26 end, on the
    /// pavement.
    public static func centreline(_ s: Double) -> SIMD3<Double> {
        let p = runwayAxis * s
        return SIMD3(p.x, p.y, runwayGradient * s)
    }

    /// Ground held flat (along the runway's slope) under the pavement, its shoulders and the
    /// blast pads, so terrain never covers what is drawn.
    public static var flatten: [GroundOverride] {
        [.area(FlattenArea(centre: .zero, halfLength: runwayLength / 2 + 100, halfWidth: 75,
                           angle: (90 - runwayHeading) * .pi / 180, height: 0, gradient: runwayGradient))]
    }
}
