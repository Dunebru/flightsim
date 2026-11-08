public import Foundation
public import simd

/// The night sky's geometry: sidereal time, stars from their catalogue positions, and the Moon
/// from a low-precision lunar theory (the Astronomical Almanac's, good to about 0.3 degrees).
/// Directions are unit vectors in the local frame: x east, y north, z up.
public enum Celestial {
    static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }

    /// Greenwich mean sidereal time, radians (Meeus 12.4).
    public static func greenwichSiderealTime(_ date: Date) -> Double {
        let jd = julianDay(date)
        let t = (jd - 2_451_545) / 36_525
        var deg = 280.460_618_37 + 360.985_647_366_29 * (jd - 2_451_545) + 0.000_387_933 * t * t - t * t * t / 38_710_000
        deg = deg.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        return deg * .pi / 180
    }

    /// Rotation from equatorial coordinates (x toward the vernal equinox, z to the celestial north
    /// pole) to the local east-north-up frame at a place and time.
    public static func equatorialToLocal(latitude: Double, longitude: Double, date: Date) -> simd_double3x3 {
        let lst = greenwichSiderealTime(date) + longitude * .pi / 180
        let phi = latitude * .pi / 180
        // A direction with hour angle H = LST - RA and declination d:
        // east = -cos d sin H, north = cos phi sin d - sin phi cos d cos H, up = sin phi sin d + cos phi cos d cos H.
        // As a matrix on (cos d cos RA, cos d sin RA, sin d):
        let cl = cos(lst), sl = sin(lst), cp = cos(phi), sp = sin(phi)
        return simd_double3x3(rows: [
            SIMD3(-sl, cl, 0),
            SIMD3(-sp * cl, -sp * sl, cp),
            SIMD3(cp * cl, cp * sl, sp),
        ])
    }

    /// Unit vector in equatorial coordinates for a right ascension and declination (radians).
    public static func equatorial(rightAscension ra: Double, declination dec: Double) -> SIMD3<Double> {
        SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
    }

    /// The Moon seen from a place: direction (local, corrected for parallax), its distance (km)
    /// and the fraction of its disk lit.
    public static func moon(at date: Date, latitude: Double, longitude: Double) -> (direction: SIMD3<Double>, distanceKm: Double, illuminated: Double) {
        let t = (julianDay(date) - 2_451_545) / 36_525
        func s(_ a: Double, _ b: Double) -> Double { sin((a + b * t) * .pi / 180) }
        func c(_ a: Double, _ b: Double) -> Double { cos((a + b * t) * .pi / 180) }
        let lambda = 218.32 + 481_267.881 * t + 6.29 * s(134.9, 477_198.85) - 1.27 * s(259.2, -413_335.38)
            + 0.66 * s(235.7, 890_534.23) + 0.21 * s(269.9, 954_397.70) - 0.19 * s(357.5, 35_999.05) - 0.11 * s(186.6, 966_404.05)
        let beta = 5.13 * s(93.3, 483_202.03) + 0.28 * s(228.2, 960_400.87) - 0.28 * s(318.3, 6_003.18) - 0.17 * s(217.6, -407_332.20)
        let parallax = 0.9508 + 0.0518 * c(134.9, 477_198.85) + 0.0095 * c(259.2, -413_335.38)
            + 0.0078 * c(235.7, 890_534.23) + 0.0028 * c(269.9, 954_397.70)
        let l = lambda * .pi / 180, b = beta * .pi / 180
        let ecliptic = SIMD3(cos(b) * cos(l), cos(b) * sin(l), sin(b))
        let eps = (23.439_291 - 0.013_004_2 * t) * .pi / 180
        let equatorial = SIMD3(ecliptic.x, ecliptic.y * cos(eps) - ecliptic.z * sin(eps), ecliptic.y * sin(eps) + ecliptic.z * cos(eps))
        let distance = 6_378.14 / sin(parallax * .pi / 180)
        // Topocentric: the Moon is close enough that the observer's offset from the Earth's
        // centre moves it by up to a degree.
        let m = equatorialToLocal(latitude: latitude, longitude: longitude, date: date)
        let geocentric = m * equatorial * distance
        let observer = SIMD3(0, 0, 6_378.14)          // the observer, from the centre, in local axes
        let topocentric = simd_normalize(geocentric - observer)
        // Phase from the Sun's direction as seen from here (the Sun is far enough not to matter).
        let sun = SolarEphemeris.sunPosition(at: date, latitude: latitude, longitude: longitude).directionENU
        let elongation = acos(max(-1, min(1, simd_dot(simd_normalize(geocentric), sun))))
        let illuminated = (1 - cos(elongation)) / 2
        return (topocentric, distance, illuminated)
    }
}

/// A star from the Yale Bright Star Catalogue: J2000 position, visual magnitude, colour index.
public struct CatalogStar: Sendable, Equatable {
    public var rightAscension: Double    // radians
    public var declination: Double       // radians
    public var magnitude: Double
    public var colourIndex: Double       // B - V

    public init(rightAscension: Double, declination: Double, magnitude: Double, colourIndex: Double) {
        self.rightAscension = rightAscension
        self.declination = declination
        self.magnitude = magnitude
        self.colourIndex = colourIndex
    }

    /// Reads bsc5.dat (fixed columns: J2000 RA at 76-83, declination 84-90, V at 103-107,
    /// B-V at 110-114). Entries without a position (novae, clusters removed) are skipped.
    public static func parseBSC5(_ text: String) -> [CatalogStar] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> CatalogStar? in
            let a = Array(line.utf8)
            guard a.count >= 107 else { return nil }
            func field(_ from: Int, _ to: Int) -> String {
                String(decoding: a[(from - 1)..<min(to, a.count)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
            guard let rh = Double(field(76, 77)), let rm = Double(field(78, 79)), let rs = Double(field(80, 83)),
                  let dd = Double(field(85, 86)), let dm = Double(field(87, 88)), let ds = Double(field(89, 90)),
                  let v = Double(field(103, 107)) else { return nil }
            let sign = field(84, 84) == "-" ? -1.0 : 1.0
            let ra = (rh + rm / 60 + rs / 3_600) * 15 * .pi / 180
            let dec = sign * (dd + dm / 60 + ds / 3_600) * .pi / 180
            let bv = a.count >= 114 ? Double(field(110, 114)) ?? 0.6 : 0.6
            return CatalogStar(rightAscension: ra, declination: dec, magnitude: v, colourIndex: bv)
        }
    }
}
