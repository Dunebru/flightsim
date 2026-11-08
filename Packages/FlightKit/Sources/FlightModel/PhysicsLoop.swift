public import Foundation
import Synchronization

/// Runs a FlightDynamics model on its own thread at a fixed rate (120 Hz), decoupled from
/// rendering. Controls go in and state snapshots come out through a mutex; the JSBSim instance
/// itself is touched only by the physics thread.
public final class PhysicsLoop: Sendable {
    public enum Command: Sendable {
        case reset(InitialConditions)
        case trim
    }

    private struct Shared: Sendable {
        var inputs = ControlInputs()
        var state = FlightState()
        var steps = 0
        var paused = false
        var running = true
        var commands: [Command] = []
        var lastError: String?
        /// Height of the reference point above the ground when resting on the gear, feet.
        var restingHeightFeet: Double = 0
    }

    /// Reference wrapper so the physics thread and callers share one (noncopyable) mutex.
    private final class SharedState: Sendable {
        let mutex = Mutex(Shared())
        func withLock<R>(_ body: (inout Shared) -> R) -> R { mutex.withLock { body(&$0) } }
    }

    private let shared = SharedState()
    public let rate: Double

    /// Ownership box: after `start`, only the physics thread touches the model.
    private final class ModelBox: @unchecked Sendable {
        let fdm: FlightDynamics
        init(_ fdm: FlightDynamics) { self.fdm = fdm }
    }

    public init(model: String, initial: InitialConditions, rate: Double = 120, root: URL? = FlightDynamics.bundledRoot) throws {
        self.rate = rate
        let fdm = try FlightDynamics(model: model, root: root, rate: rate)
        try fdm.initialize(initial)
        // Let the gear settle so the resting height is meaningful.
        fdm.apply(ControlInputs())
        fdm.step(Int(rate))
        let settled = fdm.state
        shared.withLock {
            $0.state = settled
            $0.restingHeightFeet = initial.heightAboveGroundFeet == 0 ? settled.heightAboveGroundFeet : 0
        }
        let box = ModelBox(fdm)
        let thread = Thread { [shared] in Self.run(box: box, shared: shared, rate: rate) }
        thread.name = "Physics"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit { shared.withLock { $0.running = false } }

    // MARK: Interface

    public var state: FlightState { shared.withLock { $0.state } }
    public var stepCount: Int { shared.withLock { $0.steps } }
    public var restingHeightFeet: Double { shared.withLock { $0.restingHeightFeet } }
    public var lastError: String? { shared.withLock { $0.lastError } }

    public func setInputs(_ inputs: ControlInputs) { shared.withLock { $0.inputs = inputs } }
    public func updateInputs(_ body: (inout ControlInputs) -> Void) { shared.withLock { body(&$0.inputs) } }
    public func setPaused(_ paused: Bool) { shared.withLock { $0.paused = paused } }
    public func send(_ command: Command) { shared.withLock { $0.commands.append(command) } }
    public func stop() { shared.withLock { $0.running = false } }

    // MARK: Thread

    private static func run(box: ModelBox, shared: SharedState, rate: Double) {
        let fdm = box.fdm
        let dt = 1.0 / rate
        let start = Date.timeIntervalSinceReferenceDate
        var stepped = 0
        var lastTick = start
        while true {
            let (running, paused, inputs, commands) = shared.withLock { s -> (Bool, Bool, ControlInputs, [Command]) in
                let c = s.commands
                s.commands = []
                return (s.running, s.paused, s.inputs, c)
            }
            if !running { return }
            for command in commands {
                switch command {
                case .reset(let ic):
                    do { try fdm.initialize(ic) } catch { shared.withLock { $0.lastError = String(describing: error) } }
                case .trim:
                    do { try fdm.trim(.full) } catch { shared.withLock { $0.lastError = String(describing: error) } }
                }
            }
            let now = Date.timeIntervalSinceReferenceDate
            if paused {
                lastTick = now
            } else {
                // Fixed steps for the elapsed wall time; never more than 0.1 s of catch-up.
                var due = Int((now - lastTick) / dt)
                if due > Int(rate / 10) { due = Int(rate / 10); lastTick = now - Double(due) * dt }
                if due > 0 {
                    fdm.apply(inputs)
                    fdm.step(due)
                    lastTick += Double(due) * dt
                    stepped += due
                    let s = fdm.state
                    shared.withLock { $0.state = s; $0.steps = stepped }
                }
            }
            // Sleep until the next step is due.
            let wait = lastTick + dt - Date.timeIntervalSinceReferenceDate
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }
}
