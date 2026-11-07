import Testing
@testable import UI

@MainActor
struct HUDModelTests {
    @Test func throttleStopsAtIdleGate() {
        let model = HUDModel()
        model.setThrottle(0.5)
        model.setThrottle(-0.03)          // inside the gate: holds at idle
        #expect(model.throttle == 0)
        #expect(!model.isReverse)
    }

    @Test func throttleEntersReversePastGate() {
        let model = HUDModel()
        model.setThrottle(0.5)
        model.setThrottle(-0.10)          // pulled through the gate
        #expect(model.throttle == -0.10)
        #expect(model.isReverse)
    }

    @Test func throttleClampsToRange() {
        let model = HUDModel()
        model.setThrottle(3)
        #expect(model.throttle == HUDModel.throttleRange.upperBound)
        model.setThrottle(-0.2)
        model.setThrottle(-9)
        #expect(model.throttle == HUDModel.throttleRange.lowerBound)
    }

    @Test func panelKeyTogglesAndSwitches() {
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
        #expect(model.gear == .down)
        model.toggleGear()
        #expect(model.gear == .transit(toDown: false))
    }

    @Test func fontsRegister() {
        #expect(Typeface.registerBundledFonts() == 0)
    }
}
