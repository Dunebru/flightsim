import Airports
import Foundation

// MARK: - CSV

/// RFC 4180 CSV: quoted fields, doubled quotes, commas and newlines inside quotes.
enum CSV {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, i = text.unicodeScalars.startIndex
        let s = text.unicodeScalars
        while i < s.endIndex {
            let c = s[i]
            if quoted {
                if c == "\"" {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == "\"" { field.unicodeScalars.append("\""); i = next }
                    else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r": break
                default: field.unicodeScalars.append(c)
                }
            }
            i = s.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Rows as dictionaries keyed by the header, keeping only rows that pass `keep`.
    static func records(_ url: URL, keep: ([String: String]) -> Bool = { _ in true }) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .isoLatin1)
        let all = rows(text)
        guard let header = all.first else { return [] }
        return all.dropFirst().compactMap { r in
            guard r.count == header.count else { return nil }
            let d = Dictionary(uniqueKeysWithValues: zip(header, r))
            return keep(d) ? d : nil
        }
    }
}

// MARK: - FAA NASR

/// Runways from the FAA's 28-day NASR subscription (APT_BASE, APT_RWY, APT_RWY_END CSVs).
public struct NASRAirport: Sendable {
    public var faaID: String
    public var icao: String
    public var name: String
    public var reference: LatLon
    public var elevationFeet: Double
    public var runways: [Runway]
    public var effectiveDate: String

    static let feet = 0.3048

    public static func load(directory: URL, icao: String) throws -> NASRAirport {
        let base = try CSV.records(directory.appendingPathComponent("APT_BASE.csv")) { $0["ICAO_ID"] == icao }
        guard let b = base.first, let id = b["ARPT_ID"] else { throw ImportError.notFound("\(icao) in APT_BASE.csv") }
        let rwys = try CSV.records(directory.appendingPathComponent("APT_RWY.csv")) { $0["ARPT_ID"] == id }
        let ends = try CSV.records(directory.appendingPathComponent("APT_RWY_END.csv")) { $0["ARPT_ID"] == id }
        func d(_ r: [String: String], _ k: String) -> Double? { r[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        var runways: [Runway] = []
        for r in rwys {
            guard let rid = r["RWY_ID"], let width = d(r, "RWY_WIDTH") else { continue }
            let mine = ends.filter { $0["RWY_ID"] == rid }
            let parsed: [RunwayEnd] = mine.compactMap { e in
                guard let ident = e["RWY_END_ID"], let lat = d(e, "LAT_DECIMAL"), let lon = d(e, "LONG_DECIMAL"),
                      let elev = d(e, "RWY_END_ELEV") else { return nil }
                return RunwayEnd(
                    ident: ident, position: LatLon(lat, lon), elevation: elev * feet,
                    displacedThreshold: (d(e, "DISPLACED_THR_LEN") ?? 0) * feet,
                    touchdownZoneElevation: d(e, "TDZ_ELEV").map { $0 * feet },
                    thresholdCrossingHeight: d(e, "THR_CROSSING_HGT").map { $0 * feet },
                    glidePathAngle: d(e, "VISUAL_GLIDE_PATH_ANGLE"),
                    visualGlideSlope: e["VGSI_CODE"].flatMap { $0.isEmpty ? nil : $0 },
                    approachLights: e["APCH_LGT_SYSTEM_CODE"].flatMap { $0.isEmpty || $0 == "NONE" ? nil : $0 },
                    centerlineLights: e["CNTRLN_LGTS_AVBL_FLAG"] == "Y",
                    touchdownZoneLights: e["TDZ_LGT_AVBL_FLAG"] == "Y",
                    endIdentifierLights: e["RWY_END_LGTS_FLAG"] == "Y",
                    markings: e["RWY_MARKING_TYPE_CODE"] ?? "",
                    ils: !(e["ILS_TYPE"] ?? "").isEmpty)
            }.sorted { $0.ident < $1.ident }
            guard parsed.count == 2 else { continue }
            let surfaceCode = r["SURFACE_TYPE_CODE"] ?? ""
            let light = r["RWY_LGT_CODE"] ?? ""
            runways.append(Runway(ends: parsed, width: width * feet,
                                  surface: surfaceCode.hasPrefix("ASPH") ? .asphalt : .concrete,
                                  edgeLights: ["HIGH": "HIRL", "MED": "MIRL", "LOW": "LIRL"][light]))
        }
        guard let lat = d(b, "LAT_DECIMAL"), let lon = d(b, "LONG_DECIMAL") else { throw ImportError.notFound("\(icao) position") }
        return NASRAirport(faaID: id, icao: icao, name: b["ARPT_NAME"] ?? icao, reference: LatLon(lat, lon),
                           elevationFeet: d(b, "ELEV") ?? 0, runways: runways.sorted { $0.name < $1.name },
                           effectiveDate: b["EFF_DATE"] ?? "")
    }
}

public enum ImportError: Error, CustomStringConvertible {
    case notFound(String), overpass(String)
    public var description: String {
        switch self {
        case .notFound(let s): "not found: \(s)"
        case .overpass(let s): "Overpass: \(s)"
        }
    }
}

// MARK: - OpenStreetMap

/// The subset of Overpass JSON (`out geom`) the importer reads.
struct OSMResponse: Decodable {
    struct Point: Decodable { let lat: Double; let lon: Double }
    struct Member: Decodable {
        let type: String
        let ref: Int
        let role: String
        let geometry: [Point]?
    }
    struct Element: Decodable {
        let type: String
        let id: Int
        let lat: Double?
        let lon: Double?
        let tags: [String: String]?
        let nodes: [Int]?
        let geometry: [Point]?
        let members: [Member]?
    }
    struct Meta: Decodable { let timestamp_osm_base: String? }
    let elements: [Element]
    let osm3s: Meta?
}

enum Overpass {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Runs a query, caching the response at `cache` (delete the file to refresh).
    static func query(_ q: String, cache: URL) async throws -> OSMResponse {
        if let data = try? Data(contentsOf: cache) { return try JSONDecoder().decode(OSMResponse.self, from: data) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("flightsim-personal-test", forHTTPHeaderField: "User-Agent")
        request.httpBody = ("data=" + (q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).data(using: .utf8)
        var last: any Error = ImportError.overpass("no response")
        for attempt in 0..<4 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ImportError.overpass("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                let decoded = try JSONDecoder().decode(OSMResponse.self, from: data)
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cache)
                return decoded
            } catch {
                last = error
                try await Task.sleep(for: .seconds(5 << attempt))
            }
        }
        throw last
    }
}

// MARK: - Geometry helpers (local metres around a point)

struct LocalPlane {
    let origin: LatLon
    let mPerLat: Double, mPerLon: Double
    init(_ origin: LatLon) {
        self.origin = origin
        let phi = origin.lat * .pi / 180
        mPerLat = 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi)
        mPerLon = 111_412.84 * cos(phi) - 93.5 * cos(3 * phi)
    }
    func xy(_ p: LatLon) -> SIMD2<Double> { SIMD2((p.lon - origin.lon) * mPerLon, (p.lat - origin.lat) * mPerLat) }
    func latLon(_ v: SIMD2<Double>) -> LatLon { LatLon(origin.lat + v.y / mPerLat, origin.lon + v.x / mPerLon) }
}

enum PlanarGeometry {
    static func contains(_ ring: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func distanceToSegment(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let t = max(0, min(1, ((p - a) * ab).sum() / max((ab * ab).sum(), 1e-12)))
        let d = p - (a + ab * t)
        return (d * d).sum().squareRoot()
    }

    /// Convex hull (Andrew's monotone chain), closed (first point repeated at the end).
    static func hull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = Array(Set(pts.map { [$0.x, $0.y] })).map { SIMD2($0[0], $0[1]) }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        guard p.count >= 3 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        let ring = Array(lower.dropLast()) + Array(upper.dropLast())
        return ring + [ring[0]]
    }

    /// Joins open member ways into closed rings by matching endpoints.
    static func rings(_ parts: [[LatLon]]) -> [[LatLon]] {
        var pending = parts.filter { $0.count >= 2 }
        var out: [[LatLon]] = []
        while var ring = pending.popLast() {
            var progressed = true
            while ring.first != ring.last && progressed {
                progressed = false
                for (i, p) in pending.enumerated() {
                    if p.first == ring.last { ring += p.dropFirst(); pending.remove(at: i); progressed = true; break }
                    if p.last == ring.last { ring += p.reversed().dropFirst(); pending.remove(at: i); progressed = true; break }
                }
            }
            if ring.first == ring.last, ring.count >= 4 { out.append(ring) }
        }
        return out
    }
}

// MARK: - Import

public struct AirportImporter: Sendable {
    public let nasrDirectory: URL
    public let osmCache: URL

    public init(nasrDirectory: URL, osmCache: URL) {
        self.nasrDirectory = nasrDirectory
        self.osmCache = osmCache
    }

    public func run(icao: String, log: @Sendable (String) -> Void = { _ in }) async throws -> AirportLayout {
        let nasr = try NASRAirport.load(directory: nasrDirectory, icao: icao)
        log("NASR \(nasr.effectiveDate): \(nasr.name), \(nasr.runways.count) runways: \(nasr.runways.map(\.name).joined(separator: ", "))")

        let aerodrome = try await Overpass.query("[out:json][timeout:120];nwr[\"aeroway\"=\"aerodrome\"][\"icao\"=\"\(icao)\"];out geom;",
                                                 cache: osmCache.appendingPathComponent("\(icao)-aerodrome.json"))
        var boundaryParts: [[LatLon]] = []
        for e in aerodrome.elements {
            if let g = e.geometry { boundaryParts.append(g.map { LatLon($0.lat, $0.lon) }) }
            for m in e.members ?? [] where m.role == "outer" || m.role.isEmpty {
                if let g = m.geometry { boundaryParts.append(g.map { LatLon($0.lat, $0.lon) }) }
            }
        }
        let mapped = PlanarGeometry.rings(boundaryParts)
        guard !mapped.isEmpty else { throw ImportError.notFound("aerodrome boundary for \(icao) in OSM") }
        // The mapped outline can leave the terminal core outside (KPHX's wraps around it), so
        // the airport's extent is the convex hull of the outline.
        let hullPlane = LocalPlane(mapped[0][0])
        let boundary = [PlanarGeometry.hull(mapped.flatMap { $0 }.map(hullPlane.xy)).map(hullPlane.latLon)]
        let all = boundary.flatMap { $0 }
        let south = all.map(\.lat).min()! - 0.004, north = all.map(\.lat).max()! + 0.004
        let west = all.map(\.lon).min()! - 0.004, east = all.map(\.lon).max()! + 0.004
        let bbox = "\(south),\(west),\(north),\(east)"
        let osm = try await Overpass.query("""
            [out:json][timeout:180];
            (way["aeroway"](\(bbox));node["aeroway"](\(bbox));relation["aeroway"](\(bbox));
             way["building"](\(bbox));relation["building"](\(bbox));way["man_made"="tower"](\(bbox)););
            out geom;
            """, cache: osmCache.appendingPathComponent("\(icao)-features.json"))
        log("OSM \(osm.osm3s?.timestamp_osm_base ?? "?"): \(osm.elements.count) features, boundary \(boundary.count) ring(s)")

        let plane = LocalPlane(nasr.reference)
        let rings = boundary.map { $0.map(plane.xy) }
        func insideAirport(_ pts: [LatLon]) -> Bool {
            guard !pts.isEmpty else { return false }
            let c = pts.reduce(SIMD2<Double>.zero) { $0 + plane.xy($1) } / Double(pts.count)
            return rings.contains { PlanarGeometry.contains($0, c) }
        }
        func points(_ e: OSMResponse.Element) -> [LatLon] { (e.geometry ?? []).map { LatLon($0.lat, $0.lon) } }
        func metres(_ s: String?) -> Double? {
            guard let s else { return nil }
            let t = s.lowercased().replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("ft") || s.contains("'") { return Double(t.filter { $0.isNumber || $0 == "." }).map { $0 * 0.3048 } }
            return Double(t)
        }

        // Taxiways: centrelines with widths.
        var taxiways: [Taxiway] = []
        for e in osm.elements where e.type == "way" {
            guard let t = e.tags, let a = t["aeroway"], a == "taxiway" || a == "taxilane" else { continue }
            let pts = points(e)
            guard pts.count >= 2, t["area"] != "yes" else { continue }
            let kind: Taxiway.Kind = a == "taxilane" ? .taxilane : .taxiway
            taxiways.append(Taxiway(ref: t["ref"], kind: kind, width: metres(t["width"]) ?? (kind == .taxiway ? 23 : 15), points: pts))
        }

        // Aprons: closed ways and multipolygons.
        var aprons: [Area] = []
        for e in osm.elements {
            guard e.tags?["aeroway"] == "apron" else { continue }
            let surface: Surface = (e.tags?["surface"] ?? "concrete").contains("asphalt") ? .asphalt : .concrete
            if e.type == "way" {
                let pts = points(e)
                if pts.count >= 4, pts.first == pts.last { aprons.append(Area(outer: pts, holes: [], surface: surface)) }
            } else if let members = e.members {
                let outers = PlanarGeometry.rings(members.filter { $0.role == "outer" }.compactMap { $0.geometry?.map { LatLon($0.lat, $0.lon) } })
                let inners = PlanarGeometry.rings(members.filter { $0.role == "inner" }.compactMap { $0.geometry?.map { LatLon($0.lat, $0.lon) } })
                for o in outers {
                    let ox = o.map(plane.xy)
                    let holes = inners.filter { h in PlanarGeometry.contains(ox, plane.xy(h[0])) }
                    aprons.append(Area(outer: o, holes: holes, surface: surface))
                }
            }
        }

        // Buildings inside the aerodrome.
        var buildings: [Building] = []
        for e in osm.elements {
            guard let t = e.tags, t["building"] != nil || t["aeroway"] == "terminal" || t["aeroway"] == "hangar"
                    || t["man_made"] == "tower" || t["aeroway"] == "control_tower" || t["aeroway"] == "tower" else { continue }
            if t["building"] == "no" { continue }
            var outers: [[LatLon]] = [], holes: [[LatLon]] = []
            if e.type == "way" {
                let pts = points(e)
                if pts.count >= 4, pts.first == pts.last { outers = [pts] }
            } else if let members = e.members {
                outers = PlanarGeometry.rings(members.filter { $0.role == "outer" }.compactMap { $0.geometry?.map { LatLon($0.lat, $0.lon) } })
                holes = PlanarGeometry.rings(members.filter { $0.role == "inner" }.compactMap { $0.geometry?.map { LatLon($0.lat, $0.lon) } })
            }
            let b = t["building"] ?? ""
            let kind: Building.Kind
            if t["aeroway"] == "terminal" || b == "terminal" { kind = .terminal }
            else if t["aeroway"] == "hangar" || b == "hangar" { kind = .hangar }
            else if t["aeroway"] == "control_tower" || t["aeroway"] == "tower" || t["tower:type"] == "airport_control"
                        || t["tower:type"] == "air_traffic_control" { kind = .tower }
            else if b == "parking" || t["parking"] == "multi-storey" { kind = .parking }
            else { kind = .generic }
            let defaultHeight: Double = switch kind {
            case .terminal: 18
            case .hangar: 16
            case .tower: 40
            case .parking: 14
            case .generic: b == "carport" || b == "roof" ? 4 : 7
            }
            // Untagged heights scale with the footprint: a T-hangar is not a maintenance hangar.
            let area = outers.first.map { ring -> Double in
                let pts = ring.map(plane.xy)
                var a = 0.0
                for i in 0..<(pts.count - 1) { a += pts[i].x * pts[i + 1].y - pts[i + 1].x * pts[i].y }
                return abs(a) / 2
            } ?? 0
            var sized = defaultHeight
            if kind == .hangar { sized = area < 1_500 ? 6 : (area < 6_000 ? 10 : 16) }
            if kind == .generic && area < 100 { sized = 4 }
            let height = metres(t["height"]) ?? t["building:levels"].flatMap(Double.init).map { $0 * 3.5 + 1 } ?? sized
            let minHeight = metres(t["min_height"]) ?? t["building:min_level"].flatMap(Double.init).map { $0 * 3.5 } ?? 0
            for o in outers where insideAirport(o) {
                let ox = o.map(plane.xy)
                buildings.append(Building(kind: kind, name: t["name"], height: height, minHeight: minHeight, outer: o,
                                          holes: holes.filter { PlanarGeometry.contains(ox, plane.xy($0[0])) }))
            }
        }

        // Stands: parking positions; a way is the lead-in line, stopping at the end nearer a building.
        let buildingRings = buildings.filter { $0.kind != .generic || $0.height > 5 }.map { $0.outer.map(plane.xy) }
        func distanceToBuildings(_ p: LatLon) -> Double {
            let x = plane.xy(p)
            var best = Double.infinity
            for r in buildingRings { for i in 0..<(r.count - 1) { best = min(best, PlanarGeometry.distanceToSegment(x, r[i], r[i + 1])) } }
            return best
        }
        var stands: [Stand] = []
        for e in osm.elements where e.tags?["aeroway"] == "parking_position" {
            if e.type == "node", let lat = e.lat, let lon = e.lon {
                stands.append(Stand(ref: e.tags?["ref"], position: LatLon(lat, lon), line: []))
            } else if e.type == "way" {
                var pts = points(e)
                guard pts.count >= 2 else { continue }
                if distanceToBuildings(pts.first!) < distanceToBuildings(pts.last!) { pts.reverse() }
                stands.append(Stand(ref: e.tags?["ref"], position: pts.last!, line: pts))
            }
        }

        // Hold positions: nodes on taxiways; the dashed side faces the runway.
        var nodeWay: [Int: (way: OSMResponse.Element, index: Int)] = [:]
        for e in osm.elements where e.type == "way" && (e.tags?["aeroway"] == "taxiway" || e.tags?["aeroway"] == "taxilane") {
            for (i, n) in (e.nodes ?? []).enumerated() { nodeWay[n] = (e, i) }
        }
        let runwayLines = nasr.runways.map { r in (r.name, plane.xy(r.ends[0].position), plane.xy(r.ends[1].position)) }
        func nearestRunway(_ x: SIMD2<Double>) -> (name: String, distance: Double) {
            runwayLines.map { ($0.0, PlanarGeometry.distanceToSegment(x, $0.1, $0.2)) }.min { $0.1 < $1.1 } ?? ("", .infinity)
        }
        var holds: [HoldPosition] = []
        for e in osm.elements where e.type == "node" && e.tags?["aeroway"] == "holding_position" {
            guard let lat = e.lat, let lon = e.lon, let (way, i) = nodeWay[e.id], let g = way.geometry, g.count >= 2 else { continue }
            let here = plane.xy(LatLon(lat, lon))
            let a = plane.xy(LatLon(g[max(i - 1, 0)].lat, g[max(i - 1, 0)].lon))
            let b = plane.xy(LatLon(g[min(i + 1, g.count - 1)].lat, g[min(i + 1, g.count - 1)].lon))
            var dir = b - a
            let len = (dir * dir).sum().squareRoot()
            guard len > 0.1 else { continue }
            dir /= len
            // Whichever way along the taxiway gets closer to a runway is toward the runway.
            if nearestRunway(here + dir * 40).distance > nearestRunway(here - dir * 40).distance { dir = -dir }
            let typeTag = e.tags?["holding_position:type"] ?? e.tags?["holding_position"] ?? "runway"
            let kind: HoldPosition.Kind = typeTag.contains("ils") ? .ils : (typeTag.contains("intermediate") ? .intermediate : .runway)
            let width = metres(way.tags?["width"]) ?? (way.tags?["aeroway"] == "taxilane" ? 15 : 23)
            holds.append(HoldPosition(kind: kind, position: LatLon(lat, lon),
                                      towardRunway: (atan2(dir.x, dir.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360),
                                      width: width, runway: e.tags?["ref"] ?? nearestRunway(here).name))
        }

        log("taxiways \(taxiways.count), aprons \(aprons.count), buildings \(buildings.count), stands \(stands.count), holds \(holds.count)")
        return AirportLayout(
            icao: icao, name: nasr.name, reference: nasr.reference, elevation: nasr.elevationFeet * NASRAirport.feet,
            runways: nasr.runways, taxiways: taxiways, aprons: aprons, boundary: boundary, buildings: buildings,
            stands: stands, holdPositions: holds,
            sources: ["FAA NASR 28-day subscription, effective \(nasr.effectiveDate) (US government work): runways, lighting, markings",
                      "OpenStreetMap contributors, data as of \(osm.osm3s?.timestamp_osm_base ?? "unknown") (ODbL): taxiways, aprons, stands, hold positions, buildings, boundary"])
    }
}
