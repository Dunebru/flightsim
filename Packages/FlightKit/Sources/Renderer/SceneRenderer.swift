public import Aircraft
public import Foundation
public import Metal
import os
import simd
public import SimCore
import Synchronization
public import Terrain

/// The M1 renderer: physically based sky and aerial perspective, procedural ground, a marked
/// runway, the test aircraft with a sun shadow, tone mapping and MetalFX upscaling.
///
/// Precision: world positions stay in Double and every object is drawn relative to the camera
/// (floating origin), so the scene renders identically thousands of kilometres from the origin.
public final class SceneRenderer {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    public var settings = RenderSettings()

    // Pipelines
    private let transmittancePipeline: any MTLComputePipelineState
    private let multiScatterPipeline: any MTLComputePipelineState
    private let skyViewPipeline: any MTLComputePipelineState
    private let aerialPipeline: any MTLComputePipelineState
    private let lightingPipeline: any MTLComputePipelineState
    private let scenePipeline: any MTLRenderPipelineState
    private let skyPipeline: any MTLRenderPipelineState
    private let glassPipeline: any MTLRenderPipelineState
    private let terrainPipeline: any MTLRenderPipelineState
    private let shadowPipeline: any MTLRenderPipelineState
    private let tonemapPipeline: any MTLRenderPipelineState
    private var finalPipelines: [MTLPixelFormat.RawValue: any MTLRenderPipelineState] = [:]
    private let library: any MTLLibrary
    private let depthWrite: any MTLDepthStencilState
    private let depthTestOnly: any MTLDepthStencilState
    private let depthSky: any MTLDepthStencilState
    private let shadowDepth: any MTLDepthStencilState

    // Atmosphere resources
    private let transmittanceLUT: any MTLTexture
    private let multiScatterLUT: any MTLTexture
    private let skyViewLUT: any MTLTexture
    private let aerialVolume: any MTLTexture
    private let lightingBuffer: any MTLBuffer
    private var lutsReady = false

    // Scene resources
    private let shadowMap: any MTLTexture
    private let shadowSize = 2048
    private let dummyTexture: any MTLTexture
    private let markingAtlas: any MTLTexture
    private let groundBuffer: any MTLBuffer
    private let groundVertexCount: Int
    private var terrain: TerrainRenderer?
    private let runwayBuffer: any MTLBuffer
    private let runwayVertexCount: Int
    private let markingsBuffer: any MTLBuffer
    private let markingsVertexCount: Int
    private let runway = RunwaySpec.kphx08_26
    private var aircraft: AircraftMesh?

    // Per-size targets
    private var targets: Targets?
    private struct Targets {
        let renderSize: SIMD2<Int>
        let outputSize: SIMD2<Int>
        let hdr: any MTLTexture
        let motion: any MTLTexture
        let depth: any MTLTexture
        let ldr: any MTLTexture
        let upscaler: Upscaler
    }

    // Temporal state
    private var frameIndex = 0
    private var previousCamera: SIMD3<Double>?
    private var previousViewProj: simd_float4x4?
    private var previousAircraftModel: simd_float4x4?
    /// 1 = adapt exposure immediately (first frame, offscreen); otherwise per-frame blend.
    public var exposureAdaptation: Float = 1

    private let statsBox = StatsBox()
    private let signposter = OSSignposter(subsystem: "com.shreyas.flightsim", category: "Renderer")

    public var stats: FrameStats { statsBox.value }

    /// Lighting state from the last completed frame: (sky irradiance luminance, sun luminance,
    /// exposure). Shared memory, read after the GPU finishes.
    public var lightingDebug: SIMD3<Float> {
        let p = lightingBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3)
        let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        let sky = SIMD3(p[0].x, p[0].y, p[0].z), sun = SIMD3(p[1].x, p[1].y, p[1].z)
        return SIMD3(simd_dot(sky, luma), simd_dot(sun, luma), p[2].x)
    }

    public static let colorFormat: MTLPixelFormat = .rgba16Float
    public static let motionFormat: MTLPixelFormat = .rg16Float
    public static let depthFormat: MTLPixelFormat = .depth32Float

    // MARK: Init

    public init(device: any MTLDevice, aircraftModel: AC3DModel?, aircraftTextures: URL?) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.resource("command queue") }
        self.queue = queue
        let lib = try ShaderLibrary.make(device: device)
        library = lib

        func compute(_ name: String) throws -> any MTLComputePipelineState {
            guard let f = lib.makeFunction(name: name) else { throw RendererError.resource("function \(name)") }
            return try device.makeComputePipelineState(function: f)
        }
        transmittancePipeline = try compute("transmittanceLUT")
        multiScatterPipeline = try compute("multiScatterLUT")
        skyViewPipeline = try compute("skyViewLUT")
        aerialPipeline = try compute("aerialPerspective")
        lightingPipeline = try compute("lightingState")

        func render(_ vertex: String, _ fragment: String?, colors: [MTLPixelFormat], depth: MTLPixelFormat?,
                    configure: (MTLRenderPipelineDescriptor) -> Void = { _ in }) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vertex)
            d.fragmentFunction = fragment.flatMap { lib.makeFunction(name: $0) }
            for (i, f) in colors.enumerated() { d.colorAttachments[i].pixelFormat = f }
            if let depth { d.depthAttachmentPixelFormat = depth }
            configure(d)
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let gbuffer: [MTLPixelFormat] = [Self.colorFormat, Self.motionFormat]
        scenePipeline = try render("sceneVertex", "sceneFragment", colors: gbuffer, depth: Self.depthFormat)
        skyPipeline = try render("skyVertex", "skyFragment", colors: gbuffer, depth: Self.depthFormat)
        terrainPipeline = try render("terrainVertex", "sceneFragment", colors: gbuffer, depth: Self.depthFormat)
        glassPipeline = try render("sceneVertex", "glassFragment", colors: gbuffer, depth: Self.depthFormat) { d in
            let c = d.colorAttachments[0]!
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[1].writeMask = []
        }
        shadowPipeline = try render("shadowVertex", nil, colors: [], depth: Self.depthFormat)
        tonemapPipeline = try render("fullscreenVertex", "tonemapFragment", colors: [Upscaler.colorFormat], depth: nil)

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> any MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw RendererError.resource("depth state") }
            return s
        }
        // Reverse-Z: nearer is larger.
        depthWrite = try depthState(.greater, write: true)
        depthTestOnly = try depthState(.greater, write: false)
        depthSky = try depthState(.greaterEqual, write: false)
        shadowDepth = try depthState(.lessEqual, write: true)

        func texture2D(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resource("texture") }
            return t
        }
        let rw: MTLTextureUsage = [.shaderRead, .shaderWrite]
        transmittanceLUT = try texture2D(.rgba16Float, 256, 64, rw)
        multiScatterLUT = try texture2D(.rgba16Float, 32, 32, rw)
        skyViewLUT = try texture2D(.rgba16Float, 192, 108, rw)
        let ad = MTLTextureDescriptor()
        ad.textureType = .type3D
        ad.pixelFormat = .rgba16Float
        ad.width = 32; ad.height = 32; ad.depth = 32
        ad.usage = rw
        ad.storageMode = .private
        guard let aerial = device.makeTexture(descriptor: ad) else { throw RendererError.resource("aerial volume") }
        aerialVolume = aerial
        guard let lb = device.makeBuffer(length: lightingStateSize, options: .storageModeShared) else {
            throw RendererError.resource("lighting buffer")
        }
        memset(lb.contents(), 0, lightingStateSize)
        lightingBuffer = lb
        shadowMap = try texture2D(Self.depthFormat, shadowSize, shadowSize, [.renderTarget, .shaderRead])

        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        dd.usage = .shaderRead
        dd.storageMode = .shared
        guard let dummy = device.makeTexture(descriptor: dd) else { throw RendererError.resource("dummy") }
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        dummyTexture = dummy
        guard let atlas = MarkingAtlas.makeTexture(device: device, queue: queue) else { throw RendererError.resource("marking atlas") }
        markingAtlas = atlas

        func buffer(_ v: [MeshVertex]) throws -> any MTLBuffer {
            guard let b = device.makeBuffer(bytes: v, length: max(1, v.count) * MemoryLayout<MeshVertex>.stride,
                                            options: .storageModeShared) else { throw RendererError.resource("vertex buffer") }
            return b
        }
        // Ground: a 600 km square grid that follows the camera, bent with Earth's curvature.
        let grid = RunwayGeometry.grid(halfSize: 300_000, cells: 96, z: 0)
        groundBuffer = try buffer(grid)
        groundVertexCount = grid.count
        let surface = RunwayGeometry.surface(runway)
        runwayBuffer = try buffer(surface)
        runwayVertexCount = surface.count
        let marks = RunwayGeometry.markings(runway)
        markingsBuffer = try buffer(marks)
        markingsVertexCount = marks.count

        aircraft = try aircraftModel.map { try AircraftMesh(model: $0, textureDirectory: aircraftTextures, device: device) }
    }

    // MARK: Frame

    /// Encodes and commits one frame into `target` (a drawable's texture or an offscreen
    /// texture), presenting `drawable` if given.
    @discardableResult
    public func render(_ scene: SceneDescription, to target: any MTLTexture, drawable: (any MTLDrawable)? = nil) -> any MTLCommandBuffer {
        let signpostID = signposter.makeSignpostID()
        let frameState = signposter.beginInterval("Frame", id: signpostID)
        let cpuStart = ContinuousClock.now
        let outputSize = SIMD2(target.width, target.height)
        let scale = min(max(settings.renderScale, 0.25), 1)
        let renderSize = SIMD2(max(1, Int((Double(outputSize.x) * scale).rounded())),
                               max(1, Int((Double(outputSize.y) * scale).rounded())))
        let t = ensureTargets(render: renderSize, output: outputSize)
        let temporal = t.upscaler.mode == .temporal

        // Camera and jitter
        let offset = scene.worldOffset
        let pose = scene.cameraPose ?? scene.camera.pose
        let camera = pose.position + offset
        let forward = SIMD3<Float>(pose.forward)
        let jitter: SIMD2<Float> = temporal
            ? SIMD2(MatrixMath.halton(frameIndex % 16 + 1, base: 2) - 0.5, MatrixMath.halton(frameIndex % 16 + 1, base: 3) - 0.5)
            : .zero
        let ndcJitter = SIMD2(2 * jitter.x / Float(renderSize.x), -2 * jitter.y / Float(renderSize.y))
        let aspect = Float(renderSize.x) / Float(renderSize.y)
        let view = MatrixMath.lookDirection(forward, up: SIMD3<Float>(pose.up))
        let fov = Float(pose.fovY)
        let projection = MatrixMath.perspectiveReverseZ(fovY: fov, aspect: aspect, near: 0.1, jitter: ndcJitter)
        let projectionNoJitter = MatrixMath.perspectiveReverseZ(fovY: fov, aspect: aspect, near: 0.1)
        let viewProjNoJitter = projectionNoJitter * view
        let previousCam = previousCamera ?? camera
        let reset = previousCamera == nil || simd_distance(previousCam, camera) > 500

        func relative(_ p: SIMD3<Double>, to cam: SIMD3<Double>) -> SIMD3<Float> {
            if settings.disableFloatingOrigin { return SIMD3<Float>(p) - SIMD3<Float>(cam) }
            return SIMD3<Float>(p - cam)
        }

        var u = FrameUniforms()
        u.viewProj = projection * view
        u.viewProjNoJitter = viewProjNoJitter
        u.prevViewProjNoJitter = reset ? viewProjNoJitter : (previousViewProj ?? viewProjNoJitter)
        u.invViewProjNoJitter = viewProjNoJitter.inverse
        u.cameraDelta = SIMD4(SIMD3<Float>(camera - previousCam), 0)
        let sun = SolarEphemeris.sunPosition(at: scene.date, latitude: scene.origin.latitude, longitude: scene.origin.longitude)
        let sunDir = SIMD3<Float>(sun.directionENU)
        u.sunDirection = SIMD4(sunDir, 0)
        u.sunIlluminance = SIMD4(1, 1, 1, 0)
        let cameraAboveGround = max(camera.z - offset.z, 0.5)
        // Aerial perspective reaches past the farthest terrain in view: 80 km plus the distance
        // to the horizon (about 357 km from 10 km up), so distant ranges fade into the sky.
        let horizonKm = (2 * 6_371 * max(cameraAboveGround, 1) / 1000).squareRoot()
        let aerialRangeKm = Float(min(80 + horizonKm, 450))
        u.atmosphere = SIMD4(Float(cameraAboveGround / 1000), Float(scene.origin.height / 1000), aerialRangeKm,
                             Float(scene.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 10_000)))
        // Procedural detail is anchored to the scene frame (not the floating-origin offset), so
        // patterns stay put as the camera moves.
        u.noiseOrigin = SIMD4(Float(pose.position.x), Float(pose.position.y), 0, 0)
        u.renderSize = SIMD4(Float(renderSize.x), Float(renderSize.y), 1 / Float(renderSize.x), 1 / Float(renderSize.y))
        u.jitter = SIMD4(jitter.x, jitter.y, 0, 0)
        u.debug = SIMD4(scene.showGround ? 1 : 0, 0, 0, 0)

        // Draws. With terrain loaded the procedural ground is only a fallback past the scenery's
        // edge, so it sits just below sea level (under all the terrain, whose heights are clamped
        // at sea level). Without terrain it is level with the low end of the sloped runway, so no
        // pavement is buried.
        let groundLevel: Double = terrain == nil
            ? -Double(runway.gradient * runway.length / 2) - 0.05
            : -scene.origin.height - 30
        let groundZ = Float(offset.z + groundLevel - camera.z)
        var groundDraw = DrawUniforms()
        groundDraw.model = MatrixMath.translation(SIMD3(0, 0, groundZ))
        groundDraw.prevModel = MatrixMath.translation(SIMD3<Float>(camera - previousCam)) * groundDraw.model
        groundDraw.material = SIMD4(0.95, 0, 0, SurfaceKind.ground.rawValue)
        groundDraw.emissive = SIMD4(Float(pose.position.x), Float(pose.position.y), 0, 0)

        // Runway: heading about z, then its slope (rising toward the high end).
        let runwayRotation = MatrixMath.rotationZ(Float((90 - Double(runway.heading)) * .pi / 180))
            * MatrixMath.rotationY(-atan(runway.gradient))
        let runwayCenter = offset
        var runwayDraw = DrawUniforms()
        runwayDraw.model = MatrixMath.translation(relative(runwayCenter, to: camera)) * runwayRotation
        runwayDraw.prevModel = MatrixMath.translation(relative(runwayCenter, to: previousCam)) * runwayRotation
        runwayDraw.material = SIMD4(0.85, 0, 0, SurfaceKind.runway.rawValue)
        runwayDraw.emissive = SIMD4(runway.length, runway.width, 0, 0)
        var markingDraw = runwayDraw
        markingDraw.material = SIMD4(0.7, 0, 1, SurfaceKind.marking.rawValue)
        markingDraw.emissive = .zero

        let aircraftWorld = scene.aircraftPosition + offset
        var aircraftModel = matrix_identity_float4x4
        var aircraftPrev = matrix_identity_float4x4
        var shadowOn = false
        if let aircraft {
            // Body frame: x forward, y left, z up. Heading about z, then pitch (nose up is a
            // negative rotation about +y), then bank (right wing down is positive about +x).
            let orient = MatrixMath.rotationZ(Float(.pi / 2 - scene.aircraftHeading))
                * MatrixMath.rotationY(Float(-scene.aircraftPitch))
                * MatrixMath.rotationX(Float(scene.aircraftRoll))
                * aircraft.modelToBody
            aircraftModel = MatrixMath.translation(relative(aircraftWorld, to: camera)) * orient
            aircraftPrev = reset ? aircraftModel : MatrixMath.translation(relative(aircraftWorld, to: previousCam)) * orient
            // Sun shadow map around the aircraft.
            if sunDir.z > 0.02 && scene.showAircraft {
                let centre = relative(aircraftWorld, to: camera) + SIMD3(0, 0, aircraft.boundsCenter.z)
                let radius = aircraft.boundsRadius * 1.15
                let up: SIMD3<Float> = abs(sunDir.z) > 0.98 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
                let lightView = MatrixMath.lookAt(eye: centre + sunDir * 60, target: centre, up: up)
                u.shadowViewProj = MatrixMath.orthographic(halfWidth: radius, halfHeight: radius, near: 1, far: 120) * lightView
                u.shadowParams = SIMD4(1, 0.0015, 1 / Float(shadowSize), 0)
                shadowOn = true
            }
        }

        // MARK: Encode
        let encodeAtmosphere = signposter.beginInterval("Encode atmosphere")
        let cbAtmosphere = makeCommandBuffer(label: "Atmosphere")
        if let c = cbAtmosphere.makeComputeCommandEncoder() {
            if !lutsReady {
                dispatch(c, transmittancePipeline, textures: [transmittanceLUT], size: SIMD3(256, 64, 1))
                dispatch(c, multiScatterPipeline, textures: [multiScatterLUT, transmittanceLUT], size: SIMD3(32, 32, 1))
                lutsReady = true
            }
            c.setBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            dispatch(c, skyViewPipeline, textures: [skyViewLUT, transmittanceLUT, multiScatterLUT], size: SIMD3(192, 108, 1))
            dispatch(c, aerialPipeline, textures: [aerialVolume, transmittanceLUT, multiScatterLUT], size: SIMD3(32, 32, 1))
            c.setComputePipelineState(lightingPipeline)
            c.setBuffer(lightingBuffer, offset: 0, index: 0)
            c.setBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            var adaptation = exposureAdaptation
            c.setBytes(&adaptation, length: 4, index: 2)
            c.setTexture(skyViewLUT, index: 0)
            c.setTexture(transmittanceLUT, index: 1)
            c.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            c.endEncoding()
        }
        // Terrain: upload finished tiles (mipmaps go into this command buffer) and select the
        // tiles for this camera.
        let frustum = MatrixMath.frustumPlanes(viewProjNoJitter)
        let terrainTiles = scene.showGround
            ? (terrain?.update(camera: camera - offset, frustum: frustum, commandBuffer: cbAtmosphere) ?? []) : []
        cbAtmosphere.commit()
        signposter.endInterval("Encode atmosphere", encodeAtmosphere)

        if shadowOn, let aircraft {
            let cbShadow = makeCommandBuffer(label: "Shadow")
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = shadowMap
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .store
            if let e = cbShadow.makeRenderCommandEncoder(descriptor: pass) {
                e.setRenderPipelineState(shadowPipeline)
                e.setDepthStencilState(shadowDepth)
                e.setCullMode(.none)
                e.setDepthBias(1, slopeScale: 2, clamp: 0.01)
                e.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                for part in aircraft.parts where !part.isGlass {
                    var d = part.draw
                    d.model = aircraftModel
                    e.setVertexBuffer(part.vertices, offset: 0, index: 0)
                    e.setVertexBytes(&d, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: part.vertexCount)
                }
                e.endEncoding()
            }
            cbShadow.commit()
        }

        let encodeScene = signposter.beginInterval("Encode scene")
        let cbScene = makeCommandBuffer(label: "Scene")
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = t.hdr
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = t.motion
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[1].storeAction = .store
        pass.depthAttachment.texture = t.depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        if let e = cbScene.makeRenderCommandEncoder(descriptor: pass) {
            e.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentBuffer(lightingBuffer, offset: 0, index: 3)
            e.setFragmentTexture(skyViewLUT, index: 1)
            e.setFragmentTexture(aerialVolume, index: 2)
            e.setFragmentTexture(shadowMap, index: 3)
            e.setFragmentTexture(transmittanceLUT, index: 4)
            e.setRenderPipelineState(scenePipeline)
            e.setDepthStencilState(depthWrite)
            e.setCullMode(.none)

            func draw(_ buffer: any MTLBuffer, count: Int, _ d: DrawUniforms, texture: (any MTLTexture)?) {
                var d = d
                e.setVertexBuffer(buffer, offset: 0, index: 0)
                e.setVertexBytes(&d, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                e.setFragmentBytes(&d, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                e.setFragmentTexture(texture ?? dummyTexture, index: 0)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
            }
            if scene.showGround {
                if settings.fallbackGround || terrain == nil {
                    draw(groundBuffer, count: groundVertexCount, groundDraw, texture: nil)
                }
                var drawn = 0
                if !terrainTiles.isEmpty { e.setRenderPipelineState(terrainPipeline) }
                for tile in terrainTiles {
                    let world = tile.centre + offset
                    let rel = relative(world, to: camera)
                    guard MatrixMath.sphereVisible(centre: rel, radius: Float(tile.radius), planes: frustum) else { continue }
                    var d = DrawUniforms()
                    d.model = MatrixMath.translation(rel)
                    d.prevModel = MatrixMath.translation(relative(world, to: previousCam))
                    d.baseColor = SIMD4(terrainAlbedoScale, terrainAlbedoScale, terrainAlbedoScale, 1)
                    d.material = SIMD4(0.92, 0, 1, SurfaceKind.terrain.rawValue)
                    e.setVertexBuffer(tile.vertices, offset: 0, index: 0)
                    e.setVertexBytes(&d, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    e.setFragmentBytes(&d, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                    e.setFragmentTexture(tile.texture, index: 0)
                    if let terrain {
                        e.drawIndexedPrimitives(type: .triangle, indexCount: terrain.indexCount, indexType: .uint16,
                                                indexBuffer: terrain.indices, indexBufferOffset: 0)
                    }
                    drawn += 1
                }
                terrainDrawn = drawn
                e.setRenderPipelineState(scenePipeline)
            }
            if scene.showRunway {
                draw(runwayBuffer, count: runwayVertexCount, runwayDraw, texture: nil)
                e.setDepthBias(4, slopeScale: 4, clamp: 0)
                draw(markingsBuffer, count: markingsVertexCount, markingDraw, texture: markingAtlas)
                e.setDepthBias(0, slopeScale: 0, clamp: 0)
            }
            if let aircraft, scene.showAircraft {
                for part in aircraft.parts where !part.isGlass {
                    var d = part.draw
                    d.model = aircraftModel
                    d.prevModel = aircraftPrev
                    draw(part.vertices, count: part.vertexCount, d, texture: part.texture)
                }
            }
            if !settings.blackSkyForTest {
                e.setRenderPipelineState(skyPipeline)
                e.setDepthStencilState(depthSky)
                e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            if let aircraft, scene.showAircraft {
                e.setRenderPipelineState(glassPipeline)
                e.setDepthStencilState(depthTestOnly)
                for part in aircraft.parts where part.isGlass {
                    var d = part.draw
                    d.model = aircraftModel
                    d.prevModel = aircraftPrev
                    draw(part.vertices, count: part.vertexCount, d, texture: part.texture)
                }
            }
            e.endEncoding()
        }
        cbScene.commit()
        signposter.endInterval("Encode scene", encodeScene)

        let encodePost = signposter.beginInterval("Encode post")
        let cbPost = makeCommandBuffer(label: "Post")
        let tonePass = MTLRenderPassDescriptor()
        tonePass.colorAttachments[0].texture = t.ldr
        tonePass.colorAttachments[0].loadAction = .dontCare
        tonePass.colorAttachments[0].storeAction = .store
        if let e = cbPost.makeRenderCommandEncoder(descriptor: tonePass) {
            e.setRenderPipelineState(tonemapPipeline)
            e.setFragmentTexture(t.hdr, index: 0)
            e.setFragmentBuffer(lightingBuffer, offset: 0, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        let upscaled = t.upscaler.encode(commandBuffer: cbPost, color: t.ldr, depth: t.depth, motion: t.motion,
                                         jitter: settings.flipJitterSignForTest ? -jitter : jitter, reset: reset)
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = target
        finalPass.colorAttachments[0].loadAction = .dontCare
        finalPass.colorAttachments[0].storeAction = .store
        if let e = cbPost.makeRenderCommandEncoder(descriptor: finalPass),
           let pipeline = try? finalPipeline(for: target.pixelFormat) {
            e.setRenderPipelineState(pipeline)
            e.setFragmentTexture(upscaled, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        if let drawable { cbPost.present(drawable) }
        cbPost.commit()
        signposter.endInterval("Encode post", encodePost)

        // Bookkeeping
        previousCamera = camera
        previousViewProj = viewProjNoJitter
        previousAircraftModel = aircraftModel
        frameIndex += 1
        let cpu = ContinuousClock.now - cpuStart
        statsBox.update { s in
            s.cpuMilliseconds = s.frameCount == 0 ? cpu.milliseconds : s.cpuMilliseconds * 0.9 + cpu.milliseconds * 0.1
            s.renderSize = renderSize
            s.outputSize = outputSize
            s.upscaler = t.upscaler.mode
            s.frameCount += 1
        }
        signposter.endInterval("Frame", frameState)
        return cbPost
    }

    /// Renders one frame offscreen and returns BGRA8 pixels (display-encoded). For tests and
    /// screenshots; blocks until the GPU finishes.
    public func renderImage(_ scene: SceneDescription, width: Int, height: Int, warmupFrames: Int = 0) throws -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let target = device.makeTexture(descriptor: d),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared) else {
            throw RendererError.resource("offscreen target")
        }
        for _ in 0...warmupFrames {
            render(scene, to: target)
        }
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            throw RendererError.resource("readback")
        }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let error = cb.error { throw error }
        let p = readback.contents().bindMemory(to: UInt8.self, capacity: width * height * 4)
        return Array(UnsafeBufferPointer(start: p, count: width * height * 4))
    }

    /// Whether this device can run the given MetalFX mode.
    public static func supports(_ mode: UpscalerMode, device: any MTLDevice) -> Bool {
        Upscaler.supports(mode, device: device)
    }

    /// Streams terrain from a scenery pack, in the scene frame of `origin`. `flatten` areas
    /// are held just under the drawn pavement. Pass nil to remove terrain.
    public func setTerrain(_ pack: SceneryLibrary?, origin: Geodetic, flatten: [FlattenArea]) {
        let lowered = flatten.map { a in var a = a; a.height -= 0.25; return a }
        terrain = pack.map { TerrainRenderer(pack: $0, frame: LocalFrame(origin: origin), flatten: lowered, device: device) }
        previousCamera = nil
    }

    /// Terrain refinement: a tile splits while its radius over its distance exceeds this.
    public var terrainDetail: Double {
        get { terrain?.detail ?? 0.55 }
        set { terrain?.detail = newValue }
    }

    /// GPU memory budget for terrain, megabytes.
    public var terrainBudgetMegabytes: Int {
        get { (terrain?.budgetBytes ?? 0) / 1_048_576 }
        set { terrain?.budgetBytes = newValue * 1_048_576 }
    }

    /// Multiplies the satellite imagery to give surface albedo.
    public var terrainAlbedoScale: Float = 0.8
    /// Terrain tiles drawn in the last frame, resident on the GPU, and requested but not ready.
    public private(set) var terrainDrawn = 0
    public var terrainResident: (tiles: Int, megabytes: Double) {
        (terrain?.loadedCount ?? 0, Double(terrain?.residentBytes ?? 0) / 1_048_576)
    }
    public var terrainPending: Int { terrain?.pendingCount ?? 0 }
    /// True while terrain needs more memory than its budget (detail is backing off).
    public var terrainOverBudget: Bool { terrain?.overBudget ?? false }
    /// One line on the streamer's state, for logs and test failures.
    public var terrainDebug: String {
        guard let t = terrain else { return "no terrain" }
        return String(format: "selected %d, drawn %d, resident %d (%.0f MB, budget %d MB), pending %d, broken %d, detail back-off %.2f",
                      t.lastSelected, terrainDrawn, t.loadedCount, Double(t.residentBytes) / 1_048_576,
                      t.budgetBytes / 1_048_576, t.pendingCount, t.broken.count, t.pressure)
    }

    /// Replaces the aircraft (models load in the background after the first frame).
    public func setAircraft(_ model: AC3DModel, textures: URL?) throws {
        aircraft = try AircraftMesh(model: model, textureDirectory: textures, device: device)
        previousCamera = nil
    }

    /// Forget temporal history (camera cut, new scene).
    public func resetHistory() {
        previousCamera = nil
        previousViewProj = nil
        exposureAdaptation = 1
    }

    // MARK: Helpers

    private func makeCommandBuffer(label: String) -> any MTLCommandBuffer {
        let cb = queue.makeCommandBuffer()!
        cb.label = label
        let box = statsBox
        let frame = frameIndex
        box.beginStage(frame: frame)
        cb.addCompletedHandler { buffer in
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            box.update { s in
                let old = s.gpuMilliseconds[label] ?? ms
                s.gpuMilliseconds[label] = old * 0.9 + ms * 0.1
                s.gpuTotalMilliseconds = s.gpuMilliseconds.values.reduce(0, +)
            }
            box.endStage(frame: frame, start: buffer.gpuStartTime, end: buffer.gpuEndTime)
        }
        return cb
    }

    private func dispatch(_ c: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState,
                          textures: [any MTLTexture], size: SIMD3<Int>) {
        c.setComputePipelineState(pipeline)
        for (i, t) in textures.enumerated() { c.setTexture(t, index: i) }
        c.dispatchThreads(MTLSize(width: size.x, height: size.y, depth: size.z),
                          threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    private func finalPipeline(for format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
        if let p = finalPipelines[format.rawValue] { return p }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        d.fragmentFunction = library.makeFunction(name: "finalFragment")
        d.colorAttachments[0].pixelFormat = format
        let p = try device.makeRenderPipelineState(descriptor: d)
        finalPipelines[format.rawValue] = p
        return p
    }

    private func ensureTargets(render: SIMD2<Int>, output: SIMD2<Int>) -> Targets {
        if let t = targets, t.renderSize == render, t.outputSize == output, t.upscaler.mode == resolvedMode(settings.upscaler) {
            return t
        }
        func make(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: render.x, height: render.y, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let rt: MTLTextureUsage = [.renderTarget, .shaderRead]
        let t = Targets(
            renderSize: render, outputSize: output,
            hdr: make(Self.colorFormat, rt), motion: make(Self.motionFormat, rt),
            depth: make(Self.depthFormat, rt), ldr: make(Upscaler.colorFormat, rt),
            upscaler: Upscaler(requested: render == output && settings.upscaler == .spatial ? .off : settings.upscaler,
                               device: device, input: render, output: output,
                               depthFormat: Self.depthFormat, motionFormat: Self.motionFormat)
        )
        targets = t
        previousCamera = nil
        return t
    }

    private func resolvedMode(_ requested: UpscalerMode) -> UpscalerMode {
        Upscaler.supports(requested, device: device) ? requested : .off
    }
}

public enum RendererError: Error, CustomStringConvertible {
    case resource(String)
    public var description: String {
        switch self {
        case .resource(let what): "Could not create renderer resource: \(what)"
        }
    }
}

/// Frame statistics shared between the render thread, GPU completion handlers and the UI.
final class StatsBox: Sendable {
    private let state = Mutex(FrameStats())
    /// Per-frame GPU span bookkeeping: frame -> (earliest start, latest end, stages pending).
    private let spans = Mutex([Int: (start: Double, end: Double, pending: Int)]())
    var value: FrameStats { state.withLock { $0 } }
    func update(_ body: (inout FrameStats) -> Void) { state.withLock { body(&$0) } }

    func beginStage(frame: Int) {
        spans.withLock { $0[frame, default: (.greatestFiniteMagnitude, 0, 0)].pending += 1 }
    }

    func endStage(frame: Int, start: Double, end: Double) {
        let finished: Double? = spans.withLock { table in
            guard var e = table[frame] else { return nil }
            if start > 0 { e.start = min(e.start, start) }
            e.end = max(e.end, end)
            e.pending -= 1
            if e.pending > 0 { table[frame] = e; return nil }
            table[frame] = nil
            // Drop stale entries if a frame never completed (device sleep, errors).
            if table.count > 16 { table.removeAll() }
            return e.end > e.start ? (e.end - e.start) * 1000 : nil
        }
        if let ms = finished {
            update { s in s.gpuFrameMilliseconds = s.gpuFrameMilliseconds == 0 ? ms : s.gpuFrameMilliseconds * 0.9 + ms * 0.1 }
        }
    }
}

extension Duration {
    var milliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}
