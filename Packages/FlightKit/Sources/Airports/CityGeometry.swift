import Foundation
import simd

/// Buildings around an airport as compact indexed meshes in 500 m chunks (airport frame), so the
/// renderer can draw only the chunks near the camera.
public struct CityChunk: Sendable {
    public var centre: SIMD3<Double>
    public var radius: Double
    public var positions: [SIMD3<Float>] = []
    /// xyz: normal (snorm8), w: the building's colour seed.
    public var normals: [SIMD4<Int8>] = []
    /// Walls: metres along, metres up. Roofs: metres east, north.
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []
}

/// Everything generated for one airport, ready for the renderer.
public struct AirportAssets: Sendable {
    public var site: AirportSite
    public var geometry: AirportGeometry
    public var lights: [LightPoint]
    public var city: [CityChunk]

    public init(site: AirportSite, geometry: AirportGeometry, lights: [LightPoint], city: [CityChunk]) {
        self.site = site
        self.geometry = geometry
        self.lights = lights
        self.city = city
    }
}

public enum CityGeometry {
    public static let chunkSize = 500.0

    /// - Parameter ground: ground height (airport-frame z) under a point, from the terrain.
    public static func build(_ city: SurroundingBuildings, site: AirportSite,
                             ground: (SIMD2<Double>) -> Double) -> [CityChunk] {
        var chunks: [SIMD2<Int>: CityChunk] = [:]
        // City footprints are in metres from the reference point on a local plane; the airport
        // frame is ENU from the same point, so they agree to centimetres within a few km.
        for (index, record) in city.buildings.enumerated() {
            guard record.count >= 7 else { continue }
            let height = Double(record[0])
            var ring: [SIMD2<Double>] = []
            for i in stride(from: 1, to: record.count - 1, by: 2) { ring.append(SIMD2(Double(record[i]), Double(record[i + 1]))) }
            let c = ring.reduce(SIMD2<Double>.zero, +) / Double(ring.count)
            let key = SIMD2(Int(floor(c.x / chunkSize)), Int(floor(c.y / chunkSize)))
            var chunk = chunks[key] ?? CityChunk(centre: .zero, radius: 0)
            let zs = ring.map(ground)
            let base = zs.min()! - 0.3, top = zs.max()! + height
            let seed = Int8(truncatingIfNeeded: (index &* 2_654_435_761) >> 8)
            func n(_ v: SIMD3<Double>) -> SIMD4<Int8> {
                SIMD4(Int8((v.x * 127).rounded()), Int8((v.y * 127).rounded()), Int8((v.z * 127).rounded()), seed)
            }
            // Walls: four vertices per face, two triangles.
            var along = 0.0
            for i in 0..<ring.count {
                let p = ring[i], q = ring[(i + 1) % ring.count]
                let d = q - p, len = simd_length(d)
                guard len > 0.05 else { continue }
                let normal = SIMD3(d.y / len, -d.x / len, 0)
                let first = UInt32(chunk.positions.count)
                for (pt, z, u) in [(p, base, along), (q, base, along + len), (q, top, along + len), (p, top, along)] {
                    chunk.positions.append(SIMD3<Float>(Float(pt.x), Float(pt.y), Float(z)))
                    chunk.normals.append(n(normal))
                    chunk.uvs.append(SIMD2(Float(u), Float(z - base)))
                }
                chunk.indices += [first, first + 1, first + 2, first, first + 2, first + 3]
                along += len
            }
            // Roof: the ring at the top, triangulated.
            let roofStart = UInt32(chunk.positions.count)
            for p in ring {
                chunk.positions.append(SIMD3<Float>(Float(p.x), Float(p.y), Float(top)))
                chunk.normals.append(n(SIMD3(0, 0, 1)))
                chunk.uvs.append(SIMD2<Float>(p))
            }
            let tris = Polygon2D.triangulate(outer: ring)
            for (a, b, cc) in tris {
                guard let ia = ring.firstIndex(of: a), let ib = ring.firstIndex(of: b), let ic = ring.firstIndex(of: cc) else { continue }
                chunk.indices += [roofStart + UInt32(ia), roofStart + UInt32(ib), roofStart + UInt32(ic)]
            }
            chunks[key] = chunk
        }
        // Bounds per chunk.
        return chunks.values.map { ch in
            var c = ch
            let lo = ch.positions.reduce(SIMD3<Float>(repeating: .infinity)) { pointwiseMin($0, $1) }
            let hi = ch.positions.reduce(SIMD3<Float>(repeating: -.infinity)) { pointwiseMax($0, $1) }
            c.centre = SIMD3<Double>((lo + hi) / 2)
            c.radius = Double(simd_length(hi - lo) / 2)
            return c
        }
    }
}
