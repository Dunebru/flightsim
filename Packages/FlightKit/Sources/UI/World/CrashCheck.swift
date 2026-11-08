import FlightModel

/// Decides when the aircraft has crashed. The flight model has no notion of it: it lets an
/// aircraft hit the ground at 9,000 fpm and bounce back onto its wheels. Here a crash is hitting
/// the ground faster than the gear can take, a wingtip or the nose striking it, or the airframe
/// pressed into it; once crashed it stays crashed until reset.
nonisolated struct CrashCheck {
    /// The reference point's height above the ground when parked on the gear.
    let restingHeightFeet: Double
    private(set) var reason: String?
    private var wasOnGround = true
    private var lastVerticalSpeed = 0.0

    /// Descent rate at contact beyond which the gear fails (a firm landing is 600 fpm).
    static let impactFPM = 1_000.0
    static let wingtipBankDegrees = 30.0
    static let noseDownDegrees = -15.0
    /// How far below its resting height the reference point may go (gear compressing).
    static let sinkFeet = 1.5

    init(restingHeightFeet: Double) { self.restingHeightFeet = restingHeightFeet }

    mutating func update(_ s: FlightState) -> String? {
        if reason != nil { return reason }
        defer {
            wasOnGround = s.onGround
            lastVerticalSpeed = s.verticalSpeedFPM
        }
        guard s.onGround else { return nil }
        let descent = -min(s.verticalSpeedFPM, wasOnGround ? 0 : lastVerticalSpeed)
        let bank = abs(s.roll) * 180 / .pi, pitch = s.pitch * 180 / .pi
        if !wasOnGround && descent > Self.impactFPM {
            reason = "Hit the ground at \(Int(descent.rounded())) fpm"
        } else if bank > Self.wingtipBankDegrees {
            reason = "Wingtip struck the ground"
        } else if pitch < Self.noseDownDegrees {
            reason = "Nose struck the ground"
        } else if s.heightAboveGroundFeet < restingHeightFeet - Self.sinkFeet {
            reason = "Hit the ground"
        }
        return reason
    }

    mutating func reset() {
        reason = nil
        wasOnGround = true
        lastVerticalSpeed = 0
    }
}
