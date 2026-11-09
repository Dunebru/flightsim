import Foundation
import Renderer

/// The last ten minutes of the flight as it was drawn, ten frames a second, for watching back:
/// where the aircraft was and how it sat, its gear, and every animated part's value.
nonisolated struct ReplayBuffer: Sendable {
    struct Frame: Sendable {
        var time: Double
        var position: SIMD3<Double>
        var heading: Double, pitch: Double, roll: Double
        var gearDown: Bool
        var values: [String: Double]
        var lights: SIMD8<Float>?
    }

    static let interval = 0.1, length = 600.0
    private(set) var frames: [Frame] = []

    var duration: Double { (frames.last?.time ?? 0) - (frames.first?.time ?? 0) }
    var start: Double { frames.first?.time ?? 0 }

    /// Records the scene if a tenth of a second has passed since the last frame.
    mutating func record(time: Double, _ s: SceneDescription) {
        if let last = frames.last, time - last.time < Self.interval { return }
        frames.append(Frame(time: time, position: s.aircraftPosition, heading: s.aircraftHeading, pitch: s.aircraftPitch,
                            roll: s.aircraftRoll, gearDown: s.aircraftGearDown, values: s.instrumentValues, lights: s.playerLights))
        if let first = frames.first, time - first.time > Self.length + 10 {
            frames.removeFirst(frames.firstIndex { time - $0.time <= Self.length } ?? 0)
        }
    }

    /// The aircraft at a time: position and attitude interpolated between frames (headings the
    /// short way round), the rest from the nearer frame.
    func frame(at time: Double) -> Frame? {
        guard let first = frames.first, let last = frames.last else { return nil }
        if time <= first.time { return first }
        if time >= last.time { return last }
        var lo = 0, hi = frames.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frames[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = frames[lo], b = frames[hi]
        let f = (time - a.time) / max(b.time - a.time, 1e-6)
        func angle(_ x: Double, _ y: Double) -> Double { x + remainder(y - x, 2 * .pi) * f }
        var out = f < 0.5 ? a : b
        out.time = time
        out.position = a.position + (b.position - a.position) * f
        out.heading = angle(a.heading, b.heading)
        out.pitch = a.pitch + (b.pitch - a.pitch) * f
        out.roll = a.roll + (b.roll - a.roll) * f
        return out
    }
}
