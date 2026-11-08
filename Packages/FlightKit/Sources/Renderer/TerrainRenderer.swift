import CoreGraphics
import Foundation
import ImageIO
import Metal
import SimCore
import Synchronization
public import Terrain
import simd

/// Streams terrain tiles from a scenery pack: background loading (heights to mesh, JPEG to
/// pixels), a bounded number of GPU uploads per frame, quadtree selection, and LRU eviction under
/// a memory budget.
final class TerrainRenderer {
    struct GPUTile {
        let key: TileKey
        let vertices: any MTLBuffer
        let indices: any MTLBuffer
        let indexCount: Int
        let texture: any MTLTexture
        let centre: SIMD3<Double>
        let radius: Double
        let bytes: Int
    }

    /// CPU-side result of a background load.
    struct Loaded: Sendable {
        let geometry: TerrainTileGeometry
        let heights: [Float]
        let pixels: [UInt8]      // RGBA8, sRGB
        let width: Int
        let height: Int
    }

    final class Inbox: Sendable {
        let mutex = Mutex<[TileKey: Loaded]>([:])
        let failed = Mutex<Set<TileKey>>([])
    }

    let pack: SceneryPack
    let frame: LocalFrame
    let flatten: [FlattenArea]
    private let device: any MTLDevice
    private var tiles: [TileKey: GPUTile] = [:]
    private var lastUsed: [TileKey: Int] = [:]
    private var requested: Set<TileKey> = []
    private let inbox = Inbox()
    private let roots: [TileKey]
    private(set) var heightField: HeightField
    private(set) var residentBytes = 0
    private var frameIndex = 0
    private var pendingMipmaps: [any MTLTexture] = []

    /// GPU memory budget for terrain, bytes.
    var budgetBytes = 256 * 1024 * 1024
    /// Uploads per frame (each is a mesh plus a 256 x 256 texture).
    var uploadsPerFrame = 6
    /// Refinement threshold: tile radius / distance.
    var detail = 0.55

    init(pack: SceneryPack, frame: LocalFrame, flatten: [FlattenArea], device: any MTLDevice) {
        self.pack = pack
        self.frame = frame
        self.flatten = flatten
        self.device = device
        roots = pack.available.filter { k in k.parent.map { !pack.available.contains($0) } ?? true }.sorted()
        heightField = HeightField(samples: pack.index.heightSamples, maxZoom: pack.index.maxZoom)
        roots.forEach(request)
    }

    var loadedCount: Int { tiles.count }
    var pendingCount: Int { requested.count }

    // MARK: Per frame

    /// Uploads finished loads, chooses the tiles to draw for this camera, requests the next level,
    /// and evicts what is over budget. Returns the tiles to draw.
    func update(camera: SIMD3<Double>, commandBuffer: any MTLCommandBuffer) -> [GPUTile] {
        frameIndex += 1
        upload()
        if !pendingMipmaps.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for t in pendingMipmaps { blit.generateMipmaps(for: t) }
            blit.endEncoding()
            pendingMipmaps.removeAll()
        }
        let selected = TileSelector.select(
            roots: roots, camera: camera, available: pack.available,
            tileCentre: { k in
                if let t = self.tiles[k] { return (t.centre, t.radius) }
                return self.estimate(k)
            },
            isLoaded: { self.tiles[$0] != nil },
            wantsChildren: { k in k.children.forEach(self.request) },
            detail: detail
        )
        for k in selected { lastUsed[k] = frameIndex }
        evict(keeping: Set(selected))
        return selected.compactMap { tiles[$0] }
    }

    /// Centre and radius of a tile that has not loaded yet, at the scene origin's height.
    private func estimate(_ k: TileKey) -> (centre: SIMD3<Double>, radius: Double) {
        let c = WebMercator.coordinate(x: Double(k.x) + 0.5, y: Double(k.y) + 0.5, zoom: k.z)
        let size = 40_075_016 * cos(c.latitude * .pi / 180) / Double(1 << k.z)
        return (frame.enu(Geodetic(latitude: c.latitude, longitude: c.longitude, height: frame.origin.height)), size * 0.71)
    }

    // MARK: Loading

    private func request(_ k: TileKey) {
        guard tiles[k] == nil, !requested.contains(k), pack.available.contains(k) else { return }
        requested.insert(k)
        let pack = self.pack, frame = self.frame, flatten = self.flatten, inbox = self.inbox
        Task.detached(priority: .userInitiated) {
            do {
                let heights = try pack.heights(k)
                let geometry = TerrainTileGeometry.build(key: k, heights: heights, samples: pack.index.heightSamples,
                                                         frame: frame, flatten: flatten)
                let image = try Data(contentsOf: pack.imageryURL(k))
                guard let (pixels, w, h) = Self.decode(image) else { throw CocoaError(.fileReadCorruptFile) }
                inbox.mutex.withLock { $0[k] = Loaded(geometry: geometry, heights: heights, pixels: pixels, width: w, height: h) }
            } catch {
                inbox.failed.withLock { _ = $0.insert(k) }
            }
        }
    }

    /// JPEG to RGBA8 pixels (sRGB), via ImageIO.
    nonisolated static func decode(_ data: Data) -> ([UInt8], Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }

    private func upload() {
        let ready: [TileKey: Loaded] = inbox.mutex.withLock { pending in
            var take: [TileKey: Loaded] = [:]
            for (k, v) in pending.prefix(uploadsPerFrame) { take[k] = v }
            for k in take.keys { pending[k] = nil }
            return take
        }
        for (k, loaded) in ready {
            requested.remove(k)
            guard let tile = makeGPUTile(k, loaded) else { continue }
            tiles[k] = tile
            residentBytes += tile.bytes
            lastUsed[k] = frameIndex
            heightField.insert(k, heights: loaded.heights)
        }
        let failed = inbox.failed.withLock { f -> Set<TileKey> in let c = f; f.removeAll(); return c }
        for k in failed { requested.remove(k) }
    }

    private func makeGPUTile(_ k: TileKey, _ l: Loaded) -> GPUTile? {
        let g = l.geometry
        var verts = [MeshVertex]()
        verts.reserveCapacity(g.positions.count)
        for i in 0..<g.positions.count {
            verts.append(MeshVertex(position: SIMD4(g.positions[i], 1), normal: SIMD4(g.normals[i], 0), uv: g.uvs[i]))
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<MeshVertex>.stride, options: .storageModeShared),
              let ib = device.makeBuffer(bytes: g.indices, length: g.indices.count * 2, options: .storageModeShared) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: l.width, height: l.height, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, l.width, l.height), mipmapLevel: 0, withBytes: l.pixels, bytesPerRow: l.width * 4)
        pendingMipmaps.append(tex)
        let bytes = vb.length + ib.length + l.width * l.height * 4 * 4 / 3
        return GPUTile(key: k, vertices: vb, indices: ib, indexCount: g.indices.count, texture: tex,
                       centre: g.centre, radius: g.radius, bytes: bytes)
    }

    // MARK: Budget

    private func evict(keeping inUse: Set<TileKey>) {
        guard residentBytes > budgetBytes else { return }
        let rootSet = Set(roots)
        let candidates = tiles.keys.filter { !inUse.contains($0) && !rootSet.contains($0) }
            .sorted { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
        for k in candidates {
            guard residentBytes > budgetBytes, let t = tiles.removeValue(forKey: k) else { break }
            residentBytes -= t.bytes
            lastUsed[k] = nil
        }
    }
}
