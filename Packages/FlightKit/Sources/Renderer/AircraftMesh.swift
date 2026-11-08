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
        /// Triangle corners: the index count when `indices` is set (shared vertices), else the
        /// vertex count.
        let vertexCount: Int
        var indices: (any MTLBuffer)? = nil
        let texture: (any MTLTexture)?
        var draw: DrawUniforms
        let isGlass: Bool
        /// Landing gear: not drawn while the gear is up.
        var isGear = false
        /// "prop-slow" or "prop-fast": the still or blurred propeller, drawn by engine speed.
        var variant = ""
        /// An animated part ("anim:..."), moved each frame by `animation`; empty when fixed.
        var animated = ""
        /// AC3D's two-sided flag. One-sided surfaces are culled from behind, as FlightGear
        /// does; the models rely on it (an instrument's case is capped in front of its face).
        var twoSided = true
        /// Inside the airframe (cockpit, flight deck): left out of the shadow map and when the
        /// camera is far outside.
        var interior = false
        /// The windscreen: glass while the flight deck behind it is drawn, dark and opaque when
        /// it is not (from far outside), so the empty nose does not show through.
        var isWindshield = false
        /// A display screen ("pfd1"): drawn with its live image, self-lit.
        var display = ""
        /// Bounding sphere in the model's own frame, for culling parts out of view.
        var centre = SIMD3<Float>.zero
        var radius: Float = 0
    }

    /// Animations for the parts that move (the cockpit's needles, yoke and pedals).
    var animation: AnimatedModel?
    let spinProperties: Set<String>

    private(set) var parts: [Part] = []
    /// Model space -> aircraft body frame (x forward, y left, z up, origin on the ground).
    let modelToBody: simd_float4x4
    /// Bounding sphere in the body frame, for the shadow map.
    let boundsCenter: SIMD3<Float>
    let boundsRadius: Float

    /// The generic narrowbody (the parked-traffic shape) as a flyable stand-in for the A320
    /// until real models arrive: one part in the generic livery, moved so the reference point
    /// sits near the wing rather than at the nose wheel.
    init(genericNarrowbody device: any MTLDevice) throws {
        let spec = ParkedAircraftMesh.narrowbody
        let v = ParkedAircraftMesh.build(spec)
        guard let buffer = device.makeBuffer(bytes: v, length: v.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared) else {
            throw RendererError.resource("generic airliner")
        }
        var draw = DrawUniforms()
        draw.material = SIMD4(0.35, 0, 0, SurfaceKind.parked.rawValue)
        draw.emissive = SIMD4(Float(spec.length), 0, 0, 0)
        parts = [Part(vertices: buffer, vertexCount: v.count, texture: nil, draw: draw, isGlass: false)]
        let wing = Float(spec.noseToGear - spec.wingX - spec.rootChord * 0.1)
        modelToBody = MatrixMath.translation(SIMD3(-wing, 0, 0))
        spinProperties = []
        boundsCenter = SIMD3(0, 0, Float(spec.gearHeight + spec.diameter / 2))
        boundsRadius = Float(spec.span / 2) + 4
    }

    /// `textureMap` swaps texture names (a livery's sheets for the base model's); parts named in
    /// `hiddenParts` are left out.
    init(model: AC3DModel, textureDirectory: URL?, textureMap: [String: String] = [:], hiddenParts: Set<String> = [],
         animation: AnimatedModel? = nil, cullsBackFaces: Bool = false, opaqueGlass: Bool = false, noseWheel: (model: SIMD3<Float>, aheadOfCG: Float)? = nil,
         device: any MTLDevice) throws {
        self.animation = animation
        spinProperties = animation?.spinProperties ?? []
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
        var toBody = lift * centreFwd * axes
        // Put the body origin under the flight model's centre of gravity: the drawn nose wheel
        // goes where the flight model's is.
        if let noseWheel {
            let drawn = toBody * SIMD4(noseWheel.model, 1)
            toBody = MatrixMath.translation(SIMD3(noseWheel.aheadOfCG - drawn.x, 0, 0)) * toBody
        }
        modelToBody = toBody
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

        // Large fixed groups (merged by texture across the whole airframe or flight deck) are
        // cut into 2 m cells, so parts out of view can be skipped.
        var groups: [AC3DModel.Group] = []
        for g in model.groups where !g.positions.isEmpty && !hiddenParts.contains(g.part) {
            guard g.positions.count > 6_000, !g.part.hasPrefix("anim:"), !g.part.hasPrefix("display:") else { groups.append(g); continue }
            var cells: [SIMD3<Int32>: AC3DModel.Group] = [:]
            for t in stride(from: 0, to: g.positions.count - 2, by: 3) {
                let c = (g.positions[t] + g.positions[t + 1] + g.positions[t + 2]) / 3
                let key = SIMD3<Int32>((c / 2).rounded(.down))
                var cell = cells[key] ?? { var e = g; e.positions = []; e.normals = []; e.uvs = []; return e }()
                cell.positions += g.positions[t..<(t + 3)]
                cell.normals += g.normals[t..<(t + 3)]
                cell.uvs += g.uvs[t..<(t + 3)]
                cells[key] = cell
            }
            groups += cells.values
        }
        for group in groups {
            let lo = group.positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = group.positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            // A screen carved from a shared texture sheet: its UVs are stretched to the whole
            // image the sim draws; one with no UVs gets them from its two longest extents.
            var uvs = group.uvs
            if group.part.hasPrefix("display:") {
                let ulo = uvs.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
                let uhi = uvs.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
                if uhi.x - ulo.x > 1e-4, uhi.y - ulo.y > 1e-4 {
                    uvs = uvs.map { ($0 - ulo) / (uhi - ulo) }
                } else {
                    let ext = hi - lo
                    let axes = [0, 1, 2].sorted { ext[$0] > ext[$1] }
                    // In AC3D's frame: x aft, y up, z left. Across the screen is the longer
                    // horizontal extent; up the screen is y unless the screen lies flat.
                    let uAxis = axes[0] == 1 ? axes[1] : axes[0], vAxis = axes.first { $0 != uAxis }!
                    uvs = group.positions.map { p in
                        let u = (p[uAxis] - lo[uAxis]) / max(ext[uAxis], 1e-6), v = (p[vAxis] - lo[vAxis]) / max(ext[vAxis], 1e-6)
                        return SIMD2(uAxis == 2 ? 1 - u : u, v)
                    }
                }
            }
            // Shared vertices: AC3D triangles repeat every corner, which tripled the vertex work
            // (the phone's scene pass was limited by geometry, not pixels).
            struct Key: Hashable { let p: SIMD3<Float>, n: SIMD3<Float>, t: SIMD2<Float> }
            var verts: [MeshVertex] = []
            var lookup: [Key: UInt32] = [:]
            var indexList: [UInt32] = []
            indexList.reserveCapacity(group.positions.count)
            for i in 0..<group.positions.count {
                // AC3D texture v runs bottom-up; Metal samples top-down.
                let uv = SIMD2(uvs[i].x, 1 - uvs[i].y)
                let key = Key(p: group.positions[i], n: group.normals[i], t: uv)
                if let k = lookup[key] { indexList.append(k); continue }
                let k = UInt32(verts.count)
                lookup[key] = k
                indexList.append(k)
                verts.append(MeshVertex(position: SIMD4(group.positions[i], 1), normal: SIMD4(group.normals[i], 0), uv: uv))
            }
            guard let buffer = device.makeBuffer(bytes: verts, length: MemoryLayout<MeshVertex>.stride * verts.count,
                                                 options: .storageModeShared),
                  let indexBuffer = device.makeBuffer(bytes: indexList, length: 4 * indexList.count, options: .storageModeShared)
            else { continue }
            let material = group.materialIndex < model.materials.count
                ? model.materials[group.materialIndex]
                : AC3DModel.Material(name: "", diffuse: SIMD3(0.8, 0.8, 0.8), emissive: .zero, specular: .zero, shininess: 16, transparency: 0)
            // Fully transparent objects are FlightGear's click areas: never seen.
            if material.transparency >= 0.99 && group.part != "windshield" { continue }
            let tex = texture(named: group.texture.map { textureMap[$0] ?? $0 })
            // AC3D materials darken textures (FlightGear lights them brighter); keep the tint,
            // drop the darkening, so textured parts show their painted colour.
            var tint = material.diffuse
            if tex != nil { tint /= max(tint.max(), 1e-3) }
            var isGlass = material.transparency > 0.05 || (group.texture?.lowercased().contains("glass") ?? false)
                || group.part == "windshield"
            var draw = DrawUniforms()
            draw.baseColor = SIMD4(tint, isGlass ? max(0.15, 1 - material.transparency) : 1)
            if group.part == "windshield" {
                // Untextured, lightly tinted: the painted window frames stay on the airframe.
                draw.baseColor = SIMD4(0.25, 0.28, 0.3, 0.05)
            }
            // Paint, not chrome: FlightGear's high shininess values (its effects add their own
            // reflection maps) made the airframe mirror the sky in blotches.
            let interiorPart = animation?.isInterior(part: group.part) ?? false
            var roughness = min(max(sqrt(2 / (material.shininess + 2)), interiorPart ? 0.18 : 0.38), 0.9)
            draw.material = SIMD4(roughness, 0, tex == nil || group.part == "windshield" ? 0 : 1, SurfaceKind.aircraft.rawValue)
            if isGlass && opaqueGlass {
                // Dark, glossy, drawn opaque: an aircraft with nothing modelled behind its windows.
                isGlass = false
                roughness = 0.08
                draw.baseColor = SIMD4(0.035, 0.04, 0.05, 1)
                draw.material = SIMD4(roughness, 0, 0, SurfaceKind.aircraft.rawValue)
            }
            // The cabin sees the sky only through its windows: about a third of it.
            let inside = (animation?.isInterior(part: group.part) ?? false) || group.part.hasPrefix("display:")
            // FlightGear's panels carry emission for their lighting effects; a little of it
            // reads as backlit labels, all of it as a white wash.
            draw.emissive = SIMD4(material.emissive * 0.08, inside ? 0.3 : 0)
            parts.append(Part(vertices: buffer, vertexCount: indexList.count, indices: indexBuffer, texture: tex, draw: draw, isGlass: isGlass,
                              isGear: group.part == "gear", variant: group.part.hasPrefix("prop-") ? group.part : "",
                              animated: group.part.hasPrefix("anim:") ? group.part : "", twoSided: group.twoSided || !cullsBackFaces, interior: inside,
                              isWindshield: group.part == "windshield",
                              display: group.part.hasPrefix("display:") ? String(group.part.dropFirst(8)) : "",
                              centre: (lo + hi) / 2, radius: simd_length(hi - lo) / 2))
        }
    }
}
