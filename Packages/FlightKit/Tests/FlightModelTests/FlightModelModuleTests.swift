import Testing
@testable import FlightModel

@Test func moduleIdentity() {
    #expect(FlightModelModule.info.name == "FlightModel")
    #expect(FlightModelModule.info.status == .stub(plannedFor: "M2"))
}

@Test func engineStubIsLinked() {
    #expect(FlightModelModule.engineVersion == "stub")
}
