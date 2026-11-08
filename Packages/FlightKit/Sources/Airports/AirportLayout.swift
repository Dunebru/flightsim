public import Foundation

/// A point on the ground, degrees (WGS84).
public struct LatLon: Codable, Sendable, Hashable {
    public var lat: Double
    public var lon: Double
    public init(_ lat: Double, _ lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// A cooked airport: everything the app draws and simulates at one airport, made offline by
/// `flight-tools airport-import` from FAA NASR (runways, lighting, markings) and OpenStreetMap
/// (taxiways, aprons, stands, hold positions, buildings, boundary). Heights in metres above
/// mean sea level, lengths in metres.
public struct AirportLayout: Codable, Sendable {
    public var icao: String
    public var name: String
    public var reference: LatLon
    public var elevation: Double
    public var runways: [Runway]
    public var taxiways: [Taxiway]
    public var aprons: [Area]
    /// Outer rings of the aerodrome; the ground is held to the airport surface inside them.
    public var boundary: [[LatLon]]
    public var buildings: [Building]
    public var stands: [Stand]
    public var holdPositions: [HoldPosition]
    /// Where each part came from, with dates.
    public var sources: [String]

    public init(icao: String, name: String, reference: LatLon, elevation: Double, runways: [Runway],
                taxiways: [Taxiway], aprons: [Area], boundary: [[LatLon]], buildings: [Building],
                stands: [Stand], holdPositions: [HoldPosition], sources: [String]) {
        self.icao = icao
        self.name = name
        self.reference = reference
        self.elevation = elevation
        self.runways = runways
        self.taxiways = taxiways
        self.aprons = aprons
        self.boundary = boundary
        self.buildings = buildings
        self.stands = stands
        self.holdPositions = holdPositions
        self.sources = sources
    }

    public static func load(_ url: URL) throws -> AirportLayout {
        try JSONDecoder().decode(AirportLayout.self, from: Data(contentsOf: url))
    }
}

public enum Surface: String, Codable, Sendable {
    case concrete, asphalt
}

public struct Runway: Codable, Sendable {
    /// The two ends, low designator first.
    public var ends: [RunwayEnd]
    public var width: Double
    public var surface: Surface
    /// HIRL, MIRL, LIRL or none.
    public var edgeLights: String?

    public init(ends: [RunwayEnd], width: Double, surface: Surface, edgeLights: String?) {
        self.ends = ends
        self.width = width
        self.surface = surface
        self.edgeLights = edgeLights
    }

    public var name: String { ends.map(\.ident).joined(separator: "/") }
}

public struct RunwayEnd: Codable, Sendable {
    /// Designator as painted: "07L", "26".
    public var ident: String
    /// The physical end of the pavement on the centreline.
    public var position: LatLon
    public var elevation: Double
    /// Displaced threshold, metres from the end (0 when none).
    public var displacedThreshold: Double
    public var touchdownZoneElevation: Double?
    public var thresholdCrossingHeight: Double?
    public var glidePathAngle: Double?
    /// "P4L": four-light PAPI on the left; "P4R", "P2L", and so on.
    public var visualGlideSlope: String?
    /// ALSF2, MALSR, MALSF, SSALR...
    public var approachLights: String?
    public var centerlineLights: Bool
    public var touchdownZoneLights: Bool
    /// Runway end identifier lights (REIL).
    public var endIdentifierLights: Bool
    /// PIR (precision), NPI (non-precision), BSC (basic/visual).
    public var markings: String
    public var ils: Bool

    public init(ident: String, position: LatLon, elevation: Double, displacedThreshold: Double,
                touchdownZoneElevation: Double?, thresholdCrossingHeight: Double?, glidePathAngle: Double?,
                visualGlideSlope: String?, approachLights: String?, centerlineLights: Bool,
                touchdownZoneLights: Bool, endIdentifierLights: Bool, markings: String, ils: Bool) {
        self.ident = ident
        self.position = position
        self.elevation = elevation
        self.displacedThreshold = displacedThreshold
        self.touchdownZoneElevation = touchdownZoneElevation
        self.thresholdCrossingHeight = thresholdCrossingHeight
        self.glidePathAngle = glidePathAngle
        self.visualGlideSlope = visualGlideSlope
        self.approachLights = approachLights
        self.centerlineLights = centerlineLights
        self.touchdownZoneLights = touchdownZoneLights
        self.endIdentifierLights = endIdentifierLights
        self.markings = markings
        self.ils = ils
    }

    /// The painted number without its side letter.
    public var number: String { String(ident.prefix { $0.isNumber }) }
    /// "L", "C", "R" or "".
    public var side: String { String(ident.drop { $0.isNumber }) }
}

public struct Taxiway: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case taxiway, taxilane }
    public var ref: String?
    public var kind: Kind
    public var width: Double
    public var points: [LatLon]

    public init(ref: String?, kind: Kind, width: Double, points: [LatLon]) {
        self.ref = ref
        self.kind = kind
        self.width = width
        self.points = points
    }
}

/// A paved area (apron) as a polygon with holes.
public struct Area: Codable, Sendable {
    public var outer: [LatLon]
    public var holes: [[LatLon]]
    public var surface: Surface

    public init(outer: [LatLon], holes: [[LatLon]], surface: Surface) {
        self.outer = outer
        self.holes = holes
        self.surface = surface
    }
}

public struct Building: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case terminal, hangar, tower, parking, generic }
    public var kind: Kind
    public var name: String?
    /// Roof height above the ground, and the height the walls start at (0 unless raised).
    public var height: Double
    public var minHeight: Double
    public var outer: [LatLon]
    public var holes: [[LatLon]]

    public init(kind: Kind, name: String?, height: Double, minHeight: Double, outer: [LatLon], holes: [[LatLon]]) {
        self.kind = kind
        self.name = name
        self.height = height
        self.minHeight = minHeight
        self.outer = outer
        self.holes = holes
    }
}

/// An aircraft parking position. `line` is the painted lead-in line when mapped, ending at
/// the stop position; otherwise only the point is known.
public struct Stand: Codable, Sendable {
    public var ref: String?
    public var position: LatLon
    public var line: [LatLon]

    public init(ref: String?, position: LatLon, line: [LatLon]) {
        self.ref = ref
        self.position = position
        self.line = line
    }
}

/// A painted holding position on a taxiway: where the line is, which way the taxiway runs
/// through it, and which side the runway is on (the dashed lines face the runway).
public struct HoldPosition: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case runway, ils, intermediate }
    public var kind: Kind
    public var position: LatLon
    /// True heading (degrees) of the taxiway direction that leads toward the runway.
    public var towardRunway: Double
    /// Width of the taxiway at the line.
    public var width: Double
    /// The runway it protects ("08/26"), when known.
    public var runway: String?

    public init(kind: Kind, position: LatLon, towardRunway: Double, width: Double, runway: String?) {
        self.kind = kind
        self.position = position
        self.towardRunway = towardRunway
        self.width = width
        self.runway = runway
    }
}
