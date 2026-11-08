import Airports
import Foundation
import Metal
import SimCore
import Testing
import simd
@testable import Renderer

/// Volumetric clouds: coverage against the METAR's meaning, and rendered views for review.
@Suite(.serialized)
struct CloudRenderTests {
    static func bare() throws -> SceneRenderer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let r = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        return r
    }

    static func layer(_ coverage: Double, feet: Double, depth: Double, _ kind: CloudLayer.Kind, field: Double = 340) -> CloudLayer {
        let base = field + feet * 0.3048
        return CloudLayer(baseMetres: base, topMetres: base + depth, coverage: coverage, kind: kind)
    }

    /// Fraction of the ground a layer hides, looking straight down from 12 km over six places
    /// 40 km apart (so the large-scale patchiness averages out).
    static func hidden(_ layer: CloudLayer, _ r: SceneRenderer) throws -> Double {
        var hidden = 0, total = 0
        for i in 0..<6 {
            var s = SceneDescription.phoenixTest(date: TerrainRenderTests.afternoon)
            s.showAircraft = false
            s.showRunway = false
            s.clouds = [layer]
            s.cameraPose = CameraPose(position: SIMD3(Double(i) * 40_000 - 100_000, Double(i % 2) * 40_000, 12_000),
                                      forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), fovY: 90 * .pi / 180)
            r.resetHistory()
            _ = try r.renderImage(s, width: 400, height: 400)
            let t = r.cloudTransmittanceForTest()
            hidden += t.filter { $0 < 0.5 }.count
            total += t.count
        }
        return Double(hidden) / Double(max(total, 1))
    }

    /// FEW is 1-2 eighths of the sky, SCT 3-4, BKN 5-7, OVC all of it; a layer reported with no
    /// coverage draws nothing.
    @Test func coverageMatchesTheReport() throws {
        let r = try Self.bare()
        let none = try Self.hidden(Self.layer(0, feet: 5_000, depth: 1_400, .cumulus), r)
        let few = try Self.hidden(Self.layer(0.19, feet: 5_000, depth: 1_400, .cumulus), r)
        let sct = try Self.hidden(Self.layer(0.44, feet: 5_000, depth: 1_400, .cumulus), r)
        let bkn = try Self.hidden(Self.layer(0.75, feet: 3_000, depth: 500, .stratus), r)
        let ovc = try Self.hidden(Self.layer(1, feet: 1_500, depth: 700, .stratus), r)
        print(String(format: "CLOUDCOVER none %.3f few %.3f sct %.3f bkn %.3f ovc %.3f", none, few, sct, bkn, ovc))
        #expect(none == 0)
        #expect(few > 0.06 && few < 0.3)
        #expect(sct > 0.3 && sct < 0.6)
        #expect(bkn > 0.6 && bkn < 0.92)
        #expect(ovc > 0.97)
    }

    /// The shadow map: an overcast stops the sun everywhere, a scattered layer shades about its
    /// share of the ground, and a layer with no coverage casts nothing.
    @Test func shadowsFollowCoverage() throws {
        let r = try Self.bare()
        func shade(_ layers: [CloudLayer]) throws -> [Float] {
            var s = SceneDescription.phoenixTest(date: TerrainRenderTests.afternoon)
            s.clouds = layers
            _ = try r.renderImage(s, width: 200, height: 120)
            return r.cloudShadowForTest()
        }
        let ovc = try shade([Self.layer(1, feet: 1_500, depth: 700, .stratus)])
        let sct = try shade([Self.layer(0.44, feet: 5_000, depth: 1_400, .cumulus)])
        let none = try shade([Self.layer(0, feet: 5_000, depth: 1_400, .cumulus)])
        let ovcMean = ovc.reduce(0, +) / Float(ovc.count)
        let sctShaded = Float(sct.filter { $0 < 0.5 }.count) / Float(sct.count)
        print(String(format: "CLOUDSHADOW ovc mean %.3f, sct shaded %.2f, none min %.3f", ovcMean, sctShaded, none.min() ?? -1))
        #expect(ovcMean < 0.05)
        #expect(sctShaded > 0.2 && sctShaded < 0.7)
        #expect((none.min() ?? 0) > 0.999)
    }

    /// Mist from the reported visibility washes out the distance: the horizon band loses most of
    /// its contrast at 400 m and keeps it with no report.
    @Test func mistHidesTheDistance() throws {
        let r = try Self.bare()
        func horizonContrast(_ visibility: Double) throws -> Double {
            var s = SceneDescription.phoenixTest(date: TerrainRenderTests.afternoon)
            s.visibilityMetres = visibility
            s.fogScaleHeight = 150
            s.cameraPose = CameraPose(position: SIMD3(0, 0, 3), forward: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1), fovY: 50 * .pi / 180)
            r.resetHistory()
            let img = try r.renderImage(s, width: 320, height: 180)
            // Luminance spread over the rows around the horizon (sky down to ground about 600 m out).
            var values: [Double] = []
            for y in 82..<92 {
                for x in 0..<320 {
                    let i = (y * 320 + x) * 4
                    values.append(0.0722 * Double(img[i]) + 0.7152 * Double(img[i + 1]) + 0.2126 * Double(img[i + 2]))
                }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        let clear = try horizonContrast(40_000), fog = try horizonContrast(400)
        print(String(format: "MIST horizon contrast clear %.1f, 400 m %.1f", clear, fog))
        #expect(clear > 4)
        #expect(fog < clear * 0.25)
    }

    /// Falling snow shows in front of everything, the overcast included (the cloud pass once painted
    /// over it): looking up into a deck, the sky changes where flakes fall, against the same frame dry.
    @Test func precipitationShowsInFrontOfTheClouds() throws {
        let r = try Self.bare()
        var s = SceneDescription.phoenixTest(date: TerrainRenderTests.afternoon)
        s.clouds = [Self.layer(1, feet: 1_500, depth: 700, .stratus)]
        s.cameraPose = CameraPose(position: SIMD3(0, 0, 3), forward: simd_normalize(SIMD3(1, 0, 1)), up: SIMD3(0, 0, 1),
                                  fovY: 60 * .pi / 180)
        func render(_ p: Precipitation?) throws -> [UInt8] {
            var v = s
            v.precipitation = p
            r.resetHistory()
            return try r.renderImage(v, width: 320, height: 180, warmupFrames: 12)
        }
        func changed(_ a: [UInt8], _ b: [UInt8]) -> Int {
            stride(from: 0, to: a.count, by: 4).filter { i in (0..<3).contains { abs(Int(a[i + $0]) - Int(b[i + $0])) > 8 } }.count
        }
        // Snow: rain against a bright overcast is nearly invisible, in life as here.
        let dry = try render(nil), dryAgain = try render(nil), wet = try render(Precipitation(kind: .snow, intensity: 1))
        let noise = changed(dry, dryAgain), drops = changed(dry, wet)
        print("SNOW pixels changed against the deck: \(drops) (dry to dry: \(noise))")
        #expect(drops > noise * 5 + 50)
    }

    @Test func kphxViews() throws {
        let site = try AirportSite.load(AirportRenderTests.airportsURL.appendingPathComponent("KPHX.json"))
        let (r, base) = try AirportRenderTests.scene(site, aircraft: true)
        let field = site.layout.elevation
        let rw08 = site.layout.runways.first { $0.name == "08/26" }!
        let f = site.runwayFrame(rw08)
        let threshold = f.point(rw08.ends[0].displacedThreshold + 20, 0)
        var lined = base
        lined.aircraftPosition = site.onSurface(threshold)
        lined.aircraftHeading = f.heading * .pi / 180
        let behind = threshold - f.axis * 22 + f.left * 6
        lined.cameraPose = CameraPose(position: site.onSurface(behind) + SIMD3(0, 0, 4),
                                      forward: simd_normalize(SIMD3(f.axis.x, f.axis.y, 0.12)), up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        var views: [(String, SceneDescription)] = []
        var sct = lined
        sct.clouds = [Self.layer(0.44, feet: 5_500, depth: 1_400, .cumulus, field: field),
                      Self.layer(0.6, feet: 25_000, depth: 400, .cirrus, field: field)]
        views.append(("clouds-kphx-sct", sct))
        var bkn = lined
        bkn.clouds = [Self.layer(0.75, feet: 3_000, depth: 500, .stratus, field: field)]
        views.append(("clouds-kphx-bkn", bkn))
        var ovc = lined
        ovc.clouds = [Self.layer(1, feet: 1_500, depth: 700, .stratus, field: field)]
        views.append(("clouds-kphx-ovc", ovc))
        var cb = base
        cb.showAircraft = false
        cb.clouds = [CloudLayer(baseMetres: field + 1_400, topMetres: 11_000, coverage: 0.19, kind: .cumulonimbus),
                     Self.layer(0.19, feet: 6_000, depth: 1_400, .cumulus, field: field)]
        cb.cameraPose = CameraPose(position: SIMD3(-3_000, -2_000, 900), forward: simd_normalize(SIMD3(1, 0.3, 0.08)),
                                   up: SIMD3(0, 0, 1), fovY: 65 * .pi / 180)
        views.append(("clouds-kphx-cb", cb))
        var above = base
        above.showAircraft = false
        above.clouds = [Self.layer(0.75, feet: 4_000, depth: 600, .stratus, field: field),
                        Self.layer(0.3, feet: 8_000, depth: 1_400, .cumulus, field: field)]
        above.cameraPose = CameraPose(position: SIMD3(0, -8_000, 4_200), forward: simd_normalize(SIMD3(0.3, 1, -0.12)),
                                      up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("clouds-kphx-above", above))
        var mist = ovc
        mist.clouds = [Self.layer(1, feet: 400, depth: 500, .stratus, field: field)]
        mist.visibilityMetres = 2_400
        mist.fogScaleHeight = 400
        views.append(("clouds-kphx-mist", mist))
        var fog = lined
        fog.clouds = []
        fog.visibilityMetres = 400
        fog.fogScaleHeight = 120
        fog.date = RendererTests.time(whenSunAt: -8, afternoon: true)
        views.append(("clouds-kphx-fog-night", fog))
        var rain = lined
        rain.clouds = [Self.layer(0.75, feet: 2_500, depth: 600, .stratus, field: field),
                       Self.layer(1, feet: 6_000, depth: 900, .stratus, field: field)]
        rain.visibilityMetres = 6_000
        rain.fogScaleHeight = 800
        rain.precipitation = Precipitation(kind: .rain, intensity: 0.65)
        rain.wetness = 1
        views.append(("clouds-kphx-rain", rain))
        var snow = rain
        snow.precipitation = Precipitation(kind: .snow, intensity: 0.65)
        snow.wetness = 0.3
        snow.visibilityMetres = 3_000
        views.append(("clouds-kphx-snow", snow))
        var dusk = sct
        dusk.date = RendererTests.time(whenSunAt: 6, afternoon: true)
        dusk.cameraPose = CameraPose(position: site.onSurface(behind) + SIMD3(0, 0, 4),
                                     forward: simd_normalize(SIMD3(-f.axis.x, -f.axis.y, 0.1)), up: SIMD3(0, 0, 1), fovY: 60 * .pi / 180)
        views.append(("clouds-kphx-golden", dusk))
        for (name, s) in views {
            r.exposureAdaptation = 1
            try TerrainRenderTests.settle(r, s, limit: .seconds(60))
            r.resetHistory()
            // Clouds accumulate over frames (the jittered march is resolved temporally).
            let img = try r.renderImage(s, width: 1600, height: 900, warmupFrames: 24)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
    }

    /// GPU time of the cloud pass at the phone's render size (Mac GPU): reported, not gated.
    @Test func cloudCost() throws {
        let r = try Self.bare()
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 884, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        let target = try #require(r.device.makeTexture(descriptor: d))
        var s = SceneDescription.phoenixTest(date: TerrainRenderTests.afternoon)
        s.clouds = [Self.layer(0.44, feet: 5_000, depth: 1_400, .cumulus), Self.layer(0.75, feet: 12_000, depth: 500, .stratus)]
        s.cameraPose = CameraPose(position: SIMD3(0, 0, 300), forward: simd_normalize(SIMD3(1, 0, 0.05)), up: SIMD3(0, 0, 1),
                                  fovY: 55 * .pi / 180)
        for _ in 0..<60 { r.render(s, to: target).waitUntilCompleted() }
        let st = r.stats
        print(String(format: "CLOUDCOST 1920x884: clouds %.2f ms, frame %.2f ms", st.gpuMilliseconds["Clouds"] ?? -1, st.gpuFrameMilliseconds))
    }
}
