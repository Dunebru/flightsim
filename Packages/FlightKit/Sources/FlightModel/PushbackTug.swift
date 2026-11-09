import Foundation

/// A pushback tug: pushes the aircraft back at walking pace, straight or turning the tail to one
/// side, and stops it after a set distance or a quarter turn. Feeds the flight model a force at
/// the nose gear, a nose wheel angle and, at the end, the brakes.
public struct PushbackTug: Sendable, Equatable {
    public enum Direction: String, Sendable, CaseIterable { case straight, tailLeft, tailRight }
    public enum Phase: Sendable, Equatable { case pushing, stopping, done }

    public let direction: Direction
    public private(set) var phase: Phase = .pushing
    /// Metres pushed and degrees turned so far.
    public private(set) var distance = 0.0
    public private(set) var turned = 0.0
    private var startHeading: Double?
    private var integral = 0.0

    /// Backwards speed the tug holds, knots.
    public static let speed = 2.5
    /// Straight pushes stop after this far, metres; turning pushes after this many degrees.
    public static let straightDistance = 45.0, turnDegrees = 85.0
    /// Nose wheel angle while turning, as a fraction of the maximum (75 degrees on the A320).
    public static let turnSteering = 0.4

    public init(direction: Direction) { self.direction = direction }

    /// Stops the push where it is (the tug brakes the aircraft to a halt).
    public mutating func stop() {
        if phase == .pushing { phase = .stopping }
    }

    public struct Command: Sendable, Equatable {
        public var pounds: Double
        public var steering: Double
        public var brakes: Double
    }

    /// One step. `heading` radians true, `forwardKnots` negative when rolling back, `weight` lb.
    public mutating func update(dt: Double, heading: Double, forwardKnots: Double, weightPounds: Double) -> Command {
        if startHeading == nil { startHeading = heading }
        let back = -forwardKnots
        distance += max(back, 0) * 0.514_444 * dt
        var d = (heading - startHeading!) * 180 / .pi
        d = (d + 540).truncatingRemainder(dividingBy: 360) - 180
        turned = abs(d)
        switch phase {
        case .pushing:
            let finished = direction == .straight ? distance >= Self.straightDistance : turned >= Self.turnDegrees
            if finished { phase = .stopping; return Command(pounds: 0, steering: 0, brakes: 1) }
            // Speed held by a PI loop on force, its integral clamped so it cannot wind up.
            let error = Self.speed - back
            integral = max(-4, min(4, integral + error * dt))
            // Feed-forward of 3% of the weight: the tyres' rolling resistance (2%) and the
            // engines' idle thrust; the PI loop trims around it.
            let pounds = back > Self.speed + 0.6 ? 0
                : max(0, min(0.05 * weightPounds, weightPounds * (0.03 + 0.004 * error + 0.002 * integral)))
            // Backing with the nose wheel turned right: the wheel rolls back and left, so the
            // nose swings left and the tail right.
            let steer = direction == .straight ? 0 : (direction == .tailRight ? Self.turnSteering : -Self.turnSteering)
            return Command(pounds: pounds, steering: steer, brakes: 0)
        case .stopping:
            if abs(forwardKnots) < 0.2 { phase = .done }
            return Command(pounds: 0, steering: 0, brakes: 1)
        case .done:
            return Command(pounds: 0, steering: 0, brakes: 0)
        }
    }
}
