import Testing
@testable import ATC

@Test func moduleIdentity() {
    #expect(ATCModule.info.name == "ATC")
    #expect(ATCModule.info.status == .stub(plannedFor: "M9"))
}
