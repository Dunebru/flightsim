import Testing
@testable import Weather

@Test func moduleIdentity() {
    #expect(WeatherModule.info.name == "Weather")
    #expect(WeatherModule.info.status == .stub(plannedFor: "M7"))
}
