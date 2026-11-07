public import SwiftUI
import Foundation

/// In-flight screen.
///
/// Prototype (pre-M3): the controls work by touch but drive demo state only; the flight values
/// are fixed demo data and the world behind is a flat stand-in until the M1 renderer exists.
/// Layout: thrust lever and trim under the left thumb, flaps, spoilers, gear and brake under the
/// right, the numbers along the bottom, mode annunciator and panel keys along the top.
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

            VStack(spacing: Metrics.gap) {
                TopBar(model: model)
                ZStack(alignment: .top) {
                    controls
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    panel
                }
            }
            .padding(.horizontal, Metrics.edge)
            .padding(.vertical, 8)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // `-FlightOpenPanel AP` opens a panel at launch, so scripts can screenshot it.
            if let key = UserDefaults.standard.string(forKey: "FlightOpenPanel") {
                model.openPanel = HUDModel.Panel(rawValue: key)
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom, spacing: Metrics.gap) {
            HStack(alignment: .bottom, spacing: Metrics.gap) {
                ThrottleLever(model: model)
                    .frame(maxHeight: 360)   // a full-height lever on iPad is unwieldy
                TrimControl(model: model)
            }
            Spacer(minLength: 0)
            VStack(spacing: Metrics.gap) {
                prototypeTag
                DataStrip(model: model)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: Metrics.gap) {
                HStack(spacing: Metrics.gap) {
                    GearButton(model: model)
                    BezelToggle(
                        title: "BRAKE", subtitle: "PARK",
                        isOn: model.parkingBrake, onColor: Palette.caution
                    ) { model.parkingBrake.toggle() }
                }
                HStack(alignment: .bottom, spacing: Metrics.gap) {
                    DetentLever(title: "SPLR", detents: model.spoilerDetents, index: $model.spoilerIndex) { i in
                        switch i {
                        case 0: Palette.textPrimary
                        case 1: Palette.active
                        default: Palette.caution
                        }
                    }
                    DetentLever(title: "FLAPS", detents: model.flapDetents, index: $model.flapIndex)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        if let open = model.openPanel {
            let close = { withAnimation(.snappy(duration: 0.22)) { model.openPanel = nil } }
            PanelWindow(title: open.title, onClose: close) {
                    switch open {
                    case .autopilot: AutopilotPanel(model: model)
                    case .lights: LightsPanel(model: model)
                    case .camera: CameraPanel(model: model)
                    case .map: NotYetPanel(what: "Moving map with route, traffic and airspace.", milestone: "M8")
                    case .atc: NotYetPanel(what: "Ground, tower, departure and approach.", milestone: "M9")
                    case .settings: settings
                    }
                }
            .fixedSize()
            // The autopilot strip sits centered under the mode annunciator. Other panels hang
            // under the soft keys but stop short of the right-hand controls (two 72 pt columns).
            .padding(.trailing, open == .autopilot ? 0 : 72 * 2 + Metrics.gap * 2)
            .frame(maxWidth: .infinity, alignment: open == .autopilot ? .center : .trailing)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotYetPanel(what: "Controls, graphics and realism settings.", milestone: "M3")
            Button(action: onExit) {
                Text("END FLIGHT")
                    .labelStyle(Palette.warning, size: 10)
                    .frame(maxWidth: .infinity)
                    .frame(height: Metrics.touch)
                    .bezel()
            }
            .buttonStyle(.plain)
        }
    }

    private var prototypeTag: some View {
        Text("PROTOTYPE · DEMO DATA · 3D VIEW ARRIVES IN M1")
            .labelStyle(Palette.textSecondary, size: 7)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.35), in: .capsule)
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
    let _ = Typeface.registerBundledFonts()
    FlightHUDView()
}
#endif
