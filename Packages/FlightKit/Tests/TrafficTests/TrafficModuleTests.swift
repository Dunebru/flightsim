import Testing
@testable import Traffic

@Test func moduleIdentity() {
    #expect(TrafficModule.info.name == "Traffic")
    #expect(TrafficModule.info.status == .stub(plannedFor: "M9"))
}
