public import Foundation

/// Sun position as seen from a point on Earth.
public struct SunPosition: Sendable, Hashable {
    /// Degrees clockwise from true north.
    public var azimuth: Double
    /// Geometric elevation above the horizon, degrees.
    public var elevation: Double
    /// Elevation including atmospheric refraction, degrees. This is where the sun appears.
    public var apparentElevation: Double

    /// Unit vector toward the sun in a local East-North-Up frame (uses apparent elevation).
    public var directionENU: SIMD3<Double> {
        let el = apparentElevation.radians, az = azimuth.radians
        return SIMD3(cos(el) * sin(az), cos(el) * cos(az), sin(el))
    }
}

/// Low-cost solar ephemeris: the NOAA Solar Calculator equations (after Meeus, "Astronomical
/// Algorithms"). Accurate to roughly 0.01 degrees for 1950-2050, which is far below what the
/// eye can see in a sky render. Validated against NREL's SPA in the tests.
public enum SolarEphemeris {
    public static func sunPosition(at date: Date, latitude: Double, longitude: Double) -> SunPosition {
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525  // Julian centuries since J2000

        let meanLongitude = (280.466_46 + t * (36_000.769_83 + t * 0.000_303_2))
            .truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.529_11 + t * (35_999.050_29 - 0.000_153_7 * t)
        let eccentricity = 0.016_708_634 - t * (0.000_042_037 + 0.000_000_126_7 * t)
        let m = meanAnomaly.radians
        let equationOfCenter = sin(m) * (1.914_602 - t * (0.004_817 + 0.000_014 * t))
            + sin(2 * m) * (0.019_993 - 0.000_101 * t)
            + sin(3 * m) * 0.000_289
        let trueLongitude = meanLongitude + equationOfCenter
        let omega = (125.04 - 1_934.136 * t).radians
        let apparentLongitude = (trueLongitude - 0.005_69 - 0.004_78 * sin(omega)).radians

        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.000_59 - t * 0.001_813))) / 60) / 60
        let obliquity = (meanObliquity + 0.002_56 * cos(omega)).radians
        let declination = asin(sin(obliquity) * sin(apparentLongitude))

        let y = pow(tan(obliquity / 2), 2)
        let l0 = meanLongitude.radians
        let equationOfTimeMinutes = 4 * (
            y * sin(2 * l0)
            - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0)
            - 1.25 * eccentricity * eccentricity * sin(2 * m)
        ).degrees

        let secondsOfDay = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let minutesUTC = (secondsOfDay < 0 ? secondsOfDay + 86_400 : secondsOfDay) / 60
        var trueSolarTime = (minutesUTC + equationOfTimeMinutes + 4 * longitude)
            .truncatingRemainder(dividingBy: 1_440)
        if trueSolarTime < 0 { trueSolarTime += 1_440 }
        let hourAngle = (trueSolarTime / 4 - 180).radians

        let phi = latitude.radians
        let cosZenith = min(max(sin(phi) * sin(declination) + cos(phi) * cos(declination) * cos(hourAngle), -1), 1)
        let elevation = 90 - acos(cosZenith).degrees
        // Azimuth measured from south toward west, then rotated to "from north, clockwise".
        let azimuthFromSouth = atan2(sin(hourAngle), cos(hourAngle) * sin(phi) - tan(declination) * cos(phi))
        var azimuth = (azimuthFromSouth.degrees + 180).truncatingRemainder(dividingBy: 360)
        if azimuth < 0 { azimuth += 360 }

        return SunPosition(
            azimuth: azimuth,
            elevation: elevation,
            apparentElevation: elevation + refraction(elevation: elevation)
        )
    }

    /// Atmospheric refraction in degrees (NOAA approximation, standard atmosphere). Not applied
    /// once the whole solar disk is below the horizon (elevation < -0.833 degrees), matching SPA.
    static func refraction(elevation e: Double) -> Double {
        guard e > -0.833, e <= 85 else { return 0 }
        let arcseconds: Double
        if e > 5 {
            let te = tan(e.radians)
            arcseconds = 58.1 / te - 0.07 / pow(te, 3) + 0.000_086 / pow(te, 5)
        } else if e > -0.575 {
            arcseconds = 1_735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711)))
        } else {
            arcseconds = -20.772 / tan(e.radians)
        }
        return arcseconds / 3_600
    }
}
