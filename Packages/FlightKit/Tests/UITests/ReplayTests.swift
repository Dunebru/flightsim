import Foundation
import Renderer
import Testing
@testable import UI

/// Replay keeps the last ten minutes at ten frames a second and interpolates between them,
/// headings the short way across north.
struct ReplayTests {
    @Test func recordsAndInterpolates() throws {
        var r = ReplayBuffer()
        var s = SceneDescription.phoenixTest(date: Date())
        for i in 0..<(60 * 12 * 60) {             // twelve minutes at 60 fps
            let t = Double(i) / 60
            s.aircraftPosition = SIMD3(t * 100, 0, 0)
            s.aircraftHeading = (6.2 + t * 0.01).truncatingRemainder(dividingBy: 2 * .pi)
            r.record(time: t, s)
        }
        #expect(r.duration <= ReplayBuffer.length + 10.1 && r.duration >= ReplayBuffer.length, "\(r.duration)")
        #expect(r.frames.count < 6_200)
        let f = try #require(r.frame(at: 700.05))
        #expect(abs(f.position.x - 70_005) < 0.5, "\(f.position.x)")
        // Across north (2 pi wrap) the heading stays near the recorded ones, not swung round.
        var short = ReplayBuffer()
        for i in 0..<(60 * 20) {
            let t = Double(i) / 60
            s.aircraftHeading = (6.2 + t * 0.01).truncatingRemainder(dividingBy: 2 * .pi)
            short.record(time: t, s)
        }
        let wrapT = (2 * Double.pi - 6.2) / 0.01 + 0.05
        let w = try #require(short.frame(at: wrapT))
        #expect(abs(remainder(w.heading - 2 * .pi, 2 * .pi)) < 0.01, "\(w.heading)")
    }
}
