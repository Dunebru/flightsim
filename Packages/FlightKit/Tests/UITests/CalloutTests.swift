import Testing
@testable import UI

/// An approach from 3,000 ft to touchdown at 700 fpm with the autopilot off at 400 ft: every
/// radio height callout once and in order, "retard" at 20 ft (thrust still up), the cavalry
/// charge once; a go-around and second approach calls them again.
struct CalloutTests {
    static func approach(_ m: inout CalloutMonitor, autopilotOffAt: Double = 400) -> [String] {
        var out: [String] = []
        var h = 3_000.0
        while h > 0 {
            h -= 700.0 / 60 / 30
            out += m.update(.init(radioHeightFeet: max(h, 0), verticalSpeedFPM: -700, onGround: h <= 0, gearDown: true,
                                  throttle: 0.3, autopilot: h > autopilotOffAt, altitudeFeet: 1_135 + h, selectedAltitudeFeet: 5_000))
        }
        return out
    }

    @Test func approachCallouts() {
        var m = CalloutMonitor()
        let first = Self.approach(&m)
        #expect(first.filter { $0 != "cavalry-charge-once" } == ["2500", "1000", "500", "400", "300", "200", "100", "50", "40", "30", "20", "retard", "10"],
                "\(first)")
        #expect(first.filter { $0 == "cavalry-charge-once" }.count == 1)
        // Go around: climb back to 3,000 ft, then a second approach.
        var h = 0.0
        while h < 3_000 {
            h += 1_500.0 / 60 / 30
            _ = m.update(.init(radioHeightFeet: h, verticalSpeedFPM: 1_500, onGround: false, gearDown: true, throttle: 0.9,
                               autopilot: false, altitudeFeet: 1_135 + h, selectedAltitudeFeet: 5_000))
        }
        let second = Self.approach(&m)
        #expect(second.contains("1000") && second.contains("50") && second.contains("retard"), "second approach: \(second)")
    }

    @Test func altitudeAlertAndCabinChime() {
        var m = CalloutMonitor()
        var out: [String] = []
        var alt = 8_000.0
        while alt < 11_000 {
            alt += 2_000.0 / 60 / 30
            out += m.update(.init(radioHeightFeet: 5_000, verticalSpeedFPM: 2_000, onGround: false, gearDown: false, throttle: 0.9,
                                  autopilot: true, altitudeFeet: alt, selectedAltitudeFeet: 11_000))
        }
        #expect(out == ["cabin-chime", "c-chord"], "\(out)")
    }
}
