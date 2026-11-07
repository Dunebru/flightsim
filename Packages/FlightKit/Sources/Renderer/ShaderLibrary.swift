import Foundation
import Metal

/// Compiles the bundled Metal sources at load. The files in `Shaders/` are concatenated in name
/// order (00_Common first) and built as one library, so the same code runs under `swift test`
/// on the Mac and in the iOS app without an offline metallib step.
enum ShaderLibrary {
    enum LoadError: Error, CustomStringConvertible {
        case missingShaders
        case compile(String)
        var description: String {
            switch self {
            case .missingShaders: "Renderer shader sources not found in the bundle"
            case .compile(let log): "Metal shader compile failed:\n\(log)"
            }
        }
    }

    static func source() throws -> String {
        guard let folder = Bundle.module.url(forResource: "Shaders", withExtension: nil) else {
            throw LoadError.missingShaders
        }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw LoadError.missingShaders }
        return try files.map { "// ---- \($0.lastPathComponent)\n" + (try String(contentsOf: $0, encoding: .utf8)) }
            .joined(separator: "\n")
    }

    static func make(device: any MTLDevice) throws -> any MTLLibrary {
        let options = MTLCompileOptions()
        options.mathMode = .fast
        do {
            return try device.makeLibrary(source: try source(), options: options)
        } catch let error as LoadError {
            throw error
        } catch {
            throw LoadError.compile(String(describing: error))
        }
    }
}
