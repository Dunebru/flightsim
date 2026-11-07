import Testing
@testable import Terrain

@Test func moduleIdentity() {
    #expect(TerrainModule.info.name == "Terrain")
    #expect(TerrainModule.info.status == .stub(plannedFor: "M4"))
}
