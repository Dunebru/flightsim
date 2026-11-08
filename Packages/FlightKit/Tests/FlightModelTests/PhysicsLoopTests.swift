import Foundation
import Testing
@testable import FlightModel

struct PhysicsLoopTests {
    static let phoenix = InitialConditions(latitude: 33.4342, longitude: -112.0116, terrainElevationFeet: 1135,
                                           heightAboveGroundFeet: 0, headingDegrees: 90, airspeedKnots: 0)

    /// PLAN.md M2 criterion 2: fixed 120 Hz, step count within 1% of wall time.
    @Test func runsAtOneHundredTwentyHertz() async throws {
        let loop = try PhysicsLoop(model: "c172p", initial: Self.phoenix)
        defer { loop.stop() }
        let s0 = loop.stepCount
        let t0 = Date()
        try await Task.sleep(for: .seconds(3))
        let steps = loop.stepCount - s0
        let elapsed = Date().timeIntervalSince(t0)
        let expected = elapsed * 120
        #expect(abs(Double(steps) - expected) / expected < 0.01, "\(steps) steps in \(elapsed) s, expected \(expected)")
    }

    /// Simulation time follows wall time no matter how often the state is read (the renderer's
    /// frame rate cannot change the physics).
    @Test func simulationTimeIndependentOfReaderRate() async throws {
        let fast = try PhysicsLoop(model: "c172p", initial: Self.phoenix)
        let slow = try PhysicsLoop(model: "c172p", initial: Self.phoenix)
        defer { fast.stop(); slow.stop() }
        let t0f = fast.state.time, t0s = slow.state.time
        for i in 0..<60 {
            _ = fast.state                      // read at 120 Hz
            if i % 4 == 0 { _ = slow.state }    // read at 30 Hz
            try await Task.sleep(for: .milliseconds(8))
        }
        let df = fast.state.time - t0f, ds = slow.state.time - t0s
        #expect(abs(df - ds) < 0.05, "fast reader \(df) s, slow reader \(ds) s")
    }
}
