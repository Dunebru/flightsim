import Foundation
import Testing
@testable import UI

/// The A320's engines play FlightGear's CFM56 recordings, mixed by N1.
struct TurbineSampleTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Data/Bundle/Sounds/CFM56").standardized

    /// A recording whose end does not meet its start (a 0.8 jump, like the raw files' 0.27)
    /// loops without the step once its tail is crossfaded in.
    @Test func loopSeamIsSmooth() {
        let rate = 32_000.0
        let raw = (0..<32_000).map { i in Float(sin(Double(i) * 2 * .pi * 220 / rate)) * 0.5 + Float(i) / 32_000 * 0.8 }
        print("raw seam \(abs(raw.last! - raw.first!))")
        var loop = SampleLoop(samples: raw, sampleRate: rate, level: 0.35)
        var out: [Float] = []
        for _ in 0..<(loop.samples.count + 2_000) { out.append(loop.next(step: 1)) }
        let jumps = zip(out, out.dropFirst()).map { abs($0 - $1) }
        let wrap = loop.samples.count - 1
        let typical = jumps.sorted()[jumps.count * 99 / 100]
        print("jump at the wrap \(jumps[wrap]), 99th percentile \(typical)")
        #expect(jumps[wrap] < typical * 1.5)
    }

    @Test func mixFollowsN1() {
        let idle = TurbineMix.layers(n1: 21, exterior: true, reverser: 0)
        let takeoff = TurbineMix.layers(n1: 92, exterior: true, reverser: 0)
        #expect(idle["ext-cfm-buzz"]!.gain < 0.001, "no buzz-saw at idle")
        #expect(takeoff["ext-cfm-buzz"]!.gain > 0.5)
        #expect(idle["ext-cfm-idle"]!.gain > 0.9)
        #expect(takeoff["ext-cfm-rumble"]!.gain > idle["ext-cfm-rumble"]!.gain + 0.5)
        #expect(TurbineMix.layers(n1: 0, exterior: true, reverser: 0).values.allSatisfy { $0.gain < 0.001 }, "silent when stopped")
        #expect(TurbineMix.layers(n1: 60, exterior: false, reverser: 0).keys.allSatisfy { $0.hasPrefix("ckpt-") })
    }

    /// With the recordings loaded, takeoff thrust is much louder than idle, outside and in.
    @Test func recordingsPlayLouderAtTakeoff() throws {
        let layers = FlightAudio.loadTurbineLayers(directory: Self.directory)
        #expect(layers.count == 14, "\(layers.map(\.name))")
        for exterior in [true, false] {
            func level(_ n1: Double) -> Double {
                var synth = EngineSynth(sampleRate: 48_000)
                synth.turbineLayers = layers
                var p = SoundParameters()
                p.piston = false; p.n1 = n1; p.exterior = exterior; p.onGround = false
                synth.target = p
                var buffer = [Float](repeating: 0, count: 48_000)
                buffer.withUnsafeMutableBufferPointer { b in
                    for start in stride(from: 0, to: b.count, by: 512) { synth.render(into: b.baseAddress! + start, frames: 512) }
                }
                let tail = buffer.suffix(24_000)
                return (tail.map { Double($0 * $0) }.reduce(0, +) / Double(tail.count)).squareRoot()
            }
            let idle = level(21), takeoff = level(92)
            print("\(exterior ? "outside" : "flight deck"): idle rms \(idle), takeoff rms \(takeoff)")
            #expect(idle > 0.02)
            #expect(takeoff > idle * 1.5)
        }
    }
}
