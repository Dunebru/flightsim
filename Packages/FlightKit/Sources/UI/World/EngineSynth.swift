import Foundation

/// What the aircraft sounds like right now, set by the flight about 60 times a second.
nonisolated struct SoundParameters: Sendable, Equatable {
    /// A piston engine (rpm) or a turbofan (N1 percent).
    var piston = true
    var rpm = 0.0
    var n1 = 0.0
    var throttle = 0.0
    var airspeedKnots = 0.0
    var groundSpeedKnots = 0.0
    var onGround = true
    var stallWarning = false
    /// Camera outside the aircraft: the engine is louder, the wind quieter.
    var exterior = true
}

/// Engine, wind and rolling sounds made from the flight's numbers, sample by sample: no recorded
/// audio. A four-cylinder piston fires twice a revolution, so its note is rpm / 30 Hz, a run of
/// harmonics with exhaust rasp; a turbofan has a fan whine (36 blades) over a roar that opens up
/// with N1; wind is noise that brightens and swells with airspeed; the runway rumbles.
nonisolated struct EngineSynth {
    let sampleRate: Double
    private(set) var current = SoundParameters()
    var target = SoundParameters()
    private var firing = 0.0, fan = 0.0, shaft = 0.0, horn = 0.0
    private var rng: UInt32 = 0x1234_5678
    private var windLow = 0.0, windHigh = 0.0, roarLow = 0.0, roarHigh = 0.0, rumble = 0.0, raspLow = 0.0
    private var thump = 0.0, thumpPhase = 0.0
    private var cycleGain = 1.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// A firm landing: a thud scaled by how hard (0 to 1).
    mutating func touchdown(_ strength: Double) {
        thump = min(max(strength, 0.2), 1)
        thumpPhase = 0
    }

    private mutating func noise() -> Double {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Double(rng) / Double(UInt32.max) * 2 - 1
    }

    /// One-pole low-pass coefficient for a cutoff (Hz).
    private func alpha(_ hz: Double) -> Double { 1 - exp(-2 * .pi * min(hz, sampleRate * 0.45) / sampleRate) }

    mutating func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        // Ease toward the targets over about 50 ms so changes do not click.
        let ease = 1 - exp(-Double(frames) / (0.05 * sampleRate))
        current.rpm += (target.rpm - current.rpm) * ease
        current.n1 += (target.n1 - current.n1) * ease
        current.throttle += (target.throttle - current.throttle) * ease
        current.airspeedKnots += (target.airspeedKnots - current.airspeedKnots) * ease
        current.groundSpeedKnots += (target.groundSpeedKnots - current.groundSpeedKnots) * ease
        current.piston = target.piston
        current.onGround = target.onGround
        current.stallWarning = target.stallWarning
        current.exterior = target.exterior
        let p = current
        let dt = 1 / sampleRate
        let engineGain = p.exterior ? 1.0 : 0.55
        let windGain = p.exterior ? 0.6 : 1.0
        let speed = min(p.airspeedKnots / 160, 1.4)
        let aWind = alpha(250 + 2_500 * speed), aWindHigh = alpha(80)
        let aRoar = alpha(250 + 2_800 * p.n1 / 100), aRoarHigh = alpha(40)
        let aRumble = alpha(90), aRasp = alpha(2_200)
        for i in 0..<frames {
            var s = 0.0
            if p.piston, p.rpm > 50 {
                let f0 = p.rpm / 30
                let previous = firing
                firing = (firing + f0 * dt).truncatingRemainder(dividingBy: 1)
                // Each firing a little different, as a real engine's are.
                if firing < previous { cycleGain = 0.85 + 0.3 * (noise() * 0.5 + 0.5) }
                let ph = firing * 2 * .pi
                var tone = 0.0
                for k in 1...7 { tone += sin(ph * Double(k)) / pow(Double(k), 0.9) }
                // Exhaust rasp: noise in bursts at each firing.
                let burst = pow(max(cos(ph), 0), 6)
                raspLow += (noise() - raspLow) * aRasp
                let level = (0.3 + 0.3 * p.throttle) * (0.45 + 0.55 * min(p.rpm / 2_400, 1.1))
                s += (tone * 0.16 * cycleGain + raspLow * burst * 0.6) * level * engineGain
            }
            if !p.piston, p.n1 > 1 {
                let n = p.n1 / 100
                fan = (fan + n * 80 * 36 * dt).truncatingRemainder(dividingBy: 1)
                shaft = (shaft + n * 80 * dt).truncatingRemainder(dividingBy: 1)
                let whine = sin(fan * 2 * .pi) * 0.05 * (0.4 + 0.6 * n)
                // Buzz-saw at high thrust: shaft harmonics.
                var buzz = 0.0
                if n > 0.75 { for k in 1...6 { buzz += sin(shaft * 2 * .pi * Double(k)) / Double(k) } }
                buzz *= 0.05 * max(n - 0.75, 0) * 4
                roarLow += (noise() - roarLow) * aRoar
                roarHigh += (roarLow - roarHigh) * aRoarHigh
                let roar = (roarLow - roarHigh) * (0.06 + 0.42 * n * n)
                s += (whine + buzz + roar) * engineGain
            }
            // Wind over the airframe.
            windLow += (noise() - windLow) * aWind
            windHigh += (windLow - windHigh) * aWindHigh
            s += (windLow - windHigh) * 0.5 * speed * speed * windGain
            // Rolling on the runway.
            if p.onGround, p.groundSpeedKnots > 1 {
                rumble += (noise() - rumble) * aRumble
                s += rumble * 0.6 * min(p.groundSpeedKnots / 60, 1.2)
            }
            // Touchdown thud: a falling 60 Hz knock.
            if thump > 0.001 {
                thumpPhase += 55 * dt
                s += sin(thumpPhase * 2 * .pi) * thump * 0.8
                thump *= exp(-dt / 0.09)
            }
            // Stall warning horn.
            if p.stallWarning {
                horn = (horn + 1_600 * dt).truncatingRemainder(dividingBy: 1)
                s += (sin(horn * 2 * .pi) + 0.3 * sin(horn * 4 * .pi)) * 0.08
            }
            out[i] = Float(max(-1, min(1, s)))
        }
    }
}
