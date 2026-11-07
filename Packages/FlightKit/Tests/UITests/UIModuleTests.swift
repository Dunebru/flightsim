import Testing
@testable import UI

@Test func moduleIdentity() {
    #expect(UIModule.info.name == "UI")
    #expect(UIModule.info.status == .stub(plannedFor: "M3"))
}
