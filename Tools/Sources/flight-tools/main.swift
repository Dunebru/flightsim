import FlightToolsCore

#if canImport(Darwin)
import Darwin
#endif

let result = await runTool(Array(CommandLine.arguments.dropFirst()))
print(result.output)
exit(result.code)
