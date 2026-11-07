import Aircraft
import Foundation
import Metal
import MetalKit
import simd

/// The test aircraft on the GPU: one vertex buffer per AC3D material group, textures loaded as
/// sRGB with mipmaps. Placeholder quality (M1): no normal maps, no animation, no liveries.
final class AircraftMesh {
    struct Part {
        let vertices: any MTLBuffer
        let vertexCount: Int
        let texture: (any MTLTexture)?
        var draw: DrawUniforms
        let isGlass: Bool
    }

    private(set) var parts: [Part] = []
    /// Model space -> aircraft body frame (x forward, y left, z up, origin on the ground).
    let modelToBody: simd_float4x4
    /// Bounding sphere in the body frame, for the shadow map.
    let boundsCenter: SIMD3<Float>
    let boundsRadius: Float

    init(model: AC3DModel, textureDirectory: URL?, device: any MTLDevice) throws {
        // FlightGear AC3D: x runs along the fuselage, y is up, z is the span. Find the nose by
        // where the propeller sits; default to FlightGear's convention (nose toward -x).
        let center = (model.boundsMin + model.boundsMax) / 2
        var noseSign: Float = -1
        if let prop = model.groups.first(where: { $0.texture?.lowercased().contains("prop") == true }), !prop.positions.isEmpty {
            let px = prop.positions.reduce(Float(0)) { $0 + $1.x } / Float(prop.positions.count)
            noseSign = px < center.x ? -1 : 1
        }
        // Proper rotations (det +1) taking (x, y, z)_ac to (forward, left, up)_body.
        let axes: simd_float4x4 = noseSign < 0
            ? simd_float4x4(rows: [SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)])
            : simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)])
        // Rest the lowest point (the wheels) on the ground and centre the airframe.
        let minUp = model.boundsMin.y
        let lift = MatrixMath.translation(SIMD3(0, 0, -minUp))
        let centreFwd = MatrixMath.translation(SIMD3(noseSign < 0 ? center.x : -center.x, noseSign < 0 ? -center.z : center.z, 0))
        modelToBody = lift * centreFwd * axes
        let size = model.boundsMax - model.boundsMin
        boundsCenter = SIMD3(0, 0, size.y / 2)
        boundsRadius = simd_length(size) / 2

        let loader = MTKTextureLoader(device: device)
        var cache: [String: any MTLTexture] = [:]
        func texture(named name: String?) -> (any MTLTexture)? {
            guard let name, let dir = textureDirectory else { return nil }
            if let t = cache[name] { return t }
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let t = try? loader.newTexture(URL: url, options: [
                .SRGB: true, .generateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
            cache[name] = t
            return t
        }

        for group in model.groups where !group.positions.isEmpty {
            var verts: [MeshVertex] = []
            verts.reserveCapacity(group.positions.count)
            for i in 0..<group.positions.count {
                // AC3D texture v runs bottom-up; Metal samples top-down.
                let uv = group.uvs[i]
                verts.append(MeshVertex(position: SIMD4(group.positions[i], 1), normal: SIMD4(group.normals[i], 0),
                                        uv: SIMD2(uv.x, 1 - uv.y)))
            }
            guard let buffer = device.makeBuffer(bytes: verts, length: MemoryLayout<MeshVertex>.stride * verts.count,
                                                 options: .storageModeShared) else { continue }
            let material = group.materialIndex < model.materials.count
                ? model.materials[group.materialIndex]
                : AC3DModel.Material(name: "", diffuse: SIMD3(0.8, 0.8, 0.8), emissive: .zero, specular: .zero, shininess: 16, transparency: 0)
            let tex = texture(named: group.texture)
            // AC3D materials darken textures (FlightGear lights them brighter); keep the tint,
            // drop the darkening, so textured parts show their painted colour.
            var tint = material.diffuse
            if tex != nil { tint /= max(tint.max(), 1e-3) }
            let isGlass = material.transparency > 0.05 || (group.texture?.lowercased().contains("glass") ?? false)
            var draw = DrawUniforms()
            draw.baseColor = SIMD4(tint, isGlass ? max(0.15, 1 - material.transparency) : 1)
            let roughness = min(max(sqrt(2 / (material.shininess + 2)), 0.18), 0.9)
            draw.material = SIMD4(roughness, 0, tex == nil ? 0 : 1, SurfaceKind.aircraft.rawValue)
            draw.emissive = SIMD4(material.emissive, 0)
            parts.append(Part(vertices: buffer, vertexCount: verts.count, texture: tex, draw: draw, isGlass: isGlass))
        }
    }
}
