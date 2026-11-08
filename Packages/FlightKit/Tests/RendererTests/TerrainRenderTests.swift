import Aircraft
import Foundation
import Metal
import SimCore
import Terrain
import Testing
import simd
@testable import Renderer

/// Real terrain from the baked KPHX scenery pack (Data/Bundle/Scenery/kphx, made by
/// `flight-tools terrain-bake`), rendered headless through the app's renderer.
@Suite(.serialized)
struct TerrainRenderTests {
    static let packURL = RendererTests.repoRoot.appendingPathComponent("Data/Bundle/Scenery/kphx")
    static let afternoon = RendererTests.date("2026-06-21T22:00:00Z")   // 15:00 MST, sun about 55 degrees up

    static func renderer(terrain: Bool) throws -> SceneRenderer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        if terrain {
            let pack = try SceneryPack(root: packURL)
            r.setTerrain(pack, origin: PhoenixSite.origin, flatten: PhoenixSite.flatten)
        }
        return r
    }

    /// Renders until the streamer has nothing left to load for this view (or a time limit).
    static func settle(_ r: SceneRenderer, _ s: SceneDescription, limit: Duration = .seconds(30)) throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 180, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        let target = try #require(r.device.makeTexture(descriptor: d))
        let start = ContinuousClock.now
        var quiet = 0
        while ContinuousClock.now - start < limit {
            r.render(s, to: target).waitUntilCompleted()
            quiet = r.terrainPending == 0 ? quiet + 1 : 0
            if quiet >= 3 { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        Issue.record("terrain still loading after \(limit): \(r.terrainPending) pending")
    }

    static func view(from p: SIMD3<Double>, toward t: SIMD3<Double>, fov: Double = 60) -> SceneDescription {
        var s = SceneDescription.phoenixTest(date: afternoon)
        s.showAircraft = false
        let f = simd_normalize(t - p)
        s.cameraPose = CameraPose(position: p, forward: f, up: SIMD3(0, 0, 1), fovY: fov * .pi / 180)
        return s
    }

    static func luminance(_ img: [UInt8], _ w: Int, x: Int, y: Int) -> Double {
        let i = (y * w + x) * 4
        return 0.0722 * Double(img[i]) + 0.7152 * Double(img[i + 1]) + 0.2126 * Double(img[i + 2])
    }

    /// Terrain streams in around the camera: coarse tiles everywhere, the finest level near it,
    /// within the memory budget, and tiles outside the view are not drawn.
    @Test func terrainStreamsAndCulls() throws {
        let r = try Self.renderer(terrain: true)
        let s = Self.view(from: SIMD3(0, -2_000, 600), toward: SIMD3(0, 8_000, 0))
        try Self.settle(r, s)
        let resident = r.terrainResident
        #expect(resident.tiles > 20, "resident tiles: \(resident.tiles)")
        #expect(resident.megabytes < 256)
        let drawnLooking = r.terrainDrawn
        #expect(drawnLooking > 4)
        // Same position, looking straight up: nothing on the ground is in view.
        var up = s
        up.cameraPose = CameraPose(position: SIMD3(0, -2_000, 600), forward: SIMD3(0, 0.01, 1), up: SIMD3(0, 1, 0), fovY: 1)
        _ = try r.renderImage(up, width: 64, height: 64)
        #expect(r.terrainDrawn < drawnLooking / 2, "culling: \(r.terrainDrawn) of \(drawnLooking) drawn looking up")
    }

    /// The pavement stays visible on top of the terrain: drawing the runway must change the
    /// pixels where it lies and nothing else. Negative control: with the flattened ground raised
    /// 2 m above the pavement, the runway disappears and the same check fails.
    @Test func runwayIsNotBuriedByTerrain() throws {
        func bandDifference(flattenRaise: Double) throws -> (band: Double, outside: Double) {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
            r.settings = RenderSettings(upscaler: .off, renderScale: 1)
            let areas = PhoenixSite.flatten.map { a in var a = a; a.height += flattenRaise; return a }
            r.setTerrain(try SceneryPack(root: Self.packURL), origin: PhoenixSite.origin, flatten: areas)
            // Straight down over the runway centre from 400 m; the runway runs left to right.
            var s = Self.view(from: SIMD3(0, 0, 400), toward: SIMD3(0, 0, 0), fov: 30)
            s.cameraPose?.up = SIMD3(0, 1, 0)
            try Self.settle(r, s)
            let w = 400, h = 400
            let with = try r.renderImage(s, width: w, height: h)
            if flattenRaise == 0 { try RendererTests.savePNG(with, w, h, name: "terrain-runway-topdown") }
            var without = s
            without.showRunway = false
            r.resetHistory()
            let bare = try r.renderImage(without, width: w, height: h)
            func meanDiff(rows: Range<Int>) -> Double {
                var sum = 0.0, n = 0
                for y in rows { for x in 0..<w {
                    sum += abs(Self.luminance(with, w, x: x, y: y) - Self.luminance(bare, w, x: x, y: y)); n += 1
                } }
                return sum / Double(n)
            }
            // The runway (45.7 m of a 214 m view) covers rows h/2 +- 42.
            return (meanDiff(rows: (h / 2 - 30)..<(h / 2 + 30)), meanDiff(rows: 0..<(h / 2 - 70)))
        }
        let normal = try bandDifference(flattenRaise: 0)
        #expect(normal.band > 8, "runway band changed by \(normal.band)")
        #expect(normal.outside < 1, "away from the runway changed by \(normal.outside)")
        let buried = try bandDifference(flattenRaise: 2)
        #expect(buried.band < 1, "negative control: buried runway still changed the band by \(buried.band)")
    }

    /// Snapshots for checking by eye (artifacts/renders).
    @Test func terrainSnapshots() throws {
        let r = try Self.renderer(terrain: true)
        let views: [(String, SceneDescription)] = [
            // 3 nm final for runway 08 at about 950 ft, looking along the runway.
            ("terrain-final08", Self.view(from: PhoenixSite.centreline(-1_751 - 5_556) + SIMD3(0, 0, 290),
                                          toward: PhoenixSite.centreline(-1_000))),
            // South Mountain from 1,500 m over the field.
            ("terrain-south", Self.view(from: SIMD3(0, 0, 1_500), toward: SIMD3(0, -12_000, 500))),
            // North-east toward the McDowell and Mazatzal mountains from 4,000 m.
            ("terrain-northeast", Self.view(from: SIMD3(-10_000, -10_000, 4_000), toward: SIMD3(30_000, 30_000, 500))),
            // Cruise: 10,000 m, looking west.
            ("terrain-cruise", Self.view(from: SIMD3(0, 0, 10_000), toward: SIMD3(-80_000, 0, 0))),
        ]
        for (name, s) in views {
            try Self.settle(r, s)
            r.resetHistory()
            let img = try r.renderImage(s, width: 1200, height: 540)
            try RendererTests.savePNG(img, 1200, 540, name: name)
        }
        // The M1 scene (aircraft at the runway 08 threshold) with terrain behind it.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let text = try String(contentsOf: RendererTests.c172Dir.appendingPathComponent("c172-common.ac"), encoding: .isoLatin1)
        let withPlane = try SceneRenderer(device: device, aircraftModel: try AC3DParser.parse(text), aircraftTextures: RendererTests.c172Dir)
        withPlane.settings = RenderSettings(upscaler: .off, renderScale: 1)
        withPlane.setTerrain(try SceneryPack(root: Self.packURL), origin: PhoenixSite.origin, flatten: PhoenixSite.flatten)
        let scene = SceneDescription.phoenixTest(date: Self.afternoon)
        try Self.settle(withPlane, scene)
        let img = try withPlane.renderImage(scene, width: 1200, height: 540)
        try RendererTests.savePNG(img, 1200, 540, name: "terrain-threshold")
    }
}
