/// WGS84 geodesy in double precision. The renderer works camera-relative in Float (floating
/// origin), so every world position is first expressed here in ECEF doubles.

/// WGS84 reference ellipsoid constants.
public enum WGS84 {
    /// Semi-major axis, meters.
    public static let a: Double = 6_378_137.0
    /// Flattening.
    public static let f: Double = 1.0 / 298.257_223_563
    /// Semi-minor axis, meters.
    public static let b: Double = a * (1 - f)
    /// First eccentricity squared.
    public static let e2: Double = f * (2 - f)
    /// Second eccentricity squared.
    public static let ep2: Double = e2 / (1 - e2)
}

/// Geodetic position: latitude and longitude in degrees, height above the ellipsoid in meters.
public struct Geodetic: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
    public var height: Double

    public init(latitude: Double, longitude: Double, height: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.height = height
    }
}

/// Earth-centered, Earth-fixed Cartesian position in meters.
public struct ECEF: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func - (lhs: ECEF, rhs: ECEF) -> ECEF {
        ECEF(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    public var length: Double { (x * x + y * y + z * z).squareRoot() }
}

public extension Geodetic {
    /// Converts to ECEF.
    var ecef: ECEF {
        let lat = latitude.radians, lon = longitude.radians
        let sinLat = sin(lat), cosLat = cos(lat)
        let n = WGS84.a / (1 - WGS84.e2 * sinLat * sinLat).squareRoot()
        return ECEF(
            x: (n + height) * cosLat * cos(lon),
            y: (n + height) * cosLat * sin(lon),
            z: (n * (1 - WGS84.e2) + height) * sinLat
        )
    }
}

public extension ECEF {
    /// Converts to geodetic coordinates (Bowring's method with two refinement iterations;
    /// sub-millimeter error for heights between -10 km and 1,000 km).
    var geodetic: Geodetic {
        let p = (x * x + y * y).squareRoot()
        let lon = atan2(y, x)
        var lat = atan2(z, p * (1 - WGS84.e2))
        var height = 0.0
        for _ in 0..<4 {
            let sinLat = sin(lat)
            let n = WGS84.a / (1 - WGS84.e2 * sinLat * sinLat).squareRoot()
            height = p / cos(lat) - n
            lat = atan2(z, p * (1 - WGS84.e2 * n / (n + height)))
        }
        let sinLat = sin(lat)
        let n = WGS84.a / (1 - WGS84.e2 * sinLat * sinLat).squareRoot()
        // Near the poles cos(lat) -> 0; use the z-based height formula there.
        if abs(lat) > 1.4 {
            height = z / sinLat - n * (1 - WGS84.e2)
        } else {
            height = p / cos(lat) - n
        }
        return Geodetic(latitude: lat.degrees, longitude: lon.degrees, height: height)
    }
}

public extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
