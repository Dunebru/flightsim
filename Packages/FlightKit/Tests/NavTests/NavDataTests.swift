import Foundation
import Testing
@testable import Nav

/// The cooked navaids and fixes around KPHX and KLAX (Data/Bundle/Nav/navdata.json).
struct NavDataTests {
    static let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Nav/navdata.json").standardized

    @Test func phoenixNavaids() throws {
        let nav = try NavData.load(Self.url)
        let pxr = try #require(nav.navaids.first { $0.id == "PXR" })
        #expect(pxr.type == "VORTAC" && pxr.frequency == 115.6)
        #expect(abs(pxr.latitude - 33.433) < 0.01 && abs(pxr.longitude + 111.970) < 0.01)
        let lax = try #require(nav.navaids.first { $0.id == "LAX" })
        #expect(lax.isVOR && lax.frequency == 113.6)
        #expect(nav.fixes.count > 1_000)
    }

    @Test func boxAndLookup() throws {
        let nav = try NavData.load(Self.url)
        // Nearest first: PXR sits almost on KPHX.
        let around = nav.inside(south: 33.2, west: -112.3, north: 33.7, east: -111.7, limit: 5)
        #expect(around.navaids.first?.id == "PXR")
        #expect(around.fixes.count == 5)
        let found = try #require(nav.find("bxk", near: 33.43, -112.01))
        #expect(found.name == "BXK" && abs(found.longitude + 112.82) < 0.01)
        #expect(nav.find("NOSUCH", near: 33.43, -112.01) == nil)
    }
}
