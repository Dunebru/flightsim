import Foundation
import Testing
import simd
@testable import SimCore

struct CelestialTests {
    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    static func degrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { acos(max(-1, min(1, simd_dot(a, b)))) * 180 / .pi }

    /// Polaris stands at about the latitude above the northern horizon, at any hour.
    @Test func polarisAltitudeIsTheLatitude() {
        let polaris = Celestial.equatorial(rightAscension: (2 + 31.0 / 60 + 49.1 / 3_600) * 15 * .pi / 180,
                                           declination: (89 + 15.0 / 60 + 51 / 3_600) * .pi / 180)
        for hour in [0, 6, 12, 18] {
            let m = Celestial.equatorialToLocal(latitude: 33.43, longitude: -112.01, date: Self.date("2026-06-21T\(String(format: "%02d", hour)):00:00Z"))
            let v = m * polaris
            let altitude = asin(v.z) * 180 / .pi
            #expect(abs(altitude - 33.43) < 1.1, "at \(hour)h: \(altitude)")
            #expect(v.y > 0.8, "toward north")
        }
    }

    /// A star on the meridian: Sirius due south at its transit, with the right altitude.
    @Test func siriusTransitsDueSouth() {
        let sirius = Celestial.equatorial(rightAscension: (6 + 45.0 / 60 + 8.9 / 3_600) * 15 * .pi / 180,
                                          declination: -(16 + 42.0 / 60 + 58 / 3_600) * .pi / 180)
        // Find the minute of 2026-01-15 at Phoenix when it is highest.
        var best = (alt: -2.0, east: 0.0, north: 0.0, minute: 0)
        func at(_ minute: Int) -> SIMD3<Double> {
            let d = Self.date("2026-01-15T00:00:00Z").addingTimeInterval(Double(minute) * 60)
            return Celestial.equatorialToLocal(latitude: 33.43, longitude: -112.01, date: d) * sirius
        }
        for minute in stride(from: 0, to: 1_440, by: 2) {
            let v = at(minute)
            if v.z > best.alt { best = (v.z, v.x, v.y, minute) }
        }
        let altitude = asin(best.alt) * 180 / .pi
        #expect(abs(altitude - (90 - 33.43 - 16.72)) < 0.5, "altitude \(altitude)")
        #expect(best.north < 0 && abs(best.east) < 0.02, "due south")
        // Stars rise in the east and set in the west.
        #expect(at(best.minute - 120).x > 0.3, "two hours before transit it is in the east")
        #expect(at(best.minute + 120).x < -0.3, "two hours after, in the west")
    }

    /// The 8 April 2024 total eclipse: from the point of greatest eclipse the Moon covers the Sun.
    @Test func moonCoversTheSunAtTheEclipse() {
        let d = Self.date("2024-04-08T18:17:20Z")
        let lat = 25.29, lon = -104.14
        let moon = Celestial.moon(at: d, latitude: lat, longitude: lon)
        let sun = SolarEphemeris.sunPosition(at: d, latitude: lat, longitude: lon).directionENU
        let separation = Self.degrees(moon.direction, sun)
        print(String(format: "MOON eclipse separation %.3f deg, distance %.0f km, lit %.3f", separation, moon.distanceKm, moon.illuminated))
        #expect(separation < 0.3)
        #expect(moon.illuminated < 0.01)
        #expect(moon.distanceKm > 356_000 && moon.distanceKm < 362_000, "near perigee that day")
    }

    /// Full moon of 23 April 2024 (23:49 UTC): fully lit, opposite the Sun.
    @Test func fullMoonIsOppositeTheSun() {
        let d = Self.date("2024-04-23T23:49:00Z")
        let moon = Celestial.moon(at: d, latitude: 33.43, longitude: -112.01)
        let sun = SolarEphemeris.sunPosition(at: d, latitude: 33.43, longitude: -112.01).directionENU
        #expect(moon.illuminated > 0.99)
        #expect(Self.degrees(moon.direction, sun) > 176)
    }

    @Test func readsTheCatalogueLine() {
        // Vega's line from bsc5.dat.
        let line = "7001  3Alp LyrBD+38 3238 172167 67174 699I  11510  Alp Lyr  183333.1+384126183656.3+384701 67.44 19.24 0.03   0.00 -0.01"
        let s = try! #require(CatalogStar.parseBSC5(line).first)
        #expect(abs(s.rightAscension * 180 / .pi / 15 - (18 + 36.0 / 60 + 56.3 / 3_600)) < 1e-6)
        #expect(abs(s.declination * 180 / .pi - (38 + 47.0 / 60 + 1.0 / 3_600)) < 1e-6)
        #expect(s.magnitude == 0.03 && s.colourIndex == 0.0)
    }
}
