import Foundation
import Testing
@testable import FlightToolsCore

/// nav-import keeps working navaids and fixes inside the box and nothing else.
struct NavImportTests {
    @Test func keepsWorkingNavaidsInTheBox() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("navimport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nav = """
        "EFF_DATE","NAV_ID","NAV_TYPE","NAV_STATUS","NAME","LAT_DECIMAL","LONG_DECIMAL","FREQ"
        "2026/10/29","PXR","VORTAC","OPERATIONAL RESTRICTED","PHOENIX",33.43301725,-111.97020183,"115.6"
        "2026/10/29","OLD","VOR","DECOMMISSIONED","GONE",33.5,-112.0,"113.0"
        "2026/10/29","TST","VOT","OPERATIONAL IFR","TEST",33.5,-112.0,"108.0"
        "2026/10/29","FAR","NDB","OPERATIONAL IFR","FAR AWAY",45.0,-100.0,"300"
        """
        let fix = """
        "EFF_DATE","FIX_ID","LAT_DECIMAL","LONG_DECIMAL"
        "2026/10/29","HOMRR",33.6,-112.3
        "2026/10/29","NOPEE",40.0,-90.0
        """
        try nav.write(to: dir.appendingPathComponent("NAV_BASE.csv"), atomically: true, encoding: .utf8)
        try fix.write(to: dir.appendingPathComponent("FIX_BASE.csv"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("nav.json")
        let r = await runTool(["nav-import", "--nasr", dir.path, "--box", "30,-122,38,-108", "--out", out.path])
        #expect(r.code == 0, "\(r.output)")
        let data = try JSONDecoder().decode(NavDataProbe.self, from: Data(contentsOf: out))
        #expect(data.navaids.map(\.id) == ["PXR"])
        #expect(data.navaids.first?.frequency == 115.6)
        #expect(data.fixes.map(\.id) == ["HOMRR"])
        let bad = await runTool(["nav-import", "--nasr", dir.path, "--box", "38,-108,30,-122", "--out", out.path])
        #expect(bad.code == 64, "a box with south above north is refused")
    }
}

private struct NavDataProbe: Decodable {
    struct N: Decodable { let id: String; let frequency: Double? }
    struct F: Decodable { let id: String }
    let navaids: [N]
    let fixes: [F]
}
