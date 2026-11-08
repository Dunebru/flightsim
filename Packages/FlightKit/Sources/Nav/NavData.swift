public import Foundation

/// A radio navigation aid: VOR, VORTAC, VOR/DME, NDB, TACAN, DME.
public struct Navaid: Codable, Sendable, Hashable {
    public var id: String
    public var type: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// MHz for VORs, kHz for NDBs; nil for TACAN-only and DME without a paired frequency.
    public var frequency: Double?

    public init(id: String, type: String, name: String, latitude: Double, longitude: Double, frequency: Double?) {
        self.id = id
        self.type = type
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.frequency = frequency
    }

    public var isVOR: Bool { type.hasPrefix("VOR") }
    public var isNDB: Bool { type.hasPrefix("NDB") }
}

/// A named point in space (an intersection or RNAV waypoint).
public struct Fix: Codable, Sendable, Hashable {
    public var id: String
    public var latitude: Double
    public var longitude: Double

    public init(id: String, latitude: Double, longitude: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The navaids and fixes of a region (from the FAA's NASR subscription, cooked by
/// `flight-tools nav-import`).
public struct NavData: Codable, Sendable {
    public var source: String
    public var navaids: [Navaid]
    public var fixes: [Fix]

    public init(source: String, navaids: [Navaid], fixes: [Fix]) {
        self.source = source
        self.navaids = navaids
        self.fixes = fixes
    }

    public static func load(_ url: URL) throws -> NavData {
        try JSONDecoder().decode(NavData.self, from: Data(contentsOf: url))
    }

    /// Navaids and fixes inside a box, nearest the middle first, at most `limit` of each.
    public func inside(south: Double, west: Double, north: Double, east: Double, limit: Int = 150) -> (navaids: [Navaid], fixes: [Fix]) {
        let cLat = (south + north) / 2, cLon = (west + east) / 2
        func inBox(_ lat: Double, _ lon: Double) -> Bool { lat >= south && lat <= north && lon >= west && lon <= east }
        func d(_ lat: Double, _ lon: Double) -> Double {
            let x = (lon - cLon) * cos(cLat * .pi / 180), y = lat - cLat
            return x * x + y * y
        }
        let n = navaids.filter { inBox($0.latitude, $0.longitude) }.sorted { d($0.latitude, $0.longitude) < d($1.latitude, $1.longitude) }
        let f = fixes.filter { inBox($0.latitude, $0.longitude) }.sorted { d($0.latitude, $0.longitude) < d($1.latitude, $1.longitude) }
        return (Array(n.prefix(limit)), Array(f.prefix(limit)))
    }

    /// A navaid or fix by identifier, the one nearest a position when several share it.
    public func find(_ id: String, near latitude: Double, _ longitude: Double) -> (name: String, latitude: Double, longitude: Double)? {
        let key = id.uppercased()
        func d(_ lat: Double, _ lon: Double) -> Double {
            let x = (lon - longitude) * cos(latitude * .pi / 180), y = lat - latitude
            return x * x + y * y
        }
        let candidates = navaids.filter { $0.id == key }.map { ($0.id, $0.latitude, $0.longitude) }
            + fixes.filter { $0.id == key }.map { ($0.id, $0.latitude, $0.longitude) }
        return candidates.min { d($0.1, $0.2) < d($1.1, $1.2) }.map { (name: $0.0, latitude: $0.1, longitude: $0.2) }
    }
}
