public import Airports
public import Autopilot
public import FlightModel
import Foundation

/// The ILS approaches at an airport, and which one the aircraft is lined up for.
public nonisolated enum ApproachCatalog {
    /// The approach the aircraft is lined up for: ahead of it, within 45 km, roughly toward the
    /// runway, the smallest localizer deviation.
    public static func approachAhead(_ approaches: [ApproachPath], state s: FlightState) -> ApproachPath? {
        let heading = s.heading * 180 / .pi
        return approaches.compactMap { a -> (ApproachPath, Double)? in
            let o = a.offsets(latitude: s.latitude, longitude: s.longitude)
            guard o.along > -45_000, o.along < 0 else { return nil }
            var turn = (a.courseDegrees - heading).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn -= 360 }
            if turn < -180 { turn += 360 }
            guard abs(turn) < 100 else { return nil }
            let dev = abs(a.localizerDeviation(latitude: s.latitude, longitude: s.longitude))
            return dev < 35 ? (a, dev) : nil
        }.min { $0.1 < $1.1 }?.0
    }

    /// ILS approaches from the airport's runway ends: threshold (past any displacement), the
    /// course toward the far end, the published glidepath and crossing height, and the localizer
    /// antenna about 300 m beyond the far end.
    public static func approaches(at site: AirportSite) -> [ApproachPath] {
        site.layout.runways.flatMap { rw -> [ApproachPath] in
            guard rw.ends.count == 2 else { return [] }
            return (0..<2).compactMap { i -> ApproachPath? in
                let end = rw.ends[i], far = rw.ends[1 - i]
                guard end.ils else { return nil }
                let r = 6_371_000.0
                let lat0 = end.position.lat * .pi / 180
                let north = (far.position.lat - end.position.lat) * .pi / 180 * r
                let east = (far.position.lon - end.position.lon) * .pi / 180 * r * cos(lat0)
                let length = (north * north + east * east).squareRoot()
                guard length > 100 else { return nil }
                let f = end.displacedThreshold / length
                let lat = end.position.lat + (far.position.lat - end.position.lat) * f
                let lon = end.position.lon + (far.position.lon - end.position.lon) * f
                let elevation = end.elevation + (far.elevation - end.elevation) * f
                var course = atan2(east, north) * 180 / .pi
                if course < 0 { course += 360 }
                return ApproachPath(name: "ILS \(end.ident)", thresholdLatitude: lat, thresholdLongitude: lon,
                                    thresholdElevationFeet: elevation * 3.280_84, courseDegrees: course,
                                    glidepathDegrees: end.glidePathAngle ?? 3,
                                    thresholdCrossingHeightFeet: (end.thresholdCrossingHeight ?? 15) * 3.280_84,
                                    localizerDistanceMetres: length - end.displacedThreshold + 300)
            }
        }
    }
}
