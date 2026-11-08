import Foundation
import SimCore
import Testing
import simd
@testable import Airports

struct AirportGeometryTests {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Airports").standardized

    static func site(_ icao: String) throws -> AirportSite {
        try AirportSite.load(dir.appendingPathComponent("\(icao).json"))
    }

    /// The shared surface passes through every published runway-end elevation.
    @Test(arguments: ["KPHX", "KLAX"])
    func surfaceHonoursPublishedRunwayElevations(icao: String) throws {
        let s = try Self.site(icao)
        for r in s.layout.runways {
            for e in r.ends {
                let p = s.frame.enu(Geodetic(latitude: e.position.lat, longitude: e.position.lon, height: e.elevation))
                #expect(abs(s.z(SIMD2(p.x, p.y)) - p.z) < 0.05, "\(icao) \(e.ident)")
            }
        }
    }

    @Test func triangulationKeepsAreaWithHoles() {
        let outer: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 60), SIMD2(0, 60)]
        let hole: [SIMD2<Double>] = [SIMD2(20, 20), SIMD2(40, 20), SIMD2(40, 40), SIMD2(20, 40)]
        let tris = Polygon2D.triangulate(outer: outer, holes: [hole])
        let area = tris.reduce(0.0) { $0 + abs(Polygon2D.cross($1.0, $1.1, $1.2)) / 2 }
        #expect(abs(area - (6_000 - 400)) < 1e-6, "area \(area)")
        let fine = Polygon2D.subdivide(tris, maxEdge: 10)
        let fineArea = fine.reduce(0.0) { $0 + abs(Polygon2D.cross($1.0, $1.1, $1.2)) / 2 }
        #expect(abs(fineArea - 5_600) < 1e-6)
        #expect(fine.allSatisfy { max(simd_distance($0.0, $0.1), simd_distance($0.1, $0.2), simd_distance($0.2, $0.0)) <= 10 })
    }

    @Test(arguments: ["KPHX", "KLAX"])
    func buildsTheWholeAirport(icao: String) throws {
        let s = try Self.site(icao)
        let start = ContinuousClock.now
        let g = AirportGeometry.build(s)
        let seconds = (ContinuousClock.now - start) / .seconds(1)
        print("\(icao): runways \(g.runways.count), concrete \(g.concrete.triangleCount) tris, paint \(g.yellowPaint.triangleCount), buildings \(g.buildings.values.map(\.triangleCount).reduce(0, +)), glazing \(g.glazing.triangleCount), \(String(format: "%.2f", seconds)) s")
        #expect(g.runways.count == s.layout.runways.count)
        #expect(g.runways.allSatisfy { $0.markings.triangleCount > 100 })
        #expect(g.concrete.triangleCount > 10_000)
        #expect(g.yellowPaint.triangleCount > 1_000)
        #expect(!g.buildings.isEmpty)
        let all = g.concrete.positions + g.yellowPaint.positions + g.runways.flatMap(\.surface.positions)
        #expect(all.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && abs($0.z) < 100 })
    }

    /// Runway frames match NASR's published true alignment within a degree.
    @Test func runwayHeadingsMatchPublishedAlignment() throws {
        let s = try Self.site("KLAX")
        let f = s.runwayFrame(s.layout.runways.first { $0.name == "06L/24R" }!)
        #expect(abs(f.heading - 83) < 1, "06L heading \(f.heading)")
        #expect(abs(f.length - 8_926 * 0.3048) < 15, "06L/24R length \(f.length)")
    }
}

struct AirportLightTests {
    @Test func kphxHasItsPublishedLightingSystems() throws {
        let s = try AirportGeometryTests.site("KPHX")
        let lights = AirportLights.build(s)
        let papi = lights.filter { if case .papi = $0.behaviour { return true }; return false }
        // Every KPHX runway end publishes a four-light PAPI (P4L).
        #expect(papi.count == 4 * s.layout.runways.flatMap(\.ends).filter { $0.visualGlideSlope == "P4L" }.count)
        let strobes = lights.filter { if case .flashing(let f, _) = $0.behaviour { return f >= 1.5 }; return false }
        #expect(strobes.count > 10, "approach flashers and REIL")
        #expect(lights.count > 2_000, "\(lights.count) lights")
        print("KPHX lights: \(lights.count), PAPI \(papi.count), strobes \(strobes.count)")
    }

    /// On a 3 degree path a PAPI shows two white and two red; high, all white; low, all red.
    @Test func papiReadsTheGlidePath() throws {
        let s = try AirportGeometryTests.site("KPHX")
        let rw = s.layout.runways.first { $0.name == "08/26" }!
        let f = s.runwayFrame(rw)
        let lights = AirportLights.build(s)
        // The four units beside runway 08, facing its approach (beam toward -axis).
        let units = lights.filter { l in
            guard case .papi = l.behaviour else { return false }
            let local = f.local(SIMD2(l.position.x, l.position.y))
            return local.x < f.length / 2 && abs(local.y) < 120 && simd_dot(SIMD2(l.direction.x, l.direction.y), f.axis) < 0
        }
        #expect(units.count == 4)
        let centre = units.reduce(SIMD3<Double>.zero) { $0 + $1.position } / 4
        func whites(atDegrees a: Double) -> Int {
            let back = SIMD2(-f.axis.x, -f.axis.y) * 1_852
            let eye = centre + SIMD3(back.x, back.y, 1_852 * tan(a * .pi / 180))
            return units.filter { u in
                guard case .papi(let setting) = u.behaviour else { return false }
                let v = eye - u.position
                return atan2(v.z, simd_length(SIMD2(v.x, v.y))) * 180 / .pi > setting
            }.count
        }
        #expect(whites(atDegrees: 3.0) == 2)
        #expect(whites(atDegrees: 3.8) == 4)
        #expect(whites(atDegrees: 2.2) == 0)
    }
}

struct StartSpotTests {
    /// Every final is on the runway's extended centreline, 3 nm before the threshold, at the
    /// threshold elevation plus the crossing height plus 3 nm on the published path.
    @Test(arguments: ["KPHX", "KLAX"])
    func finalsAreOnThePublishedPath(icao: String) throws {
        let s = try AirportGeometryTests.site(icao)
        for r in s.layout.runways {
            let f = s.runwayFrame(r)
            for (k, end) in r.ends.enumerated() {
                let p = try #require(s.placement(.final(end.ident)))
                let local = f.local(SIMD2(p.position.x, p.position.y))
                let threshold = k == 0 ? end.displacedThreshold : f.length - end.displacedThreshold
                #expect(abs(local.y) < 0.5, "\(end.ident) off the centreline by \(local.y) m")
                #expect(abs(abs(local.x - threshold) - 5_556) < 1, "\(end.ident) at \(abs(local.x - threshold)) m")
                let expected = end.elevation + (r.ends[1 - k].elevation - end.elevation) * end.displacedThreshold / f.length
                    + (end.thresholdCrossingHeight ?? 15) + 5_556 * tan((end.glidePathAngle ?? 3) * .pi / 180)
                #expect(abs((p.altitude ?? 0) - expected) < 0.01)
                // Flying toward the threshold.
                let h = p.heading * .pi / 180
                #expect(simd_dot(SIMD2(sin(h), cos(h)), k == 0 ? f.axis : -f.axis) > 0.9999)
            }
        }
    }

    @Test func runwayStartsAreOnTheCentrelineFacingDownTheRunway() throws {
        let s = try AirportGeometryTests.site("KLAX")
        for r in s.layout.runways {
            let f = s.runwayFrame(r)
            for end in r.ends {
                let p = try #require(s.placement(.runway(end.ident)))
                #expect(abs(f.local(SIMD2(p.position.x, p.position.y)).y) < 0.5)
                #expect(p.altitude == nil)
            }
        }
        #expect(s.startSpots.contains(.stand("68B")))
        #expect(s.placement(.stand("68B")) != nil)
    }

    @Test func towerCabIsAtTheMappedTower() throws {
        let s = try AirportGeometryTests.site("KPHX")
        let cab = try #require(s.towerCab)
        #expect(cab.z > 85 && cab.z < 100, "PHX tower cab at \(cab.z) m")
    }
}

import Terrain

/// Physics and cameras stand on the airport surface: the ground model with the airport's
/// overrides returns the same height the meshes are built on.
struct AirportGroundTests {
    @Test(arguments: ["KPHX", "KLAX"])
    func groundModelMatchesTheAirportSurface(icao: String) throws {
        let s = try AirportGeometryTests.site(icao)
        let packs = AirportGeometryTests.dir.deletingLastPathComponent().appendingPathComponent("Scenery")
        var g = GroundModel(scenery: SceneryLibrary(directory: packs), frame: s.frame, flatten: s.overrides)
        for r in s.layout.runways {
            let f = s.runwayFrame(r)
            for t in [0.2, 0.5, 0.8] {
                let p = f.point(f.length * t, 0)
                let z = g.groundZ(atENU: SIMD3(p.x, p.y, 0))
                #expect(abs(z - s.z(p)) < 0.3, "\(icao) \(r.name) at \(t): ground \(z) vs surface \(s.z(p))")
            }
        }
    }
}

struct AirportSignTests {
    @Test func holdSignsAndDistanceRemaining() throws {
        let s = try AirportGeometryTests.site("KPHX")
        let signs = AirportSigns.build(s)
        let holds = signs.filter { $0.front.style == .mandatory }
        #expect(holds.count > 100, "\(holds.count) holding position signs")
        // Every hold sign names a real runway, low-high or high-low.
        let names = Set(s.layout.runways.flatMap { r in [r.name, r.ends.reversed().map(\.ident).joined(separator: "-")] }
            .map { $0.replacingOccurrences(of: "/", with: "-") })
        #expect(holds.allSatisfy { names.contains($0.front.text) })
        // A hold north of 08/26 facing south: 08 (the west end) is on a southbound pilot's right,
        // so the sign reads 26-08.
        let rw = s.layout.runways.first { $0.name == "08/26" }!
        let f = s.runwayFrame(rw)
        let north = s.layout.holdPositions.filter { $0.runway == "08/26" && f.local(s.xy($0.position)).y > 0 && $0.kind == .runway }
        let southbound = try #require(north.first { abs($0.towardRunway - 180) < 30 })
        let sign = try #require(holds.min { simd_distance(SIMD2($0.position.x, $0.position.y), s.xy(southbound.position)) <
                                            simd_distance(SIMD2($1.position.x, $1.position.y), s.xy(southbound.position)) })
        #expect(sign.front.text == "26-08", "southbound hold reads \(sign.front.text)")
        // Direction signs at taxiway junctions, each with an arrow.
        let direction = signs.filter { $0.front.style == .direction }
        #expect(direction.count > 50, "\(direction.count) direction signs")
        #expect(direction.allSatisfy { $0.front.text.unicodeScalars.contains { (0x2190...0x2199).contains($0.value) } })
        // Distance remaining: 11,489 ft runway, signs 1 to 10 for each direction.
        let distance = signs.filter { $0.front.style == .distance }
        #expect(distance.filter { $0.front.text == "10" }.count >= 2)
    }
}

struct TaxiwayCentrelineLightTests {
    /// KLAX (ALSF-2 on 24R and 25L) gets green taxiway centreline lights; KPHX (no CAT II/III
    /// approach system) does not.
    @Test func onlyAtLowVisibilityAirports() throws {
        func greens(_ icao: String) throws -> Int {
            let s = try AirportGeometryTests.site(icao)
            return AirportLights.build(s).filter { $0.colour.y > 0.9 && $0.colour.x < 0.5 && $0.candela == 120 }.count
        }
        #expect(try greens("KLAX") > 500)
        #expect(try greens("KPHX") == 0)
    }
}

struct CityGeometryTests {
    @Test func buildsChunkedCityOnTheGround() throws {
        let s = try AirportGeometryTests.site("KPHX")
        let city = try SurroundingBuildings.load(AirportGeometryTests.dir.appendingPathComponent("KPHX-city.json"))
        let chunks = CityGeometry.build(city, site: s) { _ in 10 }      // flat ground at z = 10
        let triangles = chunks.reduce(0) { $0 + $1.indices.count / 3 }
        print("KPHX city: \(city.buildings.count) buildings, \(chunks.count) chunks, \(triangles) triangles")
        #expect(chunks.count > 20)
        #expect(triangles > city.buildings.count * 6)
        for ch in chunks {
            #expect(ch.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z >= 9.6 && $0.z < 300 })
            #expect(ch.indices.allSatisfy { Int($0) < ch.positions.count })
        }
        // A building's roof sits its height above the ground (base sunk 0.3 m).
        let first = city.buildings[0]
        let roofZ = chunks.flatMap(\.positions).contains { abs(Double($0.z) - (10 + Double(first[0]))) < 0.01 }
        #expect(roofZ)
    }
}
