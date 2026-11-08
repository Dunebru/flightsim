import Aircraft
import Airports
import Foundation
import Metal
import SimCore
import Terrain
import Testing
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
        r.setAirports(others.map { ($0, AirportGeometry.build($0), AirportLights.build($0)) }, sceneOrigin: site.frame.origin)
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
}
