import FlightToolsCore

#if canImport(Darwin)
import Darwin
#endif

let result = runTool(Array(CommandLine.arguments.dropFirst()))
print(result.output)
exit(result.code)
