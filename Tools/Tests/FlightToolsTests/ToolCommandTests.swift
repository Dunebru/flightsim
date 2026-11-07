import Testing
@testable import FlightToolsCore

@Test func unknownCommandPrintsUsage() {
    let result = runTool(["bogus"])
    #expect(result.code == 64)
    #expect(result.output.contains("nav-import"))
}

@Test func stubCommandsReportNotImplemented() {
    for command in ToolCommand.allCases {
        let result = runTool([command.rawValue])
        #expect(result.code == 69)
        #expect(result.output.contains("not implemented"))
    }
}
