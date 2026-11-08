public import FlightModel
import Foundation
import Synchronization

/// What the pilot has set on the glareshield.
public struct AutopilotSettings: Sendable, Equatable {
    /// The autopilot flies the aircraft (pitch and roll).
    public var engaged = false
    /// The autothrottle holds the selected speed.
    public var autothrottle = false
    /// Capture and track the localizer of `approach`.
    public var localizerArmed = false
    /// Capture the localizer and then the glideslope of `approach`.
    public var approachArmed = false
    /// Selected heading (degrees true), altitude (feet above sea level), vertical speed (feet per
    /// minute: its size is the climb or descent rate toward the selected altitude) and speed (knots).
    public var headingDegrees: Double = 0
    public var altitudeFeet: Double = 5_000
    public var verticalSpeedFPM: Double = 1_500
    public var speedKnots: Double = 250
    /// The approach the LOC and APPR modes fly.
    public var approach: ApproachPath?
    /// Follow `route` (NAV): direct to its first point, then leg by leg.
    public var navEngaged = false
    public var route: [NavPoint] = []

    public init() {}
}

/// A point to fly to: an airport, a navaid, a fix or a point picked on the map.
public struct NavPoint: Sendable, Equatable, Hashable {
    public var name: String
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Metres north and east of this point to another (flat around this point; fine for legs
    /// of a few hundred kilometres).
    func offset(to lat: Double, _ lon: Double) -> SIMD2<Double> {
        let r = 6_371_000.0
        return SIMD2((lat - latitude) * .pi / 180 * r, (lon - longitude) * .pi / 180 * r * cos(latitude * .pi / 180))
    }
}

/// An ILS approach: the localizer course and glidepath to a runway threshold.
public struct ApproachPath: Sendable, Equatable {
    public var name: String
    public var thresholdLatitude: Double
    public var thresholdLongitude: Double
    public var thresholdElevationFeet: Double
    /// Localizer course (degrees true), toward the runway.
    public var courseDegrees: Double
    public var glidepathDegrees: Double
    /// Height of the glidepath over the threshold (feet).
    public var thresholdCrossingHeightFeet: Double
    /// From the threshold to the localizer antenna past the far end (metres).
    public var localizerDistanceMetres: Double

    public init(name: String, thresholdLatitude: Double, thresholdLongitude: Double, thresholdElevationFeet: Double,
                courseDegrees: Double, glidepathDegrees: Double = 3, thresholdCrossingHeightFeet: Double = 50,
                localizerDistanceMetres: Double) {
        self.name = name
        self.thresholdLatitude = thresholdLatitude
        self.thresholdLongitude = thresholdLongitude
        self.thresholdElevationFeet = thresholdElevationFeet
        self.courseDegrees = courseDegrees
        self.glidepathDegrees = glidepathDegrees
        self.thresholdCrossingHeightFeet = thresholdCrossingHeightFeet
        self.localizerDistanceMetres = localizerDistanceMetres
    }

    /// Where a position is relative to the approach: metres along the course from the threshold
    /// (negative before it) and metres right of the course.
    public func offsets(latitude: Double, longitude: Double) -> (along: Double, right: Double) {
        let r = 6_371_000.0
        let north = (latitude - thresholdLatitude) * .pi / 180 * r
        let east = (longitude - thresholdLongitude) * .pi / 180 * r * cos(thresholdLatitude * .pi / 180)
        let c = courseDegrees * .pi / 180
        return (north * cos(c) + east * sin(c), -north * sin(c) + east * cos(c))
    }

    /// Localizer deviation (degrees, positive when the aircraft is right of the course).
    public func localizerDeviation(latitude: Double, longitude: Double) -> Double {
        let o = offsets(latitude: latitude, longitude: longitude)
        return atan2(o.right, localizerDistanceMetres - o.along) * 180 / .pi
    }

    /// Glidepath height (feet above sea level) at a distance along the course.
    public func pathAltitudeFeet(along: Double) -> Double {
        thresholdElevationFeet + thresholdCrossingHeightFeet - along * 3.280_84 * tan(glidepathDegrees * .pi / 180)
    }

    /// Glideslope deviation (degrees, positive when above the path), seen from where the path
    /// meets the runway.
    public func glideslopeDeviation(latitude: Double, longitude: Double, altitudeFeet: Double) -> Double {
        let o = offsets(latitude: latitude, longitude: longitude)
        let g = glidepathDegrees * .pi / 180
        let touchdown = thresholdCrossingHeightFeet / 3.280_84 / tan(g)
        let distance = max(touchdown - o.along, 30)
        let height = (altitudeFeet - thresholdElevationFeet) / 3.280_84
        return (atan2(height, distance) - g) * 180 / .pi
    }
}

/// What the autopilot is doing, for the flight mode annunciator.
public struct AutopilotStatus: Sendable, Equatable {
    public enum Lateral: String, Sendable { case off = "", heading = "HDG", nav = "NAV", localizerCapture = "LOC*", localizer = "LOC" }
    public enum Vertical: String, Sendable {
        case off = "", verticalSpeed = "V/S", altitudeCapture = "ALT*", altitude = "ALT"
        case glideslopeCapture = "G/S*", glideslope = "G/S"
    }
    public var lateral: Lateral = .off
    public var vertical: Vertical = .off
    public var autothrottle = false
    /// Deviations in dots (two dots full scale) when an approach is set.
    public var localizerDots: Double?
    public var glideslopeDots: Double?
    /// The route point NAV is flying to (index into the route) and the distance to it (metres);
    /// nil past the last point, when NAV holds the last leg's course.
    public var activeWaypoint: Int?
    public var distanceToActiveMetres: Double?

    public init() {}
}

/// Loop gains for one aircraft. Angles in degrees, rates in degrees per second.
public struct AutopilotGains: Sendable {
    public var bankLimit: Double
    public var bankPerDegreeOfHeading: Double
    /// Aileron per degree of bank error and per degree per second of roll rate.
    public var rollP: Double, rollD: Double
    /// Elevator per degree of pitch error, per degree per second of pitch rate, and the trim
    /// integrator (per degree second).
    public var pitchP: Double, pitchD: Double, pitchI: Double
    /// Pitch (degrees) per foot per minute of vertical speed error, and its integrator.
    public var pitchPerFPM: Double, pitchPerFPMSecond: Double
    public var pitchLimits: ClosedRange<Double>
    /// Throttle per knot of speed error, and its integrator.
    public var throttleP: Double, throttleI: Double
    /// Dynamic pressure (psf) the gains were set at; control power grows with it.
    public var referenceQbar: Double

    public static let c172 = AutopilotGains(bankLimit: 20, bankPerDegreeOfHeading: 1.0, rollP: 0.03, rollD: 0.012,
                                            pitchP: 0.06, pitchD: 0.025, pitchI: 0.02,
                                            pitchPerFPM: 0.004, pitchPerFPMSecond: 0.0008, pitchLimits: -10...12,
                                            throttleP: 0.04, throttleI: 0.01, referenceQbar: 34)
    public static let a320 = AutopilotGains(bankLimit: 25, bankPerDegreeOfHeading: 1.0, rollP: 0.04, rollD: 0.02,
                                            pitchP: 0.08, pitchD: 0.05, pitchI: 0.03,
                                            pitchPerFPM: 0.0025, pitchPerFPMSecond: 0.0005, pitchLimits: -10...18,
                                            throttleP: 0.03, throttleI: 0.008, referenceQbar: 200)

    public static func forModel(_ id: String) -> AutopilotGains { id == "A320" ? .a320 : .c172 }
}

/// The autopilot. Settings come from the main thread; `control` runs on the physics thread.
public final class Autopilot: FlightController {
    private struct Inner {
        var settings = AutopilotSettings()
        var status = AutopilotStatus()
        var wasEngaged = false
        var wasAutothrottle = false
        var pitchTrim = 0.0          // elevator integrator
        var pitchHold = 0.0          // pitch target integrator (degrees)
        var throttleHold = 0.0
        var localizerCaptured = false
        var glideslopeCaptured = false
        /// NAV: the leg being flown (index of its end point) and where the first leg starts.
        var leg = 0
        var legStart: NavPoint?
    }
    private let inner = Mutex(Inner())
    public let gains: AutopilotGains

    public init(gains: AutopilotGains) {
        self.gains = gains
    }

    public func update(_ settings: AutopilotSettings) {
        inner.withLock { s in
            // Disarming an approach (or changing it) lets the modes capture afresh.
            if !settings.approachArmed && !settings.localizerArmed || settings.approach != s.settings.approach {
                s.localizerCaptured = false
                s.glideslopeCaptured = false
            }
            if !settings.approachArmed { s.glideslopeCaptured = false }
            // A new route (or NAV just engaged) starts direct to its first point from wherever
            // the aircraft is.
            if settings.route != s.settings.route || (settings.navEngaged && !s.settings.navEngaged) {
                s.leg = 0
                s.legStart = nil
            }
            s.settings = settings
        }
    }

    public var settings: AutopilotSettings { inner.withLock { $0.settings } }
    public var status: AutopilotStatus { inner.withLock { $0.status } }

    public func control(state: FlightState, inputs: inout ControlInputs, dt: Double) {
        inner.withLock { s in fly(&s, state: state, inputs: &inputs, dt: dt) }
    }

    private func fly(_ s: inout Inner, state x: FlightState, inputs: inout ControlInputs, dt: Double) {
        let set = s.settings
        let g = gains
        let deg = 180 / Double.pi
        let pitch = x.pitch * deg, bank = x.roll * deg
        // Control power grows with dynamic pressure; scale the surface commands to match.
        let authority = min(max(g.referenceQbar / max(x.dynamicPressurePSF, 1), 0.4), 2.5)
        var status = AutopilotStatus()

        // Approach geometry.
        var locDeviation: Double?, gsDeviation: Double?
        if let a = set.approach {
            locDeviation = a.localizerDeviation(latitude: x.latitude, longitude: x.longitude)
            gsDeviation = a.glideslopeDeviation(latitude: x.latitude, longitude: x.longitude, altitudeFeet: x.altitudeFeet)
            // Two dots full scale: localizer 2.5 degrees, glideslope 0.7 degrees.
            status.localizerDots = locDeviation.map { $0 / 1.25 }
            status.glideslopeDots = gsDeviation.map { $0 / 0.35 }
        }

        if set.engaged && !x.onGround {
            if !s.wasEngaged {
                // Engage smoothly: hold the present attitude and start the trim where the pilot left it.
                s.pitchHold = pitch
                s.pitchTrim = inputs.pitch
            }
            // MARK: Lateral
            var targetBank: Double
            let armed = set.localizerArmed || set.approachArmed
            if armed, let a = set.approach, let dev = locDeviation {
                let o = a.offsets(latitude: x.latitude, longitude: x.longitude)
                let ahead = o.along < a.localizerDistanceMetres
                if !s.localizerCaptured && abs(dev) < 2.5 && ahead { s.localizerCaptured = true }
                if s.localizerCaptured {
                    // Track the course: aim back at it more steeply the farther off it is, flown on
                    // the ground track so the wind is corrected for.
                    let intercept = max(-30, min(30, -o.right * 0.03))
                    let desiredTrack = a.courseDegrees + intercept
                    targetBank = max(-g.bankLimit, min(g.bankLimit, wrap(desiredTrack - x.track * deg) * 1.6))
                    status.lateral = abs(dev) < 0.3 ? .localizer : .localizerCapture
                } else if let bank = navBank(&s, x, &status) {
                    targetBank = bank
                } else {
                    targetBank = headingBank(set.headingDegrees, x)
                    status.lateral = .heading
                }
            } else if let bank = navBank(&s, x, &status) {
                targetBank = bank
            } else {
                targetBank = headingBank(set.headingDegrees, x)
                status.lateral = .heading
            }
            inputs.roll = max(-1, min(1, (g.rollP * (targetBank - bank) - g.rollD * x.rollRate * deg) * authority))

            // MARK: Vertical
            var targetVS: Double
            if set.approachArmed, s.localizerCaptured, let a = set.approach, let gs = gsDeviation {
                if !s.glideslopeCaptured && abs(gs) < 0.2 { s.glideslopeCaptured = true }
                if s.glideslopeCaptured {
                    let o = a.offsets(latitude: x.latitude, longitude: x.longitude)
                    let nominal = -x.groundSpeedKnots * 101.27 * tan(a.glidepathDegrees * .pi / 180)
                    let correction = max(-600, min(600, (a.pathAltitudeFeet(along: o.along) - x.altitudeFeet) * 4))
                    targetVS = nominal + correction
                    status.vertical = abs(gs) < 0.07 ? .glideslope : .glideslopeCapture
                } else {
                    targetVS = altitudeVS(set, x, &status)
                }
            } else {
                targetVS = altitudeVS(set, x, &status)
            }
            let vsError = targetVS - x.verticalSpeedFPM
            s.pitchHold += g.pitchPerFPMSecond * vsError * dt
            s.pitchHold = min(max(s.pitchHold, g.pitchLimits.lowerBound), g.pitchLimits.upperBound)
            let targetPitch = min(max(s.pitchHold + g.pitchPerFPM * vsError, g.pitchLimits.lowerBound), g.pitchLimits.upperBound)
            let pitchError = targetPitch - pitch
            s.pitchTrim += g.pitchI * pitchError * dt * authority
            s.pitchTrim = min(max(s.pitchTrim, -0.8), 0.8)
            inputs.pitch = max(-1, min(1, (g.pitchP * pitchError - g.pitchD * x.pitchRate * deg) * authority + s.pitchTrim))
        } else {
            s.localizerCaptured = false
            s.glideslopeCaptured = false
        }
        s.wasEngaged = set.engaged && !x.onGround

        // MARK: Autothrottle
        if set.autothrottle && !x.onGround {
            if !s.wasAutothrottle { s.throttleHold = inputs.throttle }
            let error = set.speedKnots - x.indicatedAirspeedKnots
            s.throttleHold = min(max(s.throttleHold + g.throttleI * error * dt, 0), 1)
            inputs.throttle = min(max(s.throttleHold + g.throttleP * error, 0), 1)
            inputs.reverse = false
            status.autothrottle = true
        }
        s.wasAutothrottle = set.autothrottle && !x.onGround
        s.status = status
    }

    /// NAV: the bank that flies the route's active leg, or nil when NAV is off or there is no
    /// route. Steers onto the leg's course, cutting back toward it in proportion to the
    /// cross-track error, and turns onto the next leg a turn radius early.
    private func navBank(_ s: inout Inner, _ x: FlightState, _ status: inout AutopilotStatus) -> Double? {
        let route = s.settings.route
        guard s.settings.navEngaged, !route.isEmpty else { return nil }
        let here = NavPoint(name: "", latitude: x.latitude, longitude: x.longitude)
        if s.legStart == nil { s.legStart = here }
        let deg = 180 / Double.pi
        let speed = max(x.groundSpeedKnots, 60) * 0.514_444
        let radius = speed * speed / (9.81 * tan(gains.bankLimit / deg))
        while s.leg < route.count {
            let to = route[s.leg]
            let from = s.leg == 0 ? s.legStart! : route[s.leg - 1]
            let leg = to.offset(to: from.latitude, from.longitude) * -1   // from -> to, metres north/east
            let toAircraft = to.offset(to: x.latitude, x.longitude)
            let length = max((leg.x * leg.x + leg.y * leg.y).squareRoot(), 1)
            let dir = leg / length
            // Past the point (along the leg), or within a turn radius of it with a next leg: sequence.
            let beyond = toAircraft.x * dir.x + toAircraft.y * dir.y
            let distance = (toAircraft.x * toAircraft.x + toAircraft.y * toAircraft.y).squareRoot()
            let next = s.leg + 1 < route.count
            if beyond > 0 || (next && distance < max(radius * 0.8, 500)) {
                if next || beyond > 0 { s.leg += 1; continue }
            }
            status.activeWaypoint = s.leg
            status.distanceToActiveMetres = distance
            status.lateral = .nav
            return trackBank(leg: dir, offset: toAircraft, x)
        }
        // Past the last point: hold the last leg's course.
        let last = route[route.count - 1]
        let from = route.count > 1 ? route[route.count - 2] : (s.legStart ?? here)
        let leg = last.offset(to: from.latitude, from.longitude) * -1
        let length = max((leg.x * leg.x + leg.y * leg.y).squareRoot(), 1)
        status.activeWaypoint = nil
        status.distanceToActiveMetres = nil
        status.lateral = .nav
        return trackBank(leg: leg / length, offset: last.offset(to: x.latitude, x.longitude), x)
    }

    /// Bank to fly a line through a point in a direction (unit, north/east), given the aircraft's
    /// offset from that point (metres north/east).
    private func trackBank(leg dir: SIMD2<Double>, offset: SIMD2<Double>, _ x: FlightState) -> Double {
        let deg = 180 / Double.pi
        // Right of the line is positive.
        let right = -offset.x * dir.y + offset.y * dir.x
        let course = atan2(dir.y, dir.x) * deg
        let intercept = max(-45, min(45, -right * 0.015))
        let error = wrap(course + intercept - x.track * deg)
        return max(-gains.bankLimit, min(gains.bankLimit, error * 1.6))
    }

    private func headingBank(_ heading: Double, _ x: FlightState) -> Double {
        let error = wrap(heading - x.heading * 180 / .pi)
        return max(-gains.bankLimit, min(gains.bankLimit, error * gains.bankPerDegreeOfHeading))
    }

    /// Vertical speed toward the selected altitude: the selected rate, easing to zero over the
    /// last few hundred feet (4 fpm per foot), then holding.
    private func altitudeVS(_ set: AutopilotSettings, _ x: FlightState, _ status: inout AutopilotStatus) -> Double {
        let error = set.altitudeFeet - x.altitudeFeet
        let rate = max(abs(set.verticalSpeedFPM), 100)
        let vs = max(-rate, min(rate, error * 4))
        status.vertical = abs(error) < 40 ? .altitude : (abs(error * 4) < rate ? .altitudeCapture : .verticalSpeed)
        return vs
    }
}

/// An angle wrapped to -180...180 degrees.
func wrap(_ degrees: Double) -> Double {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}
