import Testing
import FlightModel
@testable import UI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
struct HUDModelTests {
    @Test func throttleClampsToRange() {
        let model = HUDModel()
        model.setThrottle(3)
        #expect(model.throttle == 1)
        model.setThrottle(-2)
        #expect(model.throttle == 0)
    }

    @Test func reverseBringsLeverToIdle() {
        let model = HUDModel()
        model.setThrottle(0.8)
        model.toggleReverse()
        #expect(model.reverse)
        #expect(model.throttle == 0)
        model.setThrottle(0.6)
        model.toggleReverse()
        #expect(!model.reverse)
        #expect(model.throttle == 0)
    }

    @Test func panelButtonsToggleAndSwitch() {
        let model = HUDModel()
        model.toggle(.autopilot)
        #expect(model.openPanel == .autopilot)
        model.toggle(.lights)
        #expect(model.openPanel == .lights)
        model.toggle(.lights)
        #expect(model.openPanel == nil)
    }

    @Test func gearGoesThroughTransit() {
        let model = HUDModel()
        model.profile = .a320          // retractable gear
        #expect(model.gear == .down)
        model.toggleGear()
        #expect(model.gear == .transit(toDown: false))
    }

    @Test func fixedGearIgnoresTheLever() {
        let model = HUDModel()          // C172: fixed gear
        model.toggleGear()
        #expect(model.gear == .down)
    }

    #if canImport(AppKit)
    /// A misspelled SF Symbol renders as nothing, silently. Every name the HUD uses must resolve.
    @Test(arguments: [
        "video.fill", "map.fill", "map", "antenna.radiowaves.left.and.right", "lightbulb.fill",
        "gearshape.fill", "pause.fill", "play.fill", "parkingsign", "flame.fill", "xmark",
        "airplane.departure",
    ] + HUDModel.Light.allCases.map(\.symbol))
    func symbolExists(_ name: String) {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
    }
    #endif
}
