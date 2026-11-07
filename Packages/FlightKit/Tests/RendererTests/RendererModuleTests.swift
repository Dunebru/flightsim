import Testing
@testable import Renderer

@Test func moduleIdentity() {
    #expect(RendererModule.info.name == "Renderer")
    #expect(RendererModule.info.status == .stub(plannedFor: "M1"))
}
