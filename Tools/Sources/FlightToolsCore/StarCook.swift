import Foundation
import SimCore

/// Stars for the night sky: the Yale Bright Star Catalogue (public domain) down to a magnitude,
/// as a small binary the app reads: "STAR", a count, then per star its J2000 unit vector, visual
/// magnitude and B-V, as little-endian Float32.
enum StarCook {
    static func run(bsc5: URL, out: URL, faintest: Double) throws -> Int {
        let text = try String(contentsOf: bsc5, encoding: .isoLatin1)
        let stars = CatalogStar.parseBSC5(text).filter { $0.magnitude <= faintest }
        var data = Data("STAR".utf8)
        withUnsafeBytes(of: UInt32(stars.count).littleEndian) { data.append(contentsOf: $0) }
        for s in stars {
            let v = Celestial.equatorial(rightAscension: s.rightAscension, declination: s.declination)
            for f in [Float(v.x), Float(v.y), Float(v.z), Float(s.magnitude), Float(s.colourIndex)] {
                withUnsafeBytes(of: f.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: out)
        return stars.count
    }
}
