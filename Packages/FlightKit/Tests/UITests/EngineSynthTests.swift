import Foundation
import Testing
@testable import UI

/// The synthesized sound follows the flight's numbers (checked by measurement, not by ear).
struct EngineSynthTests {
    static func render(_ p: SoundParameters, seconds: Double = 1) -> [Float] {
        var synth = EngineSynth(sampleRate: 48_000)
        synth.target = p
        var out = [Float](repeating: 0, count: Int(48_000 * seconds))
        // Settle past the easing first.
        var warm = [Float](repeating: 0, count: 24_000)
        warm.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, frames: 24_000) }
        out.withUnsafeMutableBufferPointer { b in
            for start in stride(from: 0, to: b.count, by: 512) {
                synth.render(into: b.baseAddress! + start, frames: min(512, b.count - start))
            }
        }
        return out
    }

    static func rms(_ x: [Float]) -> Double { (x.map { Double($0 * $0) }.reduce(0, +) / Double(x.count)).squareRoot() }

    /// The period by autocorrelation between 20 and 200 Hz: the shortest lag that correlates
    /// nearly as well as the best (multiples of the period correlate as well, and picking the
    /// largest would report a fraction of the frequency).
    static func fundamental(_ x: [Float]) -> Double {
        let lags = Array(240...2_400)
        let r = lags.map { lag in
            stride(from: 0, to: 24_000, by: 2).reduce(0.0) { $0 + Double(x[$1] * x[$1 + lag]) }
        }
        let best = r.max() ?? 0
        let first = lags.indices.first { i in
            r[i] > 0.9 * best && (i == 0 || r[i] >= r[i - 1]) && (i == lags.count - 1 || r[i] >= r[i + 1])
        } ?? 0
        return 48_000 / Double(lags[first])
    }

    @Test func pistonNoteFollowsRPM() {
        var p = SoundParameters()
        p.piston = true
        p.throttle = 1
        p.rpm = 2_400
        let full = Self.render(p)
        p.rpm = 1_200
        let half = Self.render(p)
        let f1 = Self.fundamental(full), f2 = Self.fundamental(half)
        print(String(format: "SOUND piston 2400 rpm %.1f Hz, 1200 rpm %.1f Hz", f1, f2))
        // Four cylinders fire twice a revolution: 80 Hz and 40 Hz.
        #expect(abs(f1 - 80) < 3)
        #expect(abs(f2 - 40) < 2)
    }

    @Test func louderWithPowerAndSilentWhenStill() {
        var jet = SoundParameters()
        jet.piston = false
        jet.n1 = 25
        let idle = Self.rms(Self.render(jet))
        jet.n1 = 95
        jet.throttle = 1
        let takeoff = Self.rms(Self.render(jet))
        let off = Self.rms(Self.render(SoundParameters()))
        print(String(format: "SOUND jet idle %.4f, takeoff %.4f, off %.6f", idle, takeoff, off))
        #expect(takeoff > idle * 2.5)
        #expect(off < 0.001)
    }

    @Test func windGrowsWithAirspeed() {
        var p = SoundParameters()
        p.onGround = false
        p.airspeedKnots = 60
        let slow = Self.rms(Self.render(p))
        p.airspeedKnots = 150
        let fast = Self.rms(Self.render(p))
        #expect(fast > slow * 3)
    }
}
