import Testing
@testable import Aircraft

@Test func moduleIdentity() {
    #expect(AircraftModule.info.name == "Aircraft")
    #expect(AircraftModule.info.status == .stub(plannedFor: "M6"))
}
