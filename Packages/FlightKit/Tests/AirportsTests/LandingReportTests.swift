import Foundation
import Testing
import simd
@testable import Airports

/// A synthetic approach to KPHX 08 on a 3 degree path, touching down 4 m left of the
/// centreline at 180 fpm after a flare: the report names the runway, the place, a smooth
/// grade, and the rollout once the aircraft is down to 30 kt.
struct LandingReportTests {
    @Test func reportsTouchdownAndRollout() throws {
        let site = try AirportGeometryTests.site("KPHX")
        let rw = try #require(site.layout.runways.first { $0.ends[0].ident == "08" })
        let f = site.runwayFrame(rw)
        let threshold = rw.ends[0].displacedThreshold
        var monitor = LandingMonitor(site: site)
        let heading = atan2(f.axis.x, f.axis.y)
        var reports: [LandingReport] = []
        var t = 0.0, touchdownS = 0.0, touchdownT = 0.0
        // 20 s of final at 140 kt (72 m/s), descending at 700 fpm, flaring to 180 fpm.
        var s = threshold - 72 * 20
        var height = 72 * 20 * tan(3 * Double.pi / 180) / 0.3048
        while height > 0 {
            let flare = height < 30
            let vs = flare ? -180.0 : -700.0
            height += vs / 60 / 60
            s += 72.0 / 60
            t += 1.0 / 60
            let sample = LandingMonitor.Sample(time: t, position: f.point(s, 4), heightAboveGroundFeet: max(height, 0), verticalSpeedFPM: vs,
                                               onGround: height <= 0, groundSpeedKnots: 140, airspeedKnots: 140, loadFactor: 1.0,
                                               pitch: 0.06, roll: 0.01, heading: heading, track: heading)
            if let r = monitor.update(sample) { reports.append(r) }
            if height <= 0 { touchdownS = s; touchdownT = t }
        }
        // Rollout: decelerating at 2 m/s/s from 72 m/s.
        var v = 72.0
        while v > 10 {
            v -= 2.0 / 60
            s += v / 60
            t += 1.0 / 60
            let sample = LandingMonitor.Sample(time: t, position: f.point(s, 4), heightAboveGroundFeet: 0, verticalSpeedFPM: 0, onGround: true,
                                               groundSpeedKnots: v / 0.514_444, airspeedKnots: v / 0.514_444, loadFactor: t - touchdownT < 0.5 ? 1.25 : 1.0,
                                               pitch: 0, roll: 0, heading: heading, track: heading)
            if let r = monitor.update(sample) { reports.append(r) }
        }
        let touchdown = try #require(reports.first)
        print("landing \(touchdown)")
        #expect(touchdown.runway == "08")
        #expect(abs(touchdown.sinkRate - 180) < 1)
        #expect(touchdown.grade == .smooth)
        #expect(abs((touchdown.pastThreshold ?? 0) - (touchdownS - threshold)) < 2)
        #expect(abs((touchdown.offCentreline ?? 0) - 4) < 0.5)
        #expect(touchdown.inTouchdownZone == true)
        let last = try #require(reports.last)
        #expect(last.peakG > 1.2)
        // 72 m/s to 15.4 m/s (30 kt) at 2 m/s/s: (72^2 - 15.4^2) / 4 = 1237 m.
        let rollout = try #require(last.rollout)
        #expect(abs(rollout - 1237) < 15, "\(rollout)")
    }
}
