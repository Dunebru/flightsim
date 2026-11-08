import Foundation
import Renderer
import Testing
@testable import UI

@MainActor
struct AppSettingsTests {
    static func freshDefaults() -> UserDefaults {
        let name = "AppSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func choicesPersistAcrossLaunches() {
        let d = Self.freshDefaults()
        let a = AppSettings(defaults: d)
        a.aircraftID = "A320"
        a.start = .kphxFinal08
        a.controlMode = .stick
        a.sensitivity = 1.4
        a.invertPitch = true
        a.fixedUTCHour = 13.5
        let b = AppSettings(defaults: d)
        #expect(b.aircraftID == "A320")
        #expect(b.start == .kphxFinal08)
        #expect(b.controlMode == .stick)
        #expect(b.sensitivity == 1.4)
        #expect(b.invertPitch)
        #expect(b.fixedUTCHour == 13.5)
    }

    @Test func outOfRangeSensitivityIsClamped() throws {
        let d = Self.freshDefaults()
        let a = AppSettings(defaults: d)
        a.sensitivity = 9
        #expect(AppSettings(defaults: d).sensitivity == 2)
    }

    @Test func pinnedHourIsTodayInUTC() throws {
        let a = AppSettings(defaults: Self.freshDefaults())
        a.fixedUTCHour = 19.5
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-07T03:00:00Z"))
        let d = a.flightDate(now: now)
        #expect(ISO8601DateFormatter().string(from: d) == "2026-11-07T19:30:00Z")
        a.fixedUTCHour = nil
        #expect(a.flightDate(now: now) == now)
    }

    @Test func finalApproachStartIsOnTheGlidePath() {
        let p = StartPosition.kphxFinal08.placement
        let threshold = PhoenixSite.centreline(-PhoenixSite.runwayLength / 2)
        let axis = PhoenixSite.runwayAxis
        let d = SIMD2(p.position.x - threshold.x, p.position.y - threshold.y)
        // On the extended centreline, 3 nm short of the threshold, flying the runway heading.
        let along = d.x * axis.x + d.y * axis.y
        let across = -d.x * axis.y + d.y * axis.x
        #expect(abs(across) < 0.5, "off the centreline by \(across) m")
        #expect(abs(-along - 5_556) < 1)
        // 3 nm from the threshold at a 3 degree path is about 955 ft.
        let pathHeight = (-along / 0.3048) * tan(3 * Double.pi / 180)
        #expect(abs(p.heightFeet - pathHeight) < 30)
        #expect(abs(p.heading - PhoenixSite.runwayHeading) < 1e-9)
    }

    @Test func runwayStartsAreOnTheCentreline() {
        for start in [StartPosition.kphxRunway08, .kphxRunway26] {
            let p = start.placement.position
            let axis = PhoenixSite.runwayAxis
            #expect(abs(-p.x * axis.y + p.y * axis.x) < 0.5, "\(start) off the centreline")
        }
        #expect(abs(StartPosition.kphxRunway26.placement.heading - (PhoenixSite.runwayHeading + 180)) < 1e-9)
    }
}
