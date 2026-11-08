/// A local East-North-Up frame tangent to the WGS84 ellipsoid at an origin. The renderer draws
/// in this frame (metres); the flight model works in latitude, longitude and altitude. This is
/// the one place the two meet.
public struct LocalFrame: Sendable, Equatable {
    public let origin: Geodetic
    private let originECEF: ECEF
    private let east: SIMD3<Double>
    private let north: SIMD3<Double>
    private let up: SIMD3<Double>

    public init(origin: Geodetic) {
        self.origin = origin
        originECEF = origin.ecef
        let lat = origin.latitude.radians, lon = origin.longitude.radians
        east = SIMD3(-sin(lon), cos(lon), 0)
        north = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
        up = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    /// Geodetic position -> local ENU metres.
    public func enu(_ g: Geodetic) -> SIMD3<Double> {
        let e = g.ecef - originECEF
        let d = SIMD3(e.x, e.y, e.z)
        return SIMD3((d * east).sum(), (d * north).sum(), (d * up).sum())
    }

    /// Local ENU metres -> geodetic position.
    public func geodetic(_ p: SIMD3<Double>) -> Geodetic {
        let d = east * p.x + north * p.y + up * p.z
        return ECEF(x: originECEF.x + d.x, y: originECEF.y + d.y, z: originECEF.z + d.z).geodetic
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
