import Testing
@testable import SimCore

/// Reference values computed independently with PROJ 9 via pyproj (EPSG:4979 -> EPSG:4978).
struct GeodesyTests {
    @Test func equatorPrimeMeridian() {
        let e = Geodetic(latitude: 0, longitude: 0, height: 0).ecef
        #expect(abs(e.x - 6_378_137.0) < 1e-6)
        #expect(abs(e.y) < 1e-6)
        #expect(abs(e.z) < 1e-6)
    }

    @Test func northPole() {
        let e = Geodetic(latitude: 90, longitude: 0, height: 0).ecef
        #expect(abs(e.z - 6_356_752.314_245) < 1e-3)
    }

    @Test func phoenixSkyHarbor() {
        // KPHX area, 33.4342 N, 112.0116 W, 345 m ellipsoidal height.
        let e = Geodetic(latitude: 33.4342, longitude: -112.0116, height: 345).ecef
        #expect(abs(e.x - -1_997_047.234) < 1e-3)
        #expect(abs(e.y - -4_939_985.600) < 1e-3)
        #expect(abs(e.z - 3_494_436.314) < 1e-3)
    }

    @Test(arguments: [
        Geodetic(latitude: 33.4342, longitude: -112.0116, height: 345),
        Geodetic(latitude: 51.4700, longitude: -0.4543, height: 83),
        Geodetic(latitude: -33.9461, longitude: 151.1772, height: 6),
        Geodetic(latitude: 89.9, longitude: 45, height: 11_000),
        Geodetic(latitude: -89.95, longitude: -120, height: 2_800),
        Geodetic(latitude: 0, longitude: 179.999, height: 12_500),
    ])
    func roundTrip(_ g: Geodetic) {
        let back = g.ecef.geodetic
        #expect(abs(back.latitude - g.latitude) < 1e-9)
        #expect(abs(back.longitude - g.longitude) < 1e-9)
        #expect(abs(back.height - g.height) < 1e-3)
    }

    @Test func moduleIdentity() {
        #expect(SimCoreModule.info.name == "SimCore")
    }
}
