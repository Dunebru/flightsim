import Foundation
import Testing
@testable import UI

/// Writes artifacts/audio/sound-demo.wav: what the synthesizer makes of a C172 from idle through
/// a full-power takeoff roll and climb, then an A320 spooling from idle to takeoff thrust and
/// rolling. For listening, not a check.
struct SoundDemo {
    @Test func writeDemo() throws {
        let rate = 44_100.0
        var synth = EngineSynth(sampleRate: rate)
        var samples: [Float] = []
        func run(_ seconds: Double, _ set: (Double, inout SoundParameters) -> Void) {
            let frames = Int(seconds * rate)
            var block = [Float](repeating: 0, count: 441)
            var done = 0
            while done < frames {
                var p = synth.target
                set(Double(done) / Double(frames), &p)
                synth.target = p
                block.withUnsafeMutableBufferPointer { synth.render(into: $0.baseAddress!, frames: 441) }
                samples += block
                done += 441
            }
        }
        // C172: idle, run up, then the takeoff roll and climb.
        run(3) { _, p in p.piston = true; p.rpm = 700; p.throttle = 0.05; p.onGround = true }
        run(4) { t, p in p.rpm = 700 + 1_700 * min(t * 2, 1); p.throttle = min(t * 2, 1) }
        run(8) { t, p in p.groundSpeedKnots = 60 * t; p.airspeedKnots = 60 * t }
        run(5) { t, p in p.onGround = false; p.airspeedKnots = 60 + 20 * t; p.groundSpeedKnots = 0 }
        run(1) { _, p in p = SoundParameters() }
        // A320: idle, spool to takeoff thrust, roll.
        run(3) { _, p in p.piston = false; p.n1 = 21; p.throttle = 0; p.onGround = true }
        run(6) { t, p in p.n1 = 21 + 74 * t; p.throttle = t }
        run(8) { t, p in p.groundSpeedKnots = 140 * t; p.airspeedKnots = 140 * t }
        run(2) { t, p in p.onGround = false; p.groundSpeedKnots = 0; p.airspeedKnots = 150 }
        // A firm landing to finish.
        run(1) { _, p in p.n1 = 30; p.airspeedKnots = 135 }
        synth.touchdown(0.7)
        run(4) { t, p in p.onGround = true; p.groundSpeedKnots = 130 * (1 - t); p.airspeedKnots = 130 * (1 - t) }

        // 16-bit mono WAV.
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s * 1.6)) * 32_000))) }
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../artifacts/audio").standardized
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("sound-demo.wav"))
        print("SOUND demo \(samples.count / Int(rate)) s written")
    }
}
