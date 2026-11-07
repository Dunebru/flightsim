import Testing
@testable import Autopilot

@Test func moduleIdentity() {
    #expect(AutopilotModule.info.name == "Autopilot")
    #expect(AutopilotModule.info.status == .stub(plannedFor: "M8"))
}
