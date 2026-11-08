import Aircraft
import Airports
import Foundation
import Metal
import SimCore
import Terrain
import Testing
import Traffic
import simd
@testable import Renderer

/// The generated airports on real terrain, rendered headless for review (artifacts/renders).
@Suite(.serialized)
struct AirportRenderTests {
    static let airportsURL = RendererTests.repoRoot.appendingPathComponent("Data/Bundle/Airports")

    static func scene(_ site: AirportSite, aircraft: Bool) throws -> (SceneRenderer, SceneDescription) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var model: AC3DModel?
        if aircraft {
            let text = try String(contentsOf: RendererTests.c172Dir.appendingPathComponent("c172-common.ac"), encoding: .isoLatin1)
            model = try AC3DParser.parse(text)
        }
        let r = try SceneRenderer(device: device, aircraftModel: model, aircraftTextures: aircraft ? RendererTests.c172Dir : nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        r.setTerrain(SceneryLibrary(directory: TerrainRenderTests.libraryURL), origin: site.frame.origin, flatten: site.overrides)
        let others = try ["KPHX", "KLAX"].map { try AirportSite.load(airportsURL.appendingPathComponent("\($0).json")) }
        let packs = SceneryLibrary(directory: TerrainRenderTests.libraryURL)
        r.setAirports(try others.map { s in
            let surroundings = try SurroundingBuildings.load(airportsURL.appendingPathComponent("\(s.layout.icao)-city.json"))
            var ground = GroundModel(scenery: packs, frame: s.frame, flatten: s.overrides)
            let city = CityGeometry.build(surroundings, site: s) { p in ground.groundZ(atENU: SIMD3(p.x, p.y, 0)) }
            return AirportAssets(site: s, geometry: AirportGeometry.build(s), lights: AirportLights.build(s), city: city)
        }, sceneOrigin: site.frame.origin)
        var s = SceneDescription.phoenixTest(date: TerrainRenderTests.afternoon)
        s.origin = site.frame.origin
        s.showAircraft = aircraft
        return (r, s)
    }

    @Test func kphxViews() throws {
        let site = try AirportSite.load(Self.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try Self.scene(site, aircraft: true)
        let rw08 = site.layout.runways.first { $0.name == "08/26" }!
        let f = site.runwayFrame(rw08)
        let threshold = f.point(rw08.ends[0].displacedThreshold + 20, 0)
        var views: [(String, SceneDescription)] = []

        // Aircraft lined up on 08 at the displaced threshold, chase view.
        var lined = base
        lined.aircraftPosition = site.onSurface(threshold)
        lined.aircraftHeading = f.heading * .pi / 180
        let behind = threshold - f.axis * 22 + f.left * 6
        lined.cameraPose = CameraPose(position: site.onSurface(behind) + SIMD3(0, 0, 4),
                                      forward: simd_normalize(SIMD3(f.axis.x, f.axis.y, -0.08)), up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("kphx-08-lineup", lined))

        var top = base
        top.showAircraft = false
        top.cameraPose = CameraPose(position: SIMD3(-500, 0, 1_800), forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), fovY: 60 * .pi / 180)
        views.append(("kphx-topdown", top))

        var final = base
        final.showAircraft = false
        let rw = site.layout.runways.first { $0.name == "07R/25L" }!
        let fr = site.runwayFrame(rw)
        let eye = fr.point(-2_500, 0)
        final.cameraPose = CameraPose(position: SIMD3(eye.x, eye.y, site.z(eye) + 135),
                                      forward: simd_normalize(SIMD3(fr.axis.x, fr.axis.y, -0.06)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)
        views.append(("kphx-07r-final", final))

        var terminal = base
        terminal.showAircraft = false
        terminal.cameraPose = CameraPose(position: SIMD3(600, -900, 120), forward: simd_normalize(SIMD3(0.2, 1, -0.25)),
                                         up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("kphx-terminals", terminal))

        // Close-ups: the 08 designation from a pilot's eye height, and from above.
        var eyeView = base
        eyeView.showAircraft = false
        let eyeAt = f.point(rw08.ends[0].displacedThreshold - 60, 0)
        eyeView.cameraPose = CameraPose(position: site.onSurface(eyeAt) + SIMD3(0, 0, 3.5),
                                        forward: simd_normalize(SIMD3(f.axis.x, f.axis.y, -0.05)), up: SIMD3(0, 0, 1), fovY: 40 * .pi / 180)
        views.append(("kphx-08-pilot-eye", eyeView))
        var numbers = base
        numbers.showAircraft = false
        let over = f.point(rw08.ends[0].displacedThreshold + 70, 0)
        numbers.cameraPose = CameraPose(position: site.onSurface(over) + SIMD3(0, 0, 90),
                                        forward: SIMD3(0, 0, -1), up: SIMD3(f.axis.x, f.axis.y, 0), fovY: 50 * .pi / 180)
        views.append(("kphx-08-numbers-top", numbers))

        // A gate at Terminal 4 with its boarding bridge, by day and at night.
        if let stand = site.layout.stands.first(where: { $0.ref == "F11" }) ?? site.layout.stands.first(where: { $0.line.count >= 2 }),
           let placement = site.placement(.stand(stand.ref ?? "")) {
            let h = placement.heading * .pi / 180
            let fwd = SIMD2(sin(h), cos(h))
            var gate = base
            gate.aircraftPosition = placement.position
            gate.aircraftHeading = h
            let eye = SIMD2(placement.position.x, placement.position.y) - fwd * 45 + SIMD2(fwd.y, -fwd.x) * 25
            gate.cameraPose = CameraPose(position: site.onSurface(eye) + SIMD3(0, 0, 12),
                                         forward: simd_normalize(placement.position + SIMD3(0, 0, 3) - (site.onSurface(eye) + SIMD3(0, 0, 12))),
                                         up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
            views.append(("kphx-gate", gate))
            var gateNight = gate
            gateNight.date = RendererTests.time(whenSunAt: -20, afternoon: true)
            views.append(("kphx-gate-night", gateNight))
        }

        // Taxiing up to a junction: the direction sign array on the left.
        if let sign = AirportSigns.build(site).first(where: { $0.front.style == .direction && simd_length(SIMD2($0.position.x, $0.position.y)) < 1_500 }) {
            let f = sign.facing * .pi / 180
            let n = SIMD2(sin(f), cos(f)), right = SIMD2(-n.y, n.x)
            let eye = SIMD2(sign.position.x, sign.position.y) + n * 32 + right * 10
            var junction = base
            junction.showAircraft = false
            junction.cameraPose = CameraPose(position: site.onSurface(eye) + SIMD3(0, 0, 3.5),
                                             forward: simd_normalize(SIMD3(-n.x, -n.y, -0.06)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)
            views.append(("kphx-taxi-junction", junction))
        }

        // The city north of the field from 250 m, looking north: shadows fall to the right.
        var city = base
        city.showAircraft = false
        city.cameraPose = CameraPose(position: SIMD3(-1_500, 1_800, 250), forward: simd_normalize(SIMD3(0.15, 1, -0.45)),
                                     up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("kphx-city-north", city))

        // At a holding position north of 08/26, looking south at the runway and its signs.
        let hold = site.layout.holdPositions.first { h in
            h.runway == "08/26" && h.kind == .runway && abs(h.towardRunway - 180) < 20 && f.local(site.xy(h.position)).x > 600
        }!
        let hp = site.xy(hold.position)
        let ha = hold.towardRunway * .pi / 180
        let hf = SIMD2(sin(ha), cos(ha))
        var atHold = base
        atHold.showAircraft = false
        let eyeHold = hp - hf * 35
        atHold.cameraPose = CameraPose(position: site.onSurface(eyeHold) + SIMD3(0, 0, 3.5),
                                       forward: simd_normalize(SIMD3(hf.x, hf.y, -0.08)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)
        views.append(("kphx-hold-08-26", atHold))
        var holdNight = atHold
        holdNight.date = RendererTests.time(whenSunAt: -20, afternoon: true)
        views.append(("kphx-hold-08-26-night", holdNight))

        // The 07R approach at dusk and at night: approach lights, PAPI, edge and taxiway lights.
        for (label, elevation) in [("dusk", -4.0), ("night", -20.0)] {
            var v = final
            v.date = RendererTests.time(whenSunAt: elevation, afternoon: true)
            views.append(("kphx-07r-final-\(label)", v))
        }

        for (name, s) in views {
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            let img = try r.renderImage(s, width: 1600, height: 900)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
    }

    @Test func klaxViews() throws {
        let site = try AirportSite.load(Self.airportsURL.appendingPathComponent("KLAX.json"))
        let (r, base) = try Self.scene(site, aircraft: true)
        let rw = site.layout.runways.first { $0.name == "07L/25R" }!
        let f = site.runwayFrame(rw)
        var views: [(String, SceneDescription)] = []
        // Lined up on 25R (the high end), chase view.
        var lined = base
        let start = try #require(site.placement(.runway("25R")))
        lined.aircraftPosition = start.position
        lined.aircraftHeading = start.heading * .pi / 180
        let back = SIMD2(-sin(start.heading * .pi / 180), -cos(start.heading * .pi / 180))
        let eye = SIMD2(start.position.x, start.position.y) + back * 22
        lined.cameraPose = CameraPose(position: SIMD3(eye.x, eye.y, start.position.z + 4),
                                      forward: simd_normalize(SIMD3(-back.x, -back.y, -0.08)), up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("klax-25r-lineup", lined))
        // The central terminal area from 300 m.
        var terminals = base
        terminals.showAircraft = false
        terminals.cameraPose = CameraPose(position: SIMD3(-200, -1_300, 300), forward: simd_normalize(SIMD3(0, 1, -0.35)),
                                          up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("klax-terminals", terminals))
        // 24R final from 3 nm at dusk.
        var final = base
        final.showAircraft = false
        let p = try #require(site.placement(.final("24R")))
        let h = p.heading * .pi / 180
        final.cameraPose = CameraPose(position: SIMD3(p.position.x, p.position.y, (p.altitude ?? 0) - site.frame.origin.height),
                                      forward: simd_normalize(SIMD3(sin(h), cos(h), -0.055)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)
        final.date = RendererTests.time(whenSunAt: -4, afternoon: true)
        views.append(("klax-24r-final-dusk", final))
        // Climbing out west over the Pacific in the afternoon: the sun's glint on the sea.
        var ocean = base
        ocean.showAircraft = false
        ocean.cameraPose = CameraPose(position: SIMD3(-4_500, -300, 450), forward: simd_normalize(SIMD3(-1, -0.15, -0.12)),
                                      up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        ocean.date = RendererTests.date("2026-06-21T23:30:00Z")
        views.append(("klax-pacific", ocean))
        _ = f
        for (name, s) in views {
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            let img = try r.renderImage(s, width: 1600, height: 900)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
    }

    /// KPHX with its traffic running: an arrival on short final over the city, aircraft taxiing
    /// and lined up, seen from the tower's side of the field.
    @Test func kphxTraffic() throws {
        let site = try AirportSite.load(Self.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try Self.scene(site, aircraft: false)
        let traffic = AirportTraffic(site: site, excludingStand: nil, seed: 3)
        traffic.warmUp(seconds: 900)
        var instances = TrafficInstances(narrow: [], wide: [])
        for a in traffic.snapshot {
            let v = SIMD8<Float>(Float(a.position.x), Float(a.position.y), Float(a.position.z), Float(a.heading),
                                 Float(a.seed), Float(a.pitch), Float(a.roll), Float(a.lights))
            if a.widebody { instances.wide.append(v) } else { instances.narrow.append(v) }
        }
        print("TRAFFIC render: \(traffic.snapshot.count) aircraft, \(traffic.snapshot.filter(\.onGround).count) on the ground")
        var s = base
        s.traffic = ["KPHX": instances]
        // Close to one taxiing and to one in the air.
        let taxiing = try #require(traffic.snapshot.first { $0.onGround })
        let flying = traffic.snapshot.first { !$0.onGround }
        var views: [(String, SIMD3<Double>, SIMD3<Double>)] = []
        let t = taxiing.position
        views.append(("kphx-traffic-taxi", t + SIMD3(-90, -110, 35), t))
        if let f = flying {
            let side = SIMD3(cos(f.heading), -sin(f.heading), 0)
            views.append(("kphx-traffic-air", f.position + side * 160 + SIMD3(0, 0, 20), f.position))
        }
        // And the same at night, from the threshold of the runway in use: the arrivals' landing
        // lights strung out on final, taxiing aircraft with their beacons.
        if let rw = traffic.activeRunwayGeometry.first {
            let eye = rw.threshold - rw.direction * 300
            views.append(("kphx-traffic-night", SIMD3(eye.x, eye.y, site.z(eye) + 30), SIMD3(eye.x, eye.y, site.z(eye) + 30)
                          - SIMD3(rw.direction.x, rw.direction.y, 0) * 1_000 + SIMD3(0, 0, 40)))
        }
        for (name, eye, look) in views {
            if name.hasSuffix("night") { s.date = RendererTests.time(whenSunAt: -12, afternoon: true) }
            s.cameraPose = CameraPose(position: eye, forward: simd_normalize(look - eye), up: SIMD3(0, 0, 1), fovY: 50 * .pi / 180)
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            let img = try r.renderImage(s, width: 1600, height: 900)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
        #expect(r.parkedDrawn > traffic.snapshot.count)
    }

    /// GPU time for the heaviest views (Mac GPU; the phone is measured separately). Reported, not
    /// gated: there is no phone budget to compare against on this machine.
    @Test func frameCost() throws {
        let site = try AirportSite.load(Self.airportsURL.appendingPathComponent("KLAX.json"))
        let (r, base) = try Self.scene(site, aircraft: true)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        let device = r.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 884, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        let target = try #require(device.makeTexture(descriptor: d))
        let p = try #require(site.placement(.final("24R")))
        let h = p.heading * .pi / 180
        var s = base
        s.cameraPose = CameraPose(position: SIMD3(p.position.x, p.position.y, (p.altitude ?? 0) - site.frame.origin.height),
                                  forward: simd_normalize(SIMD3(sin(h), cos(h), -0.055)), up: SIMD3(0, 0, 1), fovY: 55 * .pi / 180)
        try TerrainRenderTests.settle(r, s, limit: .seconds(60))
        var spans: [Double] = []
        for _ in 0..<60 {
            let cb = r.render(s, to: target)
            cb.waitUntilCompleted()
            spans.append(r.stats.gpuFrameMilliseconds)
        }
        let st = r.stats
        print(String(format: "FRAMECOST klax-24r-final 1920x884: GPU frame %.2f ms (stages: %@), terrain drawn %d, city chunks %d",
                     spans.last ?? 0, st.gpuMilliseconds.map { String(format: "%@ %.2f", $0.key, $0.value) }.sorted().joined(separator: ", "),
                     r.terrainDrawn, r.cityChunksDrawn))
    }
}
