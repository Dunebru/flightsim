import Testing
@testable import Airports

@Test func moduleIdentity() {
    #expect(AirportsModule.info.name == "Airports")
    #expect(AirportsModule.info.status == .stub(plannedFor: "M5"))
}
