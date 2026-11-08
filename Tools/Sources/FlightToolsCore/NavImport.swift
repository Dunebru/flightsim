import Foundation
import Nav

/// Navaids and fixes inside a latitude/longitude box from NASR's NAV_BASE.csv and FIX_BASE.csv.
/// Decommissioned navaids, VOTs (test transmitters) and fan markers are left out.
enum NavImporter {
    static func run(nasr: URL, south: Double, west: Double, north: Double, east: Double) throws -> NavData {
        func inBox(_ r: [String: String]) -> (Double, Double)? {
            guard let lat = r["LAT_DECIMAL"].flatMap(Double.init), let lon = r["LONG_DECIMAL"].flatMap(Double.init),
                  lat >= south, lat <= north, lon >= west, lon <= east else { return nil }
            return (lat, lon)
        }
        let navRows = try CSV.records(nasr.appendingPathComponent("NAV_BASE.csv")) { r in
            guard let type = r["NAV_TYPE"], type != "VOT", type != "FAN MARKER" else { return false }
            if let status = r["NAV_STATUS"], status.hasPrefix("DECOMMISSIONED") || status.hasPrefix("SHUTDOWN") { return false }
            return inBox(r) != nil
        }
        let navaids = navRows.compactMap { r -> Navaid? in
            guard let id = r["NAV_ID"], let type = r["NAV_TYPE"], let (lat, lon) = inBox(r) else { return nil }
            return Navaid(id: id, type: type, name: r["NAME"] ?? id, latitude: lat, longitude: lon,
                          frequency: r["FREQ"].flatMap(Double.init))
        }.sorted { $0.id < $1.id }
        let fixRows = try CSV.records(nasr.appendingPathComponent("FIX_BASE.csv")) { inBox($0) != nil }
        let fixes = fixRows.compactMap { r -> Fix? in
            guard let id = r["FIX_ID"], let (lat, lon) = inBox(r) else { return nil }
            return Fix(id: id, latitude: lat, longitude: lon)
        }.sorted { $0.id < $1.id }
        let effective = navRows.first?["EFF_DATE"] ?? "unknown"
        return NavData(source: "FAA NASR 28-day subscription, effective \(effective)", navaids: navaids, fixes: fixes)
    }
}
