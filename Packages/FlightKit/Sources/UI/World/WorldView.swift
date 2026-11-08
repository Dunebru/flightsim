#if os(iOS)
import Aircraft
import Airports
import Foundation
import Metal
import Observation
import QuartzCore
import FlightModel
import Renderer
import SimCore
import SwiftUI
import Terrain
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
    /// The flight's date (real time or a pinned time of day); the launch argument wins.
    @ObservationIgnored var dateProvider: (() -> Date)?
    /// Latest flight state, for the stats log.
    @ObservationIgnored var physicsProbe: (() -> FlightState?)?
    /// Cockpit, chase, tower, wing and free-orbit views; drag and pinch adjust the current one.
    @ObservationIgnored var rig = CameraRig()
    /// The bundled scenery (regional packs over a world base), if present.
    @ObservationIgnored let scenery: SceneryLibrary?
    /// The departure airport, whose frame is the scene frame. Set once the airports are built
    /// (off the main thread); the flight starts then.
    private(set) var site: AirportSite?
    /// Every airport's ground overrides in the scene frame.
    @ObservationIgnored private(set) var overrides: [GroundOverride] = []
    @ObservationIgnored private var airportsReady = false
    /// Ground under the camera, so no view goes underground.
    @ObservationIgnored private var cameraGround: GroundModel
    @ObservationIgnored private var pendingLayouts: [AirportLayout] = []
    @ObservationIgnored private var departureICAO: String?
    @ObservationIgnored private let startStand: String?

    private(set) var framesPerSecond: Double = 0
    /// True until the terrain around the camera has streamed in (or 10 s have passed), so a
    /// flight does not start over half-loaded ground.
    private(set) var loadingScenery = true
    @ObservationIgnored private var quietFrames = 0
    @ObservationIgnored private var firstFrame: CFTimeInterval = 0
    private(set) var startupError: String?
    var showStats = true

    var upscaler: UpscalerMode = .temporal {
        didSet { applyRenderSettings() }
    }

    var temporalSupported: Bool {
        guard let device = renderer?.device else { return false }
        return MTLFXSupport.temporal(device)
    }

    /// `startStand`: the gate the flight starts at, left free of parked traffic.
    init(airport icao: String = "KPHX", startStand: String? = nil) {
        self.startStand = startStand
        let defaults = UserDefaults.standard
        timeOverride = defaults.string(forKey: "FlightTimeUTC").flatMap { ISO8601DateFormatter().date(from: $0) }
        scene = .phoenixTest(date: timeOverride ?? Date())
        scene.showRunway = false        // airports are generated; the M1 stand-in runway is for tests
        scenery = Bundle.main.resourceURL.map { SceneryLibrary(directory: $0.appendingPathComponent("Bundle/Scenery")) }
            .flatMap { $0.packs.isEmpty ? nil : $0 }
        // Layouts are small; the scene origin (the departure airport's reference point) is known
        // at once. Surfaces, meshes and lights are built in the background.
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Airports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder ?? URL(fileURLWithPath: "/"), includingPropertiesForKeys: nil)) ?? []
        let layouts = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("-city") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? AirportLayout.load($0) }
        let current = layouts.first { $0.icao == icao } ?? layouts.first
        if let current {
            scene.origin = Geodetic(latitude: current.reference.lat, longitude: current.reference.lon, height: current.elevation)
        }
        cameraGround = GroundModel(scenery: scenery, frame: LocalFrame(origin: scene.origin), flatten: [])
        pendingLayouts = layouts
        departureICAO = current?.icao
        var made: SceneRenderer?
        var error: String?
        if let device = MTLCreateSystemDefaultDevice() {
            do { made = try SceneRenderer(device: device, aircraftModel: nil, aircraftTextures: nil) }
            catch let e { error = String(describing: e) }
        } else {
            error = "This device has no Metal GPU."
        }
        #if os(iOS)
        // Clouds march at 40% of the render resolution on the phone (half on the Mac); the
        // temporal resolve hides most of the difference. Not yet measured on the device.
        made?.cloudResolutionScale = 0.4
        #endif
        // The bright star catalogue for the night sky.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Sky/stars.bin"), let list = try? SkyStar.load(url) {
            made?.setStars(list)
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
        loadAirports()
    }

    /// Writes Library/Caches/flight-ready.txt when a flight starts, so scripts (verify.sh) know
    /// the world is ready before they take a screenshot.
    static func markReady(airport: String) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? "ready \(airport) \(ISO8601DateFormatter().string(from: Date()))\n"
            .write(to: caches.appendingPathComponent("flight-ready.txt"), atomically: true, encoding: .utf8)
    }

    struct BuiltAirports: Sendable {
        var assets: [AirportAssets]
        var overrides: [GroundOverride]
    }

    /// Builds airport surfaces, meshes and lights off the main thread, then starts the terrain
    /// (which needs the airports' ground overrides) and hands the airports to the renderer.
    private func loadAirports() {
        let layouts = pendingLayouts, origin = scene.origin, icao = departureICAO
        let started = Date()
        Task { [weak self] in
            let built = await Self.buildAirports(layouts, sceneOrigin: origin, scenery: self?.scenery, cityFor: icao)
            print(String(format: "AIRPORTS ready in %.1f s", Date().timeIntervalSince(started)))
            guard let self else { return }
            self.overrides = built.overrides
            self.cameraGround = GroundModel(scenery: self.scenery, frame: LocalFrame(origin: origin), flatten: built.overrides)
            self.renderer?.setTerrain(self.scenery, origin: origin, flatten: built.overrides)
            self.renderer?.setAirports(built.assets, sceneOrigin: origin, excludeStand: self.startStand)
            let departure = built.assets.first { $0.site.layout.icao == icao }?.site
            if let cab = departure?.towerCab { self.rig.towerPosition = cab }
            self.quietFrames = 0
            self.airportsReady = true
            self.site = departure
        }
    }

    @concurrent
    /// Surroundings (city buildings) only for `cityFor`, the departure airport: the other is
    /// hundreds of kilometres away, and its 80,000 buildings would only slow the start.
    private nonisolated static func buildAirports(_ layouts: [AirportLayout], sceneOrigin: Geodetic,
                                                  scenery: SceneryLibrary?, cityFor: String?) async -> BuiltAirports {
        let frame = LocalFrame(origin: sceneOrigin)
        let sites = layouts.map { AirportSite(layout: $0) }
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Airports")
        let assets = sites.map { site -> AirportAssets in
            var city: [CityChunk] = []
            if site.layout.icao == cityFor, let url = folder?.appendingPathComponent("\(site.layout.icao)-city.json"),
               let surroundings = try? SurroundingBuildings.load(url) {
                var ground = GroundModel(scenery: scenery, frame: site.frame, flatten: site.overrides)
                city = CityGeometry.build(surroundings, site: site) { p in ground.groundZ(atENU: SIMD3(p.x, p.y, 0)) }
            }
            return AirportAssets(site: site, geometry: AirportGeometry.build(site), lights: AirportLights.build(site), city: city)
        }
        return BuiltAirports(assets: assets, overrides: sites.flatMap { $0.overrides(in: frame) })
    }

    private func applyRenderSettings() {
        guard let renderer else { return }
        renderer.settings.upscaler = upscaler
        // Without MetalFX the final pass upsamples bilinearly; render at full size instead.
        renderer.settings.renderScale = upscaler == .off ? 1.0 : 0.67
    }

    /// Which aircraft to draw: "c172p" or "A320" (both FlightGear models).
    @ObservationIgnored private var aircraftID = "c172p"
    @ObservationIgnored private var c172: AC3DModel?
    @ObservationIgnored private var c172Cockpit: AnimatedModel?
    @ObservationIgnored private var a320: AnimatedModel?

    private func loadAircraft() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Aircraft/c172p") else { return }
        Task { [weak self] in
            guard let (model, cockpit) = await Self.parseC172(directory) else {
                self?.startupError = "Test aircraft not found in the app bundle (run scripts/fetch-assets.sh)."
                return
            }
            self?.c172 = model
            self?.c172Cockpit = cockpit
            if self?.aircraftID == "c172p" { self?.applyAircraft() }
        }
        guard let a320Directory = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Aircraft/A320") else { return }
        Task { [weak self] in
            guard let model = await Self.parseA320(a320Directory) else { return }
            self?.a320 = model
            if self?.aircraftID == "A320" { self?.applyAircraft() }
        }
    }

    @concurrent
    private nonisolated static func parseA320(_ directory: URL) async -> AnimatedModel? {
        try? A320Model.loadAnimated(from: directory)
    }

    /// Draws the aircraft for a profile (the C172 once its model has loaded).
    func showAircraft(_ id: String) {
        aircraftID = id
        rig.configure(forAircraft: id)
        applyAircraft()
    }

    /// The drawn nose wheel and where the flight model has it, for placing the model.
    static func noseWheel(_ m: AnimatedModel, _ object: String, _ profile: AircraftProfile) -> (model: SIMD3<Float>, aheadOfCG: Float)? {
        m.centre(ofObject: object).map { ($0, Float(profile.noseWheelAheadOfCG)) }
    }

    private func applyAircraft() {
        do {
            if aircraftID == "A320" {
                if let a320, let directory = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Aircraft/A320") {
                    // No flight deck yet: the cockpit windows are tinted, not clear, so the empty
                    // nose does not show through them.
                    try renderer?.setAircraft(a320.model, textures: directory, textureMap: A320Model.liveries[0].textures,
                                              hiddenParts: ["hidden"], animation: a320, cullsBackFaces: true, opaqueGlass: true,
                                              noseWheel: Self.noseWheel(a320, "NLGWheels", AircraftProfile.a320))
                } else {
                    try renderer?.setGenericAirliner()    // until the model has loaded
                }
            } else if let c172, let directory = Bundle.main.resourceURL?.appendingPathComponent("Bundle/Aircraft/c172p") {
                try renderer?.setAircraft(c172, textures: directory, hiddenParts: ["hidden"], animation: c172Cockpit, cullsBackFaces: true,
                                          noseWheel: c172Cockpit.flatMap { Self.noseWheel($0, "NoseWheel", AircraftProfile.c172) })
            }
        } catch {
            startupError = String(describing: error)
        }
    }

    /// FlightGear's whole c172p: the airframe model file places the cockpit and animates the
    /// control surfaces. Without the cockpit files the bare exterior still flies.
    @concurrent
    private nonisolated static func parseC172(_ directory: URL) async -> (AC3DModel, AnimatedModel?)? {
        if let whole = try? C172Model.loadAircraft(directory: directory) { return (whole.model, whole) }
        guard let text = try? String(contentsOf: directory.appendingPathComponent("c172-common.ac"), encoding: .isoLatin1),
              let exterior = try? AC3DParser.parse(text, part: C172Model.part) else { return nil }
        return (exterior, nil)
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
        scene.date = timeOverride ?? dateProvider?() ?? Date()
        frameHook?(dt, &scene)
        var pose = rig.pose(aircraftPosition: scene.aircraftPosition, heading: scene.aircraftHeading,
                            pitch: scene.aircraftPitch, roll: scene.aircraftRoll, dt: dt, pivot: scene.aircraftPivotHeight)
        let floor = cameraGround.groundZ(atENU: pose.position) + 1.5
        if pose.position.z < floor { pose.position.z = floor }
        scene.cameraPose = pose
        scene.showAircraft = rig.drawsAircraft
        renderer.render(scene, to: update.drawable.texture, drawable: update.drawable)
        renderer.exposureAdaptation = 0.05
        // The flight starts once the airports are built and the terrain around the camera has
        // streamed in (or 15 s after the airports, whichever is first).
        if loadingScenery && airportsReady {
            if firstFrame == 0 { firstFrame = t }
            quietFrames = renderer.terrainPending == 0 ? quietFrames + 1 : 0
            if scenery == nil || quietFrames >= 3 || t - firstFrame > 15 {
                loadingScenery = false
                Self.markReady(airport: site?.layout.icao ?? "")
            }
        }
        if logStats {
            framesSinceLog += 1
            if framesSinceLog >= 120 {
                framesSinceLog = 0
                let st = renderer.stats
                let passes = ["Atmosphere", "Shadow", "Scene", "Clouds", "Precipitation", "Post"]
                    .map { String(format: "%@=%.2f", $0, st.gpuMilliseconds[$0] ?? 0) }.joined(separator: " ")
                if let s = physicsProbe?() {
                    print(String(format: "FLIGHTSTATE ias=%.1f alt=%.0f agl=%.1f hdg=%.1f pitch=%.1f roll=%.1f vs=%.0f eng=%.0f ground=%d t=%.1f",
                                 s.indicatedAirspeedKnots, s.altitudeFeet, s.heightAboveGroundFeet, s.heading * 180 / .pi,
                                 s.pitch * 180 / .pi, s.roll * 180 / .pi, s.verticalSpeedFPM, s.engineIndication, s.onGround ? 1 : 0, s.time))
                }
                print("TERRAINSTATS \(renderer.terrainDebug)")
                let moving = scene.traffic.values.reduce(0) { $0 + $1.narrow.count + $1.wide.count }
                print("TRAFFICSTATS moving=\(moving) airliners drawn=\(renderer.parkedDrawn)")
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
        rig.drag(Double(delta.width), Double(delta.height))
    }

    func zoom(by factor: Double) {
        rig.pinch(factor)
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
