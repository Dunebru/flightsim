public import SwiftUI
import Foundation

/// In-flight screen.
///
/// Prototype: controls work by touch but drive demo state only; the numbers are fixed demo data
/// and the world behind is a flat stand-in until the M1 renderer lands. Each thumb owns its edge:
/// thrust on the left; gear, brake, spoilers and flaps on the right. The center stays open.
public struct FlightHUDView: View {
    @State private var model = HUDModel()
    private let onExit: () -> Void

    public init(onExit: @escaping () -> Void = {}) {
        self.onExit = onExit
    }

    public var body: some View {
        ZStack {
            WorldPlaceholder()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topRow
                Spacer(minLength: HUDStyle.gap)
                HStack(alignment: .bottom, spacing: HUDStyle.gap) {
                    leftEdge
                    Spacer(minLength: HUDStyle.gap)
                    VStack(spacing: 8) {
                        demoTag
                        MetricsBar(model: model)
                    }
                    Spacer(minLength: HUDStyle.gap)
                    rightEdge
                }
            }
            .padding(.horizontal, HUDStyle.edge)
            .padding(.vertical, 10)
            .overlay(alignment: .topTrailing) { panel }

            if model.paused { pausedOverlay }
        }
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.apMaster)
        .onAppear {
            // `-FlightOpenPanel autopilot` opens a panel at launch, so scripts can screenshot it.
            if let key = UserDefaults.standard.string(forKey: "FlightOpenPanel") {
                model.openPanel = HUDModel.Panel(rawValue: key)
            }
        }
    }

    // MARK: Regions

    private var topRow: some View {
        HStack(alignment: .top) {
            GlassCircleToggle(isOn: false, size: 48, accessibilityLabel: "Pause") {
                withAnimation(.spring(duration: 0.3)) { model.paused = true }
            } label: {
                Image(systemName: "pause.fill").font(.system(size: 17, weight: .semibold))
            }
            Spacer(minLength: HUDStyle.gap)
            if model.apMaster {
                AutopilotStatus(model: model)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: HUDStyle.gap)
            ToolCluster(model: model)
        }
    }

    private var leftEdge: some View {
        VStack(spacing: HUDStyle.gap) {
            GlassSlider(
                value: $model.throttle,
                fill: model.reverse ? HUDStyle.caution : HUDStyle.sliderFill,
                icon: .symbol("flame.fill"),
                topText: "\(Int((model.throttle * 100).rounded()))%",
                width: 68,
                accessibilityLabel: model.reverse ? "Reverse thrust" : "Thrust"
            )
            .frame(maxHeight: 250)
            GlassCircleToggle(
                isOn: model.reverse, onColor: HUDStyle.caution, size: 48,
                accessibilityLabel: "Reverse thrust"
            ) {
                withAnimation(.spring(duration: 0.3)) { model.toggleReverse() }
            } label: {
                Text("REV").font(.system(size: 12, weight: .heavy, design: .rounded))
            }
        }
    }

    /// Width of the right-thumb column: spoiler slider, gap, flap slider.
    static let rightEdgeWidth: CGFloat = 52 + HUDStyle.gap + 68

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
                GlassSlider(
                    value: detentBinding(\.spoilerIndex, count: model.spoilerDetents.count),
                    steps: model.spoilerDetents.count,
                    fill: model.spoilerIndex >= 2 ? HUDStyle.caution : HUDStyle.sliderFill,
                    icon: .glyph(.spoilers),
                    topText: model.spoilerDetents[model.spoilerIndex],
                    width: 52,
                    accessibilityLabel: "Spoilers"
                )
                GlassSlider(
                    value: detentBinding(\.flapIndex, count: model.flapDetents.count),
                    steps: model.flapDetents.count,
                    icon: .glyph(.flaps),
                    topText: model.flapDetents[model.flapIndex],
                    width: 68,
                    accessibilityLabel: "Flaps"
                )
            }
            .frame(maxHeight: 190)
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
                    GlassPanel(title: "Settings", onClose: close) { SettingsPanel(onEndFlight: onExit) }
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
            .padding(.top, 10 + 48 + HUDStyle.gap)
            // Hang under the tool cluster but stop short of the right-thumb controls.
            .padding(.trailing, HUDStyle.edge + Self.rightEdgeWidth + HUDStyle.gap)
            .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
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

    private var demoTag: some View {
        Text("Prototype · demo data · 3D world arrives in M1")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .overWorldLegibility()
    }

    /// Maps a detent index to a 0...1 slider value and back.
    private func detentBinding(_ keyPath: ReferenceWritableKeyPath<HUDModel, Int>, count: Int) -> Binding<Double> {
        Binding(
            get: { Double(model[keyPath: keyPath]) / Double(count - 1) },
            set: { model[keyPath: keyPath] = Int(($0 * Double(count - 1)).rounded()) }
        )
    }
}

/// Landing gear: green when down and locked, orange while travelling, glass when up.
struct GearButton: View {
    let model: HUDModel

    var body: some View {
        GlassCircleToggle(
            isOn: model.gear != .up,
            onColor: model.gear == .down ? HUDStyle.engaged : HUDStyle.caution,
            accessibilityLabel: "Landing gear"
        ) {
            model.toggleGear()
        } label: {
            GlyphView(glyph: .landingGear, size: 22)
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
