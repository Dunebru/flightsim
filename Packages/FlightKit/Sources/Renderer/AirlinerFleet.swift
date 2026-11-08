import Aircraft
import Foundation
import Metal
import MetalKit
import simd

/// The A320 model for every parked and moving airliner: drawn instanced, in four liveries, at two
/// levels of detail. Vertices are in the instance body frame the parked shader expects: x forward,
/// y left, z up, origin at the nose wheel on the ground.
final class AirlinerFleet {
    struct Group {
        let buffer: any MTLBuffer
        let count: Int
        /// The texture this group samples, by base name (a livery replaces the fuselage and engine).
        let textureName: String?
        var draw: DrawUniforms
    }

    let full: [Group]
    let distant: [Group]
    /// Beyond about a kilometre: merged on a 1.6 m grid, a few thousand triangles, the shape
    /// and the paint and nothing else.
    let far: [Group]
    /// Every far triangle in one buffer, for the shadow maps.
    let shadow: (buffer: any MTLBuffer, count: Int)
    /// Per livery: texture by base name.
    let textures: [[String: any MTLTexture]]
    let liveryCount: Int
    let fullTriangles: Int, distantTriangles: Int, farTriangles: Int

    init(model: AC3DModel, directory: URL, device: any MTLDevice) throws {
        // FlightGear axes (x aft, y up, z right) to the body frame, nose wheel at the origin.
        let noseWheels = model.groups.filter { $0.part == "gear" }.flatMap(\.positions).filter { $0.x < -8 }
        let noseX = noseWheels.isEmpty ? -13.6 : noseWheels.map(\.x).reduce(0, +) / Float(noseWheels.count)
        let ground = model.boundsMin.y
        func body(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-(p.x - noseX), p.z, p.y - ground) }
        func bodyNormal(_ n: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-n.x, n.z, n.y) }

        var full: [Group] = [], distant: [Group] = [], far: [Group] = []
        var shadowVerts: [MeshVertex] = []
        var fullTris = 0, distantTris = 0, farTris = 0
        for g in model.groups where g.part == "airframe" || g.part == "gear" || g.part == "windshield" {
            guard !g.positions.isEmpty else { continue }
            let material = g.materialIndex < model.materials.count ? model.materials[g.materialIndex] : nil
            let isGlass = (material?.transparency ?? 0) > 0.05 || g.part == "windshield"
            var positions = g.positions.map(body), normals = g.normals.map(bodyNormal)
            let uvs = g.uvs.map { SIMD2($0.x, 1 - $0.y) }
            func vertices(_ p: [SIMD3<Float>], _ n: [SIMD3<Float>], _ t: [SIMD2<Float>]) -> [MeshVertex] {
                (0..<p.count).map { MeshVertex(position: SIMD4(p[$0], 1), normal: SIMD4(n[$0], 0), uv: t[$0]) }
            }
            var draw = DrawUniforms()
            var tint = material?.diffuse ?? SIMD3(0.8, 0.8, 0.8)
            if g.texture != nil { tint /= max(tint.max(), 1e-3) }
            // Windows: dark glass, drawn opaque (the cabin behind is not modelled).
            draw.baseColor = isGlass ? SIMD4(0.05, 0.06, 0.07, 1) : SIMD4(tint, 1)
            let shininess = material?.shininess ?? 16
            draw.material = SIMD4(isGlass ? 0.08 : min(max(sqrt(2 / (shininess + 2)), 0.25), 0.8), 0,
                                  g.texture == nil || isGlass ? 0 : 1, SurfaceKind.aircraft.rawValue)
            let fv = vertices(positions, normals, uvs)
            guard let fb = device.makeBuffer(bytes: fv, length: fv.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared) else { continue }
            full.append(Group(buffer: fb, count: fv.count, textureName: g.texture, draw: draw))
            fullTris += fv.count / 3
            // Distant: vertices merged into 0.45 m cells (small parts vanish, the shape stays).
            (positions, normals) = (positions, normals)
            let d = Self.decimate(positions: positions, normals: normals, uvs: uvs, cell: 0.45)
            guard !d.0.isEmpty else { continue }
            let dv = vertices(d.0, d.1, d.2)
            guard let db = device.makeBuffer(bytes: dv, length: dv.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared) else { continue }
            distant.append(Group(buffer: db, count: dv.count, textureName: g.texture, draw: draw))
            distantTris += dv.count / 3
            let fd = Self.decimate(positions: positions, normals: normals, uvs: uvs, cell: 1.6)
            guard !fd.0.isEmpty else { continue }
            let farVerts = vertices(fd.0, fd.1, fd.2)
            guard let fb2 = device.makeBuffer(bytes: farVerts, length: farVerts.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared) else { continue }
            far.append(Group(buffer: fb2, count: farVerts.count, textureName: g.texture, draw: draw))
            farTris += farVerts.count / 3
            if !isGlass { shadowVerts += farVerts }
        }
        guard let sb = device.makeBuffer(bytes: shadowVerts, length: max(shadowVerts.count, 1) * MemoryLayout<MeshVertex>.stride,
                                         options: .storageModeShared) else { throw RendererError.resource("fleet shadow mesh") }
        self.full = full
        self.distant = distant
        self.far = far
        shadow = (sb, shadowVerts.count)
        fullTriangles = fullTris
        distantTriangles = distantTris
        farTriangles = farTris

        let loader = MTKTextureLoader(device: device)
        var cache: [String: any MTLTexture] = [:]
        func load(_ name: String) -> (any MTLTexture)? {
            if let t = cache[name] { return t }
            let t = try? loader.newTexture(URL: directory.appendingPathComponent(name), options: [
                .SRGB: true, .generateMipmaps: true, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
            cache[name] = t
            return t
        }
        let baseNames = Set(full.compactMap(\.textureName))
        textures = A320Model.liveries.map { livery in
            var map: [String: any MTLTexture] = [:]
            for base in baseNames {
                var file = livery.textures[base] ?? base
                // Traffic uses the smaller fuselage sheets.
                if base == "Fuse-Main.png" { file = file.replacingOccurrences(of: ".png", with: "-1k.png") }
                if let t = load(file) { map[base] = t }
            }
            return map
        }
        liveryCount = A320Model.liveries.count
    }

    /// Vertex clustering: snaps triangle corners to a grid of `cell` metres (and to coarse texture
    /// coordinates, so seams survive), drops triangles that collapse, and averages what merged.
    static func decimate(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>],
                         cell: Float) -> ([SIMD3<Float>], [SIMD3<Float>], [SIMD2<Float>]) {
        struct Key: Hashable { let p: SIMD3<Int32>; let t: SIMD2<Int16> }
        var index: [Key: Int] = [:]
        var sumP: [SIMD3<Float>] = [], sumN: [SIMD3<Float>] = [], sumT: [SIMD2<Float>] = [], counts: [Float] = []
        var corner = [Int](repeating: 0, count: positions.count)
        for i in positions.indices {
            let k = Key(p: SIMD3<Int32>((positions[i] / cell).rounded(.down)), t: SIMD2<Int16>((uvs[i] * 6).rounded(.down)))
            if let j = index[k] {
                sumP[j] += positions[i]; sumN[j] += normals[i]; sumT[j] += uvs[i]; counts[j] += 1
                corner[i] = j
            } else {
                index[k] = sumP.count
                corner[i] = sumP.count
                sumP.append(positions[i]); sumN.append(normals[i]); sumT.append(uvs[i]); counts.append(1)
            }
        }
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = [], t: [SIMD2<Float>] = []
        for tri in stride(from: 0, to: positions.count - 2, by: 3) {
            let a = corner[tri], b = corner[tri + 1], c = corner[tri + 2]
            guard a != b, b != c, a != c else { continue }
            for j in [a, b, c] {
                p.append(sumP[j] / counts[j])
                let nn = sumN[j]
                n.append(simd_length(nn) > 1e-6 ? simd_normalize(nn) : SIMD3(0, 0, 1))
                t.append(sumT[j] / counts[j])
            }
        }
        return (p, n, t)
    }
}
