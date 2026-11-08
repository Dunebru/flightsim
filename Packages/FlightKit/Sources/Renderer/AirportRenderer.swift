import Airports
import Foundation
import Metal
import SimCore
import simd

/// GPU buffers for one airport, drawn in the scene frame. The airport's meshes are built in its
/// own frame (origin at its reference point); `placement` rotates and moves them into the scene
/// frame, so an airport hundreds of kilometres from the scene origin still sits exactly right.
final class AirportRenderer {
    struct Draw {
        let vertices: any MTLBuffer
        let count: Int
        var uniforms: DrawUniforms
        let atlas: Bool
        /// Depth bias layer: 0 ground pavement, 1 runway (over crossing taxiways), 2 paint.
        let layer: Int
    }

    let name: String
    /// Airport frame to scene frame: rotation (columns are the airport's ENU axes in the scene).
    let rotation: simd_double3x3
    /// The airport origin in the scene frame.
    let origin: SIMD3<Double>
    private(set) var draws: [Draw] = []
    let radius: Double
    let lights: (any MTLBuffer)?
    let lightCount: Int

    /// Building facade codes for the shader (DrawUniforms.emissive.x).
    enum Facade: Float { case terminal = 1, hangar = 2, generic = 3, parking = 4, tower = 5, glass = 6 }

    init?(site: AirportSite, geometry: AirportGeometry, lights points: [LightPoint], sceneFrame: LocalFrame, device: any MTLDevice) {
        name = site.layout.icao
        let a = site.frame
        let o = sceneFrame.enu(a.origin)
        func axis(_ v: SIMD3<Double>) -> SIMD3<Double> { simd_normalize(sceneFrame.enu(a.geodetic(v)) - o) }
        origin = o
        rotation = simd_double3x3(columns: (axis(SIMD3(1, 0, 0)), axis(SIMD3(0, 1, 0)), axis(SIMD3(0, 0, 1))))
        var r = 0.0
        for p in site.surface.ring { r = max(r, simd_length(p)) }
        radius = r + 1_500

        let gpu = points.map { p -> GPULight in
            var behaviour: Float = 0, params = SIMD4<Float>.zero
            switch p.behaviour {
            case .steady: break
            case .flashing(let perSecond, let phase):
                behaviour = 1
                // Strobes flash for 1/25 s; slower lights (runway guard wig-wags) half the cycle.
                params = SIMD4(Float(perSecond), Float(phase), perSecond >= 1.5 ? Float(perSecond / 25) : 0.5, 0)
            case .papi(let angle):
                behaviour = 2
                params = SIMD4(Float(angle * .pi / 180), 0, 0, 0)
            }
            let omni = simd_length(p.direction) < 0.5
            return GPULight(position: SIMD4(SIMD3<Float>(p.position), Float(p.candela)),
                            colour: SIMD4(SIMD3<Float>(p.colour), behaviour),
                            direction: SIMD4(omni ? .zero : SIMD3<Float>(simd_normalize(p.direction)),
                                             Float(cos(p.beamDegrees * .pi / 180))),
                            params: params)
        }
        lightCount = gpu.count
        lights = gpu.isEmpty ? nil : device.makeBuffer(bytes: gpu, length: gpu.count * MemoryLayout<GPULight>.stride, options: .storageModeShared)

        func buffer(_ m: MeshData) -> (any MTLBuffer)? {
            guard !m.positions.isEmpty else { return nil }
            var v = [MeshVertex]()
            v.reserveCapacity(m.positions.count)
            for i in 0..<m.positions.count {
                v.append(MeshVertex(position: SIMD4(m.positions[i], 1), normal: SIMD4(m.normals[i], 0), uv: m.uvs[i]))
            }
            return device.makeBuffer(bytes: v, length: v.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared)
        }
        func add(_ m: MeshData, kind: SurfaceKind, roughness: Float, base: SIMD4<Float> = SIMD4(1, 1, 1, 1),
                 emissive: SIMD4<Float> = .zero, atlas: Bool = false, layer: Int = 0) {
            guard let b = buffer(m) else { return }
            var u = DrawUniforms()
            u.baseColor = base
            u.material = SIMD4(roughness, 0, atlas ? 1 : 0, kind.rawValue)
            u.emissive = emissive
            draws.append(Draw(vertices: b, count: m.positions.count, uniforms: u, atlas: atlas, layer: layer))
        }
        add(geometry.concrete, kind: .pavement, roughness: 0.9, emissive: SIMD4(0, 0, 0, 0))
        add(geometry.asphalt, kind: .pavement, roughness: 0.9, emissive: SIMD4(1, 0, 0, 0))
        for rw in geometry.runways {
            add(rw.surface, kind: .runway, roughness: 0.88,
                emissive: SIMD4(Float(rw.length), Float(rw.width), rw.asphalt ? 0 : 1, 0), layer: 1)
        }
        for rw in geometry.runways {
            add(rw.markings, kind: .marking, roughness: 0.7, base: SIMD4(0.80, 0.80, 0.78, 1), atlas: true, layer: 2)
        }
        add(geometry.yellowPaint, kind: .marking, roughness: 0.7, base: SIMD4(0.78, 0.56, 0.08, 1), layer: 2)
        let facades: [(Building.Kind, Facade)] = [(.terminal, .terminal), (.hangar, .hangar), (.generic, .generic),
                                                  (.parking, .parking), (.tower, .tower)]
        for (kind, facade) in facades {
            if let m = geometry.buildings[kind] {
                add(m, kind: .building, roughness: 0.8, emissive: SIMD4(facade.rawValue, 0, 0, 0))
            }
        }
        add(geometry.glazing, kind: .building, roughness: 0.08, emissive: SIMD4(Facade.glass.rawValue, 0, 0, 0))
        if draws.isEmpty { return nil }
    }

    /// Model matrix into camera-relative world for a camera at `camera` (scene frame).
    func model(relativeTo camera: SIMD3<Double>, offset: SIMD3<Double>) -> simd_float4x4 {
        let t = SIMD3<Float>(origin + offset - camera)
        let m = rotation
        return simd_float4x4(columns: (
            SIMD4(SIMD3<Float>(m.columns.0), 0), SIMD4(SIMD3<Float>(m.columns.1), 0),
            SIMD4(SIMD3<Float>(m.columns.2), 0), SIMD4(t, 1)))
    }
}
