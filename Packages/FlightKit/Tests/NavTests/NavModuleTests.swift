import Testing
@testable import Nav

@Test func moduleIdentity() {
    #expect(NavModule.info.name == "Nav")
    #expect(NavModule.info.status == .stub(plannedFor: "M8"))
}
