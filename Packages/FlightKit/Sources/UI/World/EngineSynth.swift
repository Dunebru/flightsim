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
    /// Thrust reversers deployed, 0...1.
    var reverser = 0.0
}

/// A recording made to loop: its tail crossfaded into its head so the seam does not click,
/// levelled to a common loudness, read at any speed.
nonisolated struct SampleLoop: Sendable {
    var name = ""
    let samples: [Float]
    let sampleRate: Double
    private(set) var position = 0.0
    /// Smoothed toward the mix's targets each buffer.
    var gain = 0.0, rate = 1.0

    /// `crossfade` seconds of the end are blended into the start (equal power); the loop is
    /// that much shorter than the recording. Levelled to an RMS of `level`.
    init(samples raw: [Float], sampleRate: Double, crossfade: Double = 0.15, level: Float = 0.15) {
        let n = raw.count
        let fade = min(Int(crossfade * sampleRate), n / 3)
        var out = Array(raw[0..<(n - fade)])
        for i in 0..<fade {
            let t = Float(i) / Float(max(fade, 1))
            out[i] = raw[i] * sqrt(t) + raw[n - fade + i] * sqrt(1 - t)
        }
        let rms = sqrt(out.reduce(0) { $0 + $1 * $1 } / Float(max(out.count, 1)))
        let scale = rms > 1e-6 ? level / rms : 1
        samples = out.map { $0 * scale }
        self.sampleRate = sampleRate
    }

    /// The next sample, advancing by `step` source samples (linear interpolation).
    mutating func next(step: Double) -> Float {
        let n = samples.count
        guard n > 1 else { return 0 }
        let i = Int(position), f = Float(position - Double(i))
        let a = samples[i], b = samples[i + 1 < n ? i + 1 : 0]
        position += step
        if position >= Double(n) { position -= Double(n) }
        return a + (b - a) * f
    }
}

/// How loud and how fast each CFM56 recording plays for an N1 (percent), outside or on the
/// flight deck: the idle note rising in pitch, the fan whine opening up through the middle,
/// the buzz-saw above 80 percent, the roar of the exhaust at high thrust, and the reversers.
nonisolated enum TurbineMix {
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Layer name ("ext-cfm-idle") to (gain, playback rate).
    static func layers(n1: Double, exterior: Bool, reverser: Double) -> [String: (gain: Double, rate: Double)] {
        let running = smooth(1, 12, n1)           // spooling down to silence
        func r(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        let idle = (gain: running * (1 - 0.6 * smooth(35, 70, n1)), rate: r(0.9 + (n1 - 20) * 0.012, 0.6, 1.35))
        let low = (gain: smooth(25, 45, n1) * (1 - 0.7 * smooth(70, 90, n1)), rate: r(n1 / 45, 0.6, 1.6))
        let spool = (gain: smooth(50, 75, n1), rate: r(n1 / 80, 0.7, 1.3))
        let buzz = (gain: 0.9 * smooth(78, 92, n1), rate: r(n1 / 90, 0.8, 1.15))
        let reverse = (gain: 1.2 * reverser * smooth(30, 70, n1), rate: r(n1 / 80, 0.7, 1.2))
        if exterior {
            return ["ext-cfm-idle": idle, "ext-cfm-lowspool": low, "ext-cfm-spool": spool, "ext-cfm-buzz": buzz,
                    "ext-cfm-rumble": (gain: 1.3 * pow(smooth(55, 95, n1), 1.5), rate: r(0.8 + 0.25 * n1 / 100, 0.8, 1.05)),
                    "ext-cfm-reverse": reverse]
        }
        return ["ckpt-cfm-idle": idle, "ckpt-cfm-hum": (gain: 0.5 * running, rate: r(0.85 + n1 * 0.004, 0.85, 1.25)),
                "ckpt-cfm-lowspool": low, "ckpt-cfm-spool": spool, "ckpt-cfm-buzz": buzz,
                "ckpt-cfm-comb": (gain: 0.8 * smooth(60, 95, n1), rate: r(n1 / 85, 0.8, 1.15)), "ckpt-cfm-reverse": reverse]
    }
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
    /// Recorded CFM56 layers by name; while loaded, a turbine plays these instead of the synth.
    var turbineLayers: [SampleLoop] = []

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
        current.reverser += (target.reverser - current.reverser) * ease
        let p = current
        let sampled = !p.piston && !turbineLayers.isEmpty
        if sampled {
            let mix = TurbineMix.layers(n1: p.n1, exterior: p.exterior, reverser: p.reverser)
            for k in turbineLayers.indices {
                let t = mix[turbineLayers[k].name] ?? (gain: 0, rate: turbineLayers[k].rate)
                turbineLayers[k].gain += (t.gain - turbineLayers[k].gain) * ease
                turbineLayers[k].rate += (t.rate - turbineLayers[k].rate) * ease
            }
        }
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
            if sampled {
                var e: Float = 0
                for k in turbineLayers.indices where turbineLayers[k].gain > 0.0005 {
                    let step = turbineLayers[k].rate * turbineLayers[k].sampleRate / sampleRate
                    e += turbineLayers[k].next(step: step) * Float(turbineLayers[k].gain)
                }
                s += Double(e) * 0.9 * engineGain
            } else if !p.piston, p.n1 > 1 {
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
