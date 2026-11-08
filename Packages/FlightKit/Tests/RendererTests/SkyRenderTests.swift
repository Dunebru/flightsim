import Foundation
import Metal
import SimCore
import Testing
import simd
@testable import Renderer

/// Stars and the Moon over KPHX, rendered for review, with a check that stars come out at night.
@Suite(.serialized)
struct SkyRenderTests {
    static let stars = RendererTests.repoRoot.appendingPathComponent("Data/Bundle/Sky/stars.bin")

    static func renderer() throws -> SceneRenderer {
        let r = try SceneRenderer(device: try #require(MTLCreateSystemDefaultDevice()), aircraftModel: nil, aircraftTextures: nil)
        r.settings = RenderSettings(upscaler: .off, renderScale: 1)
        r.setStars(try SkyStar.load(Self.stars))
        return r
    }

    /// Looking up at night there are many points of light; by day there are none.
    @Test func starsComeOutAtNight() throws {
        let r = try Self.renderer()
        func points(_ date: Date) throws -> Int {
            var s = SceneDescription.phoenixTest(date: date)
            s.showAircraft = false
            s.cameraPose = CameraPose(position: SIMD3(0, 0, 3), forward: simd_normalize(SIMD3(0, -1, 1.2)), up: SIMD3(0, 0, 1),
                                      fovY: 70 * .pi / 180)
            r.resetHistory()
            let img = try r.renderImage(s, width: 480, height: 270)
            // Points of light: pixels brighter than all eight neighbours by a clear margin.
            func g(_ x: Int, _ y: Int) -> Int { Int(img[(y * 480 + x) * 4 + 1]) }
            var n = 0
            for y in 1..<269 {
                for x in 1..<479 {
                    let v = g(x, y)
                    guard v > 30 else { continue }
                    var peak = true, lowest = 255
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let w = g(x + dx, y + dy)
                        if w > v { peak = false }
                        lowest = min(lowest, w)
                    } }
                    if peak && v - lowest > 20 { n += 1 }
                }
            }
            return n
        }
        let night = try points(RendererTests.time(whenSunAt: -30, afternoon: true))
        let day = try points(TerrainRenderTests.afternoon)
        print("STARS points of light: night \(night), day \(day)")
        // At this size only stars brighter than about magnitude 3.5 clear the threshold, a few
        // dozen in this part of the sky; by day the sky drowns them all.
        #expect(night > 15)
        #expect(day < 3)
    }

    @Test func nightViews() throws {
        let r = try Self.renderer()
        let lat = 33.434, lon = -112.012
        var views: [(String, Date, CameraPose)] = []
        // Orion high in the south on a January evening (8 pm local).
        views.append(("sky-orion", ISO8601DateFormatter().date(from: "2026-01-16T03:00:00Z")!,
                      CameraPose(position: SIMD3(0, 0, 3), forward: simd_normalize(SIMD3(0.15, -1, 0.75)), up: SIMD3(0, 0, 1), fovY: 75 * .pi / 180)))
        // A gibbous moon in a dark sky: search early 2026 for one.
        var found: (Date, SIMD3<Double>)?
        var d = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        while found == nil, d < ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")! {
            let m = Celestial.moon(at: d, latitude: lat, longitude: lon)
            let sun = SolarEphemeris.sunPosition(at: d, latitude: lat, longitude: lon).directionENU
            if sun.z < -0.25, m.direction.z > 0.45, m.direction.z < 0.75, m.illuminated > 0.55, m.illuminated < 0.85 { found = (d, m.direction) }
            d.addTimeInterval(1_800)
        }
        let (moonDate, moonDir) = try #require(found)
        print("MOON gibbous at \(moonDate)")
        views.append(("sky-moon-close", moonDate, CameraPose(position: SIMD3(0, 0, 3), forward: moonDir, up: SIMD3(0, 0, 1), fovY: 2.5 * .pi / 180)))
        let level = simd_normalize(SIMD3(moonDir.x, moonDir.y, 0))
        views.append(("sky-moonlit", moonDate, CameraPose(position: SIMD3(0, 0, 60), forward: simd_normalize(level + SIMD3(0, 0, 0.35)),
                                                         up: SIMD3(0, 0, 1), fovY: 70 * .pi / 180)))
        for (name, date, pose) in views {
            var s = SceneDescription.phoenixTest(date: date)
            s.showAircraft = false
            s.cameraPose = pose
            r.resetHistory()
            let img = try r.renderImage(s, width: 1600, height: 900)
            try RendererTests.savePNG(img, 1600, 900, name: name)
        }
    }
}
