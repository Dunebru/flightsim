import SwiftUI

/// A floating glass card that hangs under the tool cluster. Title and a close button on top.
struct GlassPanel<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                if let trailing { trailing }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.14), in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
            content
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 28, style: .continuous))
    }
}

struct AutopilotPanel: View {
    @Bindable var model: HUDModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                target("Speed", "\(model.targetSpeed)", "kt") {
                    model.targetSpeed = min(max(model.targetSpeed + $0, 100), 399)
                }
                target("Heading", String(format: "%03d°", model.targetHeading), nil) {
                    model.targetHeading = ((model.targetHeading + $0 - 1) % 360 + 360) % 360 + 1
                }
                target("Altitude", model.targetAltitude.formatted(.number.locale(Locale(identifier: "en_US"))), "ft", step: 100) {
                    model.targetAltitude = min(max(model.targetAltitude + $0, 0), 45_000)
                }
                target("Vertical speed", model.targetVerticalSpeed > 0 ? "+\(model.targetVerticalSpeed)" : "\(model.targetVerticalSpeed)", "fpm", step: 100) {
                    model.targetVerticalSpeed = min(max(model.targetVerticalSpeed + $0, -6_000), 6_000)
                }
            }
            HStack(spacing: 8) {
                modeButton("A/THR", isOn: model.autothrottle) { model.autothrottle.toggle() }
                modeButton("LOC", isOn: model.locArmed) { model.locArmed.toggle() }
                modeButton("APPR", isOn: model.approachArmed) { model.approachArmed.toggle() }
                Spacer(minLength: 0)
            }
        }
        .padding(.trailing, 12)
    }

    private func target(_ label: String, _ value: String, _ unit: String?, step: Int = 1,
                        change: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(HUDStyle.metric(24))
                    .foregroundStyle(model.apMaster ? HUDStyle.selected : .white)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit).font(HUDStyle.unit).foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(spacing: 8) {
                stepper("minus", label: "Decrease \(label)") { change(-step) }
                stepper("plus", label: "Increase \(label)") { change(step) }
            }
        }
        .frame(minWidth: 96, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func stepper(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 36)
                .background(.white.opacity(0.14), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private func modeButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(isOn ? AnyShapeStyle(HUDStyle.engaged) : AnyShapeStyle(.white.opacity(0.14)), in: .capsule)
                .frame(minHeight: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Exterior lights as a Control Center-style grid of round toggles with a caption under each.
struct LightsPanel: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(HUDModel.Light.allCases) { light in
                VStack(spacing: 6) {
                    GlassCircleToggle(
                        isOn: model.lights.contains(light),
                        size: 50,
                        accessibilityLabel: light.name
                    ) {
                        model.toggle(light)
                    } label: {
                        Image(systemName: light.symbol)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    Text(light.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.trailing, 12)
    }
}

struct SettingsPanel: View {
    let onEndFlight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls, graphics and realism settings arrive in M3.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive, action: onEndFlight) {
                Text("End Flight")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.glass)
            .tint(.red)
        }
        .frame(width: 280)
        .padding(.trailing, 12)
    }
}

/// A system that does not exist yet, said plainly in the platform's own empty-state view.
struct NotYetPanel: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .foregroundStyle(.white)
            .frame(width: 300, height: 170)
            .padding(.trailing, 12)
    }
}

nonisolated extension HUDModel.Light {
    var name: String {
        switch self {
        case .nav: "Nav"
        case .beacon: "Beacon"
        case .strobe: "Strobe"
        case .landing: "Landing"
        case .taxi: "Taxi"
        case .logo: "Logo"
        }
    }

    var symbol: String {
        switch self {
        case .nav: "light.beacon.min"
        case .beacon: "light.beacon.max"
        case .strobe: "bolt"
        case .landing: "headlight.high.beam"
        case .taxi: "headlight.low.beam"
        case .logo: "airplane"
        }
    }
}
