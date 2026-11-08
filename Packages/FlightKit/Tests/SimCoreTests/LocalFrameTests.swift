import Testing
@testable import SimCore

struct LocalFrameTests {
    let frame = LocalFrame(origin: Geodetic(latitude: 33.4342, longitude: -112.0116, height: 345))

    @Test func originMapsToZero() {
        let p = frame.enu(frame.origin)
        #expect(abs(p.x) < 1e-6 && abs(p.y) < 1e-6 && abs(p.z) < 1e-6)
    }

    @Test func eastNorthUpPointTheRightWay() {
        // 0.01 deg of longitude east at 33.43 N is about 929 m; 0.01 deg of latitude north about 1109 m.
        let e = frame.enu(Geodetic(latitude: 33.4342, longitude: -112.0016, height: 345))
        #expect(abs(e.x - 929.6) < 2 && abs(e.y) < 1)
        let n = frame.enu(Geodetic(latitude: 33.4442, longitude: -112.0116, height: 345))
        #expect(abs(n.y - 1109.0) < 2 && abs(n.x) < 1e-3)
        let u = frame.enu(Geodetic(latitude: 33.4342, longitude: -112.0116, height: 1345))
        #expect(abs(u.z - 1000) < 1e-6)
    }

    @Test(arguments: [SIMD3<Double>(-1_600, 0, 2), SIMD3(25_000, -40_000, 3_000), SIMD3(0.5, 0.5, 0.5)])
    func roundTrip(_ p: SIMD3<Double>) {
        let back = frame.enu(frame.geodetic(p))
        #expect(abs(back.x - p.x) < 1e-4 && abs(back.y - p.y) < 1e-4 && abs(back.z - p.z) < 1e-4)
    }
}
