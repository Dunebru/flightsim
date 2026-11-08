#if os(iOS)
import Aircraft
import Foundation
import Metal
import Observation
import QuartzCore
import FlightModel
import Renderer
import SimCore
import SwiftUI
import UIKit

/// Owns the renderer and the scene, and drives frames from a CAMetalDisplayLink.
@Observable
final class WorldEngine: NSObject {
    @ObservationIgnored let renderer: SceneRenderer?
    @ObservationIgnored var scene: SceneDescription
    @ObservationIgnored private var link: CAMetalDisplayLink?
    @ObservationIgnored private var lastPresentation: CFTimeInterval = 0
    /// `-FlightTimeUTC 2026-06-21T19:30:00Z` pins the time of day (screenshots, testing).
    @ObservationIgnored private let timeOverride: Date?
    /// `-FlightLogStats YES` prints a frame-statistics line every two seconds to stdout, so
    /// `devicectl ... --console` can collect device frame times.
    @ObservationIgnored private let logStats = UserDefaults.standard.bool(forKey: "FlightLogStats")
    @ObservationIgnored private var framesSinceLog = 0

    /// Called every display frame before rendering with the frame time (s); a flight session
    /// uses it to move the aircraft.
    @ObservationIgnored var frameHook: ((Double, inout SceneDescription) -> Void)?
    /// Latest flight state, for the stats log.
    @ObservationIgnored var physicsProbe: (() -> FlightState?)?
    /// Chase camera relative to the aircraft: yaw offset from its heading, look-down angle,
    /// distance. Drag and pinch change these.
    @ObservationIgnored var orbitYawOffset: Double = -25 * .pi / 180
    @ObservationIgnored var orbitPitch: Double = 8 * .pi / 180
    @ObservationIgnored var orbitDistance: Double = 15

    private(set) var framesPerSecond: Double = 0
    private(set) var startupError: String?
    var showStats = true

    var upscaler: UpscalerMode = .temporal {
        didSet { applyRenderSettings() }
    }

    var temporalSupported: Bool {
        guard let device = renderer?.device else { return false }
        return MTLFXSupport.temporal(device)
    }

    override init() {
        let defaults = UserDefaults.standard
        timeOverride = defaults.string(forKey: "FlightTimeUTC").flatMap { ISO8601DateFormatter().date(from: $0) }
        scene = .phoenixTest(date: timeOverride ?? Date())
        var made: SceneRenderer?
        var error: String?
        if let device = MTLCreateSystemDefaultDevice() {
            do { made = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil) }
            catch let e { error = String(describing: e) }
        } else {
            error = "This device has no Metal GPU."
        }
        renderer = made
        startupError = error
        super.init()
        if let device = made?.device, !MTLFXSupport.temporal(device) { upscaler = .off }
        // `-FlightUpscaler temporal|spatial|off` (measurements and comparisons).
        if let forced = defaults.string(forKey: "FlightUpscaler").flatMap(UpscalerMode.init(rawValue:)) {
            upscaler = forced
        }
        applyRenderSettings()
        loadAircraft()
    }

    private func applyRenderSettings() {
        guard let renderer else { return }
        renderer.settings.upscaler = upscaler
        // Without MetalFX the final pass upsamples bilinearly; render at full size instead.
        renderer.settings.renderScale = upscaler == .off ? 1.0 : 0.67
    }

    private func loadAircraft() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Aircraft/c172p") else { return }
        Task { [weak self] in
            guard let model = await Self.parseModel(directory.appendingPathComponent("c172-common.ac")) else {
                self?.startupError = "Test aircraft not found in the app bundle (run scripts/fetch-assets.sh)."
                return
            }
            do { try self?.renderer?.setAircraft(model, textures: directory) }
            catch { self?.startupError = String(describing: error) }
        }
    }

    @concurrent
    private nonisolated static func parseModel(_ url: URL) async -> AC3DModel? {
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return nil }
        return try? AC3DParser.parse(text)
    }

    // MARK: Display link

    func attach(to layer: CAMetalLayer) {
        guard let renderer, link == nil else { return }
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.preferredFrameLatency = 2
        link.delegate = self
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    fileprivate func draw(_ update: CAMetalDisplayLink.Update) {
        guard let renderer else { return }
        let t = update.targetPresentationTimestamp
        var dt = 1.0 / 60
        if lastPresentation > 0, t > lastPresentation {
            dt = min(t - lastPresentation, 0.1)
            let fps = 1 / (t - lastPresentation)
            framesPerSecond = framesPerSecond == 0 ? fps : framesPerSecond * 0.9 + fps * 0.1
        }
        lastPresentation = t
        scene.date = timeOverride ?? Date()
        frameHook?(dt, &scene)
        scene.camera = OrbitCamera(
            target: scene.aircraftPosition + SIMD3(0, 0, 1.2),
            yaw: scene.aircraftHeading + orbitYawOffset,
            pitch: orbitPitch,
            distance: orbitDistance
        )
        renderer.render(scene, to: update.drawable.texture, drawable: update.drawable)
        renderer.exposureAdaptation = 0.05
        if logStats {
            framesSinceLog += 1
            if framesSinceLog >= 120 {
                framesSinceLog = 0
                let st = renderer.stats
                let passes = ["Atmosphere", "Shadow", "Scene", "Post"]
                    .map { String(format: "%@=%.2f", $0, st.gpuMilliseconds[$0] ?? 0) }.joined(separator: " ")
                if let s = physicsProbe?() {
                    print(String(format: "FLIGHTSTATE ias=%.1f alt=%.0f agl=%.1f hdg=%.1f pitch=%.1f roll=%.1f vs=%.0f eng=%.0f ground=%d t=%.1f",
                                 s.indicatedAirspeedKnots, s.altitudeFeet, s.heightAboveGroundFeet, s.heading * 180 / .pi,
                                 s.pitch * 180 / .pi, s.roll * 180 / .pi, s.verticalSpeedFPM, s.engineIndication, s.onGround ? 1 : 0, s.time))
                }
                print(String(format: "FLIGHTSTATS fps=%.1f gpuFrame=%.2fms gpuStageSum=%.2fms cpu=%.2fms %@ render=%dx%d output=%dx%d upscaler=%@ thermal=%d",
                             framesPerSecond, st.gpuFrameMilliseconds, st.gpuTotalMilliseconds, st.cpuMilliseconds, passes,
                             st.renderSize.x, st.renderSize.y, st.outputSize.x, st.outputSize.y,
                             st.upscaler.rawValue, ProcessInfo.processInfo.thermalState.rawValue))
                fflush(stdout)
            }
        }
    }

    // MARK: Camera

    func orbit(byPoints delta: CGSize) {
        orbitYawOffset += Double(delta.width) * 0.008
        orbitPitch = min(max(orbitPitch + Double(delta.height) * 0.006, -0.15), 1.4)
    }

    func zoom(by factor: Double) {
        orbitDistance = min(max(orbitDistance / factor, 6), 400)
    }
}

extension WorldEngine: @preconcurrency CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        draw(update)
    }
}

/// MetalFX availability, without importing MetalFX into the UI module's public surface.
enum MTLFXSupport {
    static func temporal(_ device: any MTLDevice) -> Bool {
        SceneRenderer.supports(.temporal, device: device)
    }
}

/// The 3D world behind the HUD. Drag to orbit the camera, pinch to zoom.
struct WorldView: View {
    let engine: WorldEngine
    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        MetalLayerView(engine: engine)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        engine.orbit(byPoints: CGSize(width: value.translation.width - lastDrag.width,
                                                      height: value.translation.height - lastDrag.height))
                        lastDrag = value.translation
                    }
                    .onEnded { _ in lastDrag = .zero }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        engine.zoom(by: Double(value.magnification / lastMagnification))
                        lastMagnification = value.magnification
                    }
                    .onEnded { _ in lastMagnification = 1 }
            )
            .accessibilityLabel("Outside view. Drag to look around the aircraft, pinch to zoom.")
    }
}

private struct MetalLayerView: UIViewRepresentable {
    let engine: WorldEngine

    func makeUIView(context: Context) -> MetalHostView {
        let view = MetalHostView()
        view.engine = engine
        return view
    }

    func updateUIView(_ uiView: MetalHostView, context: Context) {}

    static func dismantleUIView(_ uiView: MetalHostView, coordinator: ()) {
        uiView.engine?.detach()
    }
}

final class MetalHostView: UIView {
    weak var engine: WorldEngine?

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateDrawableSize()
            engine?.attach(to: metalLayer)
        } else {
            engine?.detach()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
}

/// Frame-time overlay: frame rate, GPU time per stage, CPU encode time, resolutions, upscaler.
struct FrameStatsOverlay: View {
    let engine: WorldEngine

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let s = engine.renderer?.stats ?? FrameStats()
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.0f fps   GPU %.1f ms/frame   CPU %.1f ms", engine.framesPerSecond, s.gpuFrameMilliseconds, s.cpuMilliseconds))
                Text(["Atmosphere", "Shadow", "Scene", "Post"]
                    .map { String(format: "%@ %.1f", String($0.prefix(5)), s.gpuMilliseconds[$0] ?? 0) }
                    .joined(separator: "  "))
                Text("\(s.renderSize.x)×\(s.renderSize.y) → \(s.outputSize.x)×\(s.outputSize.y)  MetalFX \(s.upscaler.rawValue)")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(HUDStyle.glass, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}
#endif
