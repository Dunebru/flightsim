import FlightModel
import Renderer
public import SwiftUI
import Foundation

/// In-flight screen.
///
/// Prototype: controls work by touch but drive demo state only; the numbers are fixed demo data
/// and the world behind is a flat stand-in until the M1 renderer lands.
///
/// Arrangement follows the mobile-sim convention the owner flies with: flight data across the
/// top center, the button bar along the bottom center with panels rising from it, thrust on the
/// left edge, and gear, brake, spoilers and flaps on the right edge. The center data and the
/// button bar sit on the screen's true center axis, independent of the side columns.
public struct FlightHUDView: View {
    @State private var model = HUDModel()
    #if os(iOS)
    @State private var engine: WorldEngine
    @State private var session: FlightSession?
    #endif
    @Bindable private var settings: AppSettings
    private let onExit: () -> Void

    public init(settings: AppSettings = AppSettings(), onExit: @escaping () -> Void = {}) {
        self.settings = settings
        self.onExit = onExit
        #if os(iOS)
        var stand: String?
        if case .stand(let ref) = settings.spot { stand = ref }
        _engine = State(initialValue: WorldEngine(airport: settings.airport, startStand: stand))
        #endif
    }

    /// Width of the right-thumb column: spoiler slider, gap, flap slider.
    static let rightEdgeWidth: CGFloat = 52 + HUDStyle.gap + 68
    /// Symmetric inset that keeps the bottom center clear of both thumb columns.
    static let bottomCenterInset: CGFloat = HUDStyle.edge + rightEdgeWidth + HUDStyle.gap
    /// Symmetric inset for the top center: clear of the pause button.
    static let topCenterInset: CGFloat = HUDStyle.edge + 48 + HUDStyle.gap

    public var body: some View {
        ZStack {
            #if os(iOS)
            WorldView(engine: engine)
                .ignoresSafeArea()
            #else
            WorldPlaceholder()
                .ignoresSafeArea()
            #endif

            // Thumb columns.
            HStack(alignment: .bottom, spacing: 0) {
                leftEdge
                Spacer(minLength: 0)
                rightEdge
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, HUDStyle.edge)
            .padding(.bottom, 10)

            // Pause, top-left; startup problems are reported under it.
            VStack(alignment: .leading, spacing: 8) {
                pauseButton
                #if os(iOS)
                if let error = engine.startupError {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(HUDStyle.warning.opacity(0.85), in: .rect(cornerRadius: 12))
                        .frame(maxWidth: 260, alignment: .leading)
                }
                #endif
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, HUDStyle.edge)
                .padding(.top, 10)

            // Top center: flight data, then autopilot status while engaged. Drawn as an overlay
            // on an empty layer so its width can never push the thumb columns.
            Color.clear
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        MetricsBar(model: model)
                        if model.stallWarning { StallWarning() }
                        // The status is redundant while the autopilot panel itself is open.
                        if model.apMaster && model.openPanel != .autopilot {
                            AutopilotStatus(model: model)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if model.openPanel == nil {
                            demoTag
                            #if os(iOS)
                            if engine.showStats { FrameStatsOverlay(engine: engine) }
                            #endif
                        }
                    }
                    .padding(.horizontal, Self.topCenterInset)
                    .padding(.top, 10)
                }

            // Bottom center: panels rise from the button bar. Overlay for the same reason.
            Color.clear
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        panel
                        ToolCluster(model: model)
                    }
                    .padding(.horizontal, Self.bottomCenterInset)
                    .padding(.bottom, 10)
                }

            // On-screen stick (stick mode): right thumb, above the button bar, inside the
            // right-hand levers.
            if settings.controlMode == .stick {
                VirtualStick { pitch, roll in
                    model.stickPitch = pitch
                    model.stickRoll = roll
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, HUDStyle.edge + Self.rightEdgeWidth + HUDStyle.gap)
                .padding(.bottom, 10 + 48 + HUDStyle.gap)
            }

            if model.paused { pausedOverlay }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.apMaster)
        #if os(iOS)
        .onChange(of: settings.upscaler, initial: true) { _, mode in
            engine.upscaler = UpscalerMode(rawValue: mode) ?? .temporal
        }
        .onChange(of: settings.showStats, initial: true) { _, show in engine.showStats = show }
        .onChange(of: model.camera, initial: true) { _, camera in
            engine.rig.mode = switch camera {
            case .cockpit: .cockpit
            case .chase: .chase
            case .tower: .tower
            case .wing: .wing
            case .orbit: .orbit
            }
        }
        #endif
        // Until the airport and the ground around it are ready, a loading screen instead of a
        // half-built world.
        .overlay {
            if isLoadingScenery {
                LoadingScreen(airport: settings.airport, place: settings.spot.label)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.45), value: isLoadingScenery)
        #if os(iOS)
        .onChange(of: engine.site?.layout.icao) { _, icao in
            if icao != nil && session == nil { startSession() }
        }
        #endif
        .onAppear {
            #if os(iOS)
            if engine.site != nil { startSession() }
            #endif
            // `-FlightOpenPanel autopilot` opens a panel at launch, so scripts can screenshot it.
            if let key = UserDefaults.standard.string(forKey: "FlightOpenPanel") {
                model.openPanel = HUDModel.Panel(rawValue: key)
            }
            // `-FlightScenario caution` shows the caution states (brake set, reverse armed).
            if UserDefaults.standard.string(forKey: "FlightScenario") == "caution" {
                model.parkingBrake = true
                model.toggleReverse()
                model.setThrottle(0.4)
            }
        }
    }

    #if os(iOS)
    private func startSession() {
        model.profile = AircraftProfile.all.first { $0.id == settings.aircraftID } ?? .c172
        guard let site = engine.site else { return }
        engine.showAircraft(model.profile.id)
        let s = FlightSession(profile: model.profile, site: site, spot: settings.spot, settings: settings,
                              scenery: engine.scenery, overrides: engine.overrides)
        s.configureHUD(model)
        session = s
        let hud = model
        let settings = self.settings
        engine.dateProvider = { settings.flightDate() }
        engine.frameHook = { [weak engine] dt, scene in
            s.tick(dt: dt, hud: hud, scene: &scene, holdForScenery: engine?.loadingScenery ?? false)
        }
        engine.physicsProbe = { s.physics?.state }
    }

    private func switchAircraft(to profile: AircraftProfile) {
        guard profile != model.profile else { return }
        settings.aircraftID = profile.id
        engine.frameHook = nil
        session = nil
        startSession()
    }
    #endif

    // MARK: Regions

    private var pauseButton: some View {
        GlassCircleToggle(isOn: false, size: 48, accessibilityLabel: "Pause") {
            withAnimation(.spring(duration: 0.3)) { model.paused = true }
        } label: {
            Image(systemName: "pause.fill").font(.system(size: 17, weight: .semibold))
        }
    }

    private var leftEdge: some View {
        VStack(spacing: HUDStyle.gap) {
            GlassSlider(
                value: $model.throttle,
                fill: model.reverse ? HUDStyle.caution : HUDStyle.sliderFill,
                icon: .symbol("flame.fill"),
                readout: "\(Int((model.throttle * 100).rounded()))%",
                width: 68,
                accessibilityLabel: model.reverse ? "Reverse thrust" : "Thrust"
            )
            .frame(maxHeight: 250)
            HStack(spacing: 8) {
                GlassCircleToggle(
                    isOn: model.reverse, onColor: HUDStyle.caution, size: 48,
                    accessibilityLabel: "Reverse thrust"
                ) {
                    withAnimation(.spring(duration: 0.3)) { model.toggleReverse() }
                } label: {
                    Text("REV").font(.system(size: 12, weight: .heavy, design: .rounded))
                }
                HoldToBrake(isHeld: $model.wheelBrakes)
            }
        }
    }

    private var rightEdge: some View {
        VStack(alignment: .trailing, spacing: HUDStyle.gap) {
            HStack(spacing: HUDStyle.gap) {
                GlassCircleToggle(
                    isOn: model.parkingBrake, onColor: HUDStyle.caution,
                    accessibilityLabel: "Parking brake"
                ) {
                    model.parkingBrake.toggle()
                } label: {
                    Image(systemName: "parkingsign").font(.system(size: 19, weight: .bold))
                }
                GearButton(model: model)
            }
            HStack(alignment: .bottom, spacing: HUDStyle.gap) {
                if model.profile.hasSpoilers {
                GlassSlider(
                    value: detentBinding(\.spoilerIndex, count: model.spoilerDetents.count),
                    detents: model.spoilerDetents,
                    fillsFromTop: true,
                    fill: model.spoilerIndex >= 2 ? HUDStyle.caution : HUDStyle.sliderFill,
                    icon: .glyph(.spoilers),
                    width: 52,
                    accessibilityLabel: "Spoilers"
                )
                }
                GlassSlider(
                    value: detentBinding(\.flapIndex, count: model.flapDetents.count),
                    detents: model.flapDetents,
                    fillsFromTop: true,
                    icon: .glyph(.flaps),
                    width: 68,
                    accessibilityLabel: "Flaps"
                )
            }
            .frame(maxHeight: 200)
        }
    }

    @ViewBuilder
    private var panel: some View {
        if let open = model.openPanel {
            let close = { withAnimation(.spring(duration: 0.35, bounce: 0.15)) { model.openPanel = nil } }
            Group {
                switch open {
                case .autopilot:
                    GlassPanel(
                        title: "Autopilot",
                        trailing: AnyView(
                            Toggle("Autopilot", isOn: $model.apMaster)
                                .labelsHidden()
                                .tint(HUDStyle.engaged)
                        ),
                        onClose: close
                    ) { AutopilotPanel(model: model) }
                case .lights:
                    GlassPanel(title: "Lights", onClose: close) { LightsPanel(model: model) }
                case .settings:
                    GlassPanel(title: "Settings", onClose: close) {
                        #if os(iOS)
                        SettingsPanel(
                            engine: engine, profile: model.profile, settings: settings,
                            onSelectAircraft: { switchAircraft(to: $0) },
                            onReset: { session?.resetToStart(hud: model) },
                            onCalibrateTilt: { session?.tilt.calibrate() },
                            onEndFlight: onExit
                        )
                        #else
                        SettingsPanel(onEndFlight: onExit)
                        #endif
                    }
                case .map:
                    GlassPanel(title: "Map", onClose: close) {
                        NotYetPanel(title: "No map yet", symbol: "map", detail: "The moving map with your route, traffic and airspace arrives in M8.")
                    }
                case .atc:
                    GlassPanel(title: "ATC", onClose: close) {
                        NotYetPanel(title: "No ATC yet", symbol: "antenna.radiowaves.left.and.right", detail: "Ground, tower, departure and approach arrive in M9.")
                    }
                }
            }
            .fixedSize()
            .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
        }
    }

    private var pausedOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Paused")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Button {
                    withAnimation(.spring(duration: 0.3)) { model.paused = false }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
        }
        .transition(.opacity)
    }

    private var isLoadingScenery: Bool {
        #if os(iOS)
        engine.loadingScenery
        #else
        false
        #endif
    }

    private var demoTag: some View {
        Text("Prototype · JSBSim \(model.profile.name) · tilt to fly")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .glassEffect(HUDStyle.glass, in: .capsule)
    }

    /// Maps a detent index to a 0...1 slider value and back.
    private func detentBinding(_ keyPath: ReferenceWritableKeyPath<HUDModel, Int>, count: Int) -> Binding<Double> {
        Binding(
            get: { Double(model[keyPath: keyPath]) / Double(count - 1) },
            set: { model[keyPath: keyPath] = Int(($0 * Double(count - 1)).rounded()) }
        )
    }
}

/// Landing gear: green when down and locked, orange and pulsing while travelling, glass when up.
struct GearButton: View {
    let model: HUDModel

    var body: some View {
        GlassCircleToggle(
            isOn: model.gear != .up,
            onColor: model.gear == .down ? HUDStyle.engaged : HUDStyle.caution,
            accessibilityLabel: model.profile.retractableGear ? "Landing gear" : "Landing gear, fixed"
        ) {
            model.toggleGear()
        } label: {
            if case .transit = model.gear {
                GlyphView(glyph: .landingGear, size: 24)
                    .phaseAnimator([1.0, 0.35]) { glyph, opacity in
                        glyph.opacity(opacity)
                    } animation: { _ in .easeInOut(duration: 0.45) }
            } else {
                GlyphView(glyph: .landingGear, size: 24)
            }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.gear)
        .accessibilityValue(stateText)
    }

    private var stateText: String {
        switch model.gear {
        case .down: "Down and locked"
        case .transit: "In transit"
        case .up: "Up"
        }
    }
}

/// Flat stand-in for the 3D world: a sky gradient over a dark ground plane with a horizon line.
/// Exists only so the HUD can be judged against something sky-like. Replaced by the renderer in M1.
struct WorldPlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            let horizon = geo.size.height * 0.58
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.30, blue: 0.55),
                        Color(red: 0.42, green: 0.62, blue: 0.82),
                        Color(red: 0.78, green: 0.86, blue: 0.92),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: horizon)
                LinearGradient(
                    colors: [Color(red: 0.36, green: 0.39, blue: 0.33), Color(red: 0.18, green: 0.20, blue: 0.16)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: geo.size.height - horizon)
                .offset(y: horizon)
            }
        }
        .accessibilityHidden(true)
    }
}

#if os(iOS)
#Preview(traits: .landscapeLeft) {
    FlightHUDView()
}
#endif
