import Testing
@testable import FlightModel

@Test func moduleIdentity() {
    #expect(FlightModelModule.info.name == "FlightModel")
}

@Test func linksJSBSim133() {
    #expect(FlightModelModule.engineVersion == "1.3.3")
}
