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
        let texture: any MTLTexture
        let centre: SIMD3<Double>
        let radius: Double
        let bytes: Int
    }

    /// CPU-side result of a background load.
    struct Loaded: Sendable {
        let geometry: TerrainTileGeometry
        let pixels: [UInt8]      // RGBA8, sRGB
        let width: Int
        let height: Int
    }

    final class Inbox: Sendable {
        let mutex = Mutex<[TileKey: Loaded]>([:])
        let failed = Mutex<Set<TileKey>>([])
    }

    let pack: SceneryLibrary
    let frame: LocalFrame
    let flatten: [FlattenArea]
    private let device: any MTLDevice
    private var tiles: [TileKey: GPUTile] = [:]
    private var lastUsed: [TileKey: Int] = [:]
    private var requested: Set<TileKey> = []
    /// Tiles whose files failed to load.
    private(set) var broken: Set<TileKey> = []
    private let inbox = Inbox()
    private let roots: [TileKey]
    /// One index buffer for every tile (they share a topology).
    let indices: any MTLBuffer
    let indexCount: Int
    /// Refinement outside the view is this many times coarser.
    var hiddenDetailScale = 3.0
    private(set) var residentBytes = 0
    private var frameIndex = 0
    private var pendingMipmaps: [any MTLTexture] = []

    /// GPU memory budget for terrain, bytes.
    var budgetBytes = 256 * 1024 * 1024
    /// Uploads per frame (each is a mesh plus a 256 x 256 texture).
    var uploadsPerFrame = 6
    /// Refinement threshold: tile radius / distance.
    var detail = 0.55

    init(pack: SceneryLibrary, frame: LocalFrame, flatten: [FlattenArea], device: any MTLDevice) {
        self.pack = pack
        self.frame = frame
        self.flatten = flatten
        self.device = device
        roots = pack.available.filter { k in k.parent.map { !pack.available.contains($0) } ?? true }.sorted()
        let list = TerrainTileGeometry.indices(samples: pack.heightSamples)
        indices = device.makeBuffer(bytes: list, length: list.count * 2, options: .storageModeShared)!
        indexCount = list.count
        roots.forEach(request)
    }

    var loadedCount: Int { tiles.count }
    var pendingCount: Int { requested.count }
    /// Detail back-off under memory pressure: 1 normally, larger (coarser) while the view would
    /// not fit the budget. Rises quickly when over, relaxes slowly when well under.
    private(set) var pressure = 1.0
    private(set) var lastSelected = 0
    var overBudget: Bool { residentBytes > budgetBytes }

    // MARK: Per frame

    /// Uploads finished loads, chooses the tiles to draw for this camera, requests the next level,
    /// and evicts what is over budget. Returns the tiles to draw.
    func update(camera: SIMD3<Double>, frustum: [SIMD4<Float>], commandBuffer: any MTLCommandBuffer) -> [GPUTile] {
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
            wantsChildren: { k in
                // Children a drawn tile is waiting on count as in use, so eviction cannot drop
                // the ones already loaded while their siblings arrive.
                for c in k.children {
                    self.lastUsed[c] = self.frameIndex
                    self.request(c)
                }
            },
            detail: detail * pressure,
            isVisible: { c, r in MatrixMath.sphereVisible(centre: SIMD3<Float>(c - camera), radius: Float(r), planes: frustum) },
            hiddenDetailScale: hiddenDetailScale
        )
        // Drawn tiles and every ancestor: the traversal passes through the ancestors, so
        // evicting one would collapse its whole subtree and reload it (a churn loop).
        for k in selected {
            var p: TileKey? = k
            while let q = p, tiles[q] != nil, lastUsed[q] != frameIndex {
                lastUsed[q] = frameIndex
                p = q.parent
            }
        }
        lastSelected = selected.count
        evict()
        if residentBytes > budgetBytes {
            pressure = min(pressure * 1.15, 16)
        } else if residentBytes < budgetBytes * 3 / 4 {
            pressure = max(1, pressure / 1.02)
        }
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
        guard tiles[k] == nil, !requested.contains(k), !broken.contains(k), pack.available.contains(k) else { return }
        requested.insert(k)
        let pack = self.pack, frame = self.frame, flatten = self.flatten, inbox = self.inbox
        Task.detached(priority: .userInitiated) {
            do {
                let heights = try pack.heights(k)
                let geometry = TerrainTileGeometry.build(key: k, heights: heights, samples: pack.heightSamples,
                                                         frame: frame, flatten: flatten)
                guard let url = pack.imageryURL(k) else { throw CocoaError(.fileNoSuchFile) }
                let image = try Data(contentsOf: url)
                guard let (pixels, w, h) = Self.decode(image) else { throw CocoaError(.fileReadCorruptFile) }
                inbox.mutex.withLock { $0[k] = Loaded(geometry: geometry, pixels: pixels, width: w, height: h) }
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
        }
        let failed = inbox.failed.withLock { f -> Set<TileKey> in let c = f; f.removeAll(); return c }
        for k in failed {
            // A tile that cannot be read will not become readable; stop asking for it.
            requested.remove(k)
            broken.insert(k)
        }
    }

    private func makeGPUTile(_ k: TileKey, _ l: Loaded) -> GPUTile? {
        let g = l.geometry
        var verts = [TerrainVertex]()
        verts.reserveCapacity(g.positions.count)
        func snorm(_ v: Float) -> Int8 { Int8(max(-127, min(127, (v * 127).rounded()))) }
        func unorm(_ v: Float) -> UInt16 { UInt16(max(0, min(65535, (v * 65535).rounded()))) }
        for i in 0..<g.positions.count {
            let p = g.positions[i], n = g.normals[i], t = g.uvs[i]
            verts.append(TerrainVertex(x: p.x, y: p.y, z: p.z, nx: snorm(n.x), ny: snorm(n.y), nz: snorm(n.z), nw: 0,
                                       u: unorm(t.x), v: unorm(t.y)))
        }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<TerrainVertex>.stride,
                                         options: .storageModeShared) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: l.width, height: l.height, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, l.width, l.height), mipmapLevel: 0, withBytes: l.pixels, bytesPerRow: l.width * 4)
        pendingMipmaps.append(tex)
        let bytes = vb.length + l.width * l.height * 4 * 4 / 3
        return GPUTile(key: k, vertices: vb, texture: tex, centre: g.centre, radius: g.radius, bytes: bytes)
    }

    // MARK: Budget

    /// Drops least recently used tiles until under budget. Tiles in use this frame (drawn, or
    /// children being waited on) and the roots are never dropped, so the budget can be exceeded
    /// when the view itself needs more; `overBudget` reports that.
    private func evict() {
        guard residentBytes > budgetBytes else { return }
        let rootSet = Set(roots)
        let candidates = tiles.keys.filter { (lastUsed[$0] ?? 0) < frameIndex && !rootSet.contains($0) }
            .sorted { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
        for k in candidates {
            guard residentBytes > budgetBytes, let t = tiles.removeValue(forKey: k) else { break }
            residentBytes -= t.bytes
            lastUsed[k] = nil
        }
    }
}
