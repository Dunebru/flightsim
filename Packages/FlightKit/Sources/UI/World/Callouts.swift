import Foundation

/// The A320's automatic callouts and alerts, decided from the flight state: radio height on the
/// way down (2,500, 1,000, 500 ... 10), "retard" at 20 ft with thrust still up, the cavalry
/// charge when the autopilot disconnects, the C-chord nearing the selected altitude, a cabin
/// chime through 10,000 ft. Returns the names of recordings to play.
nonisolated struct CalloutMonitor: Sendable {
    static let heights = [2_500, 1_000, 500, 400, 300, 200, 100, 50, 40, 30, 20, 10]

    struct Input: Sendable {
        var radioHeightFeet: Double
        var verticalSpeedFPM: Double
        var onGround: Bool
        var gearDown: Bool
        var throttle: Double
        var autopilot: Bool
        var altitudeFeet: Double
        var selectedAltitudeFeet: Double
    }

    private var lastHeight: Double?
    private var called = Set<Int>()
    private var retardCalled = false
    private var wasAutopilot = false
    private var altitudeAlerted = false
    private var lastAltitude: Double?

    mutating func update(_ i: Input) -> [String] {
        var out: [String] = []
        defer {
            lastHeight = i.radioHeightFeet
            wasAutopilot = i.autopilot
            lastAltitude = i.altitudeFeet
        }
        // Climbing away re-arms each callout once well above it.
        called = called.filter { Double($0) + 150 >= i.radioHeightFeet || i.verticalSpeedFPM < 300 }
        if i.radioHeightFeet > 100 { retardCalled = false }
        if let last = lastHeight, !i.onGround, i.verticalSpeedFPM < -100 {
            for h in Self.heights where last > Double(h) && i.radioHeightFeet <= Double(h) && !called.contains(h) {
                called.insert(h)
                out.append("\(h)")
            }
            if !retardCalled, last > 20, i.radioHeightFeet <= 20, i.throttle > 0.05 {
                retardCalled = true
                out.append("retard")
            }
        }
        if wasAutopilot && !i.autopilot && !i.onGround { out.append("cavalry-charge-once") }
        // Altitude alert: once on coming within 750 ft of the selected altitude; re-armed when
        // more than 1,000 ft away again.
        let gap = abs(i.altitudeFeet - i.selectedAltitudeFeet)
        if gap > 1_000 { altitudeAlerted = false }
        if !altitudeAlerted, gap <= 750, gap > 250, !i.onGround, abs(i.verticalSpeedFPM) > 300 {
            altitudeAlerted = true
            out.append("c-chord")
        }
        if let last = lastAltitude, (last - 10_000) * (i.altitudeFeet - 10_000) < 0 { out.append("cabin-chime") }
        return out
    }
}
