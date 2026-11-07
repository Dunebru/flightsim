import SwiftUI

/// Bottom metrics: the numbers you fly by, in one glass capsule. Rounded semibold numerals with
/// small units; labels are short and quiet because the units already say what each number is.
struct MetricsBar: View {
    let model: HUDModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(extended: true)
            bar(extended: false)
        }
    }

    private func bar(extended: Bool) -> some View {
        HStack(spacing: 22) {
            metric("IAS", "\(model.indicatedAirspeed)", "kt")
            metric("GS", "\(model.groundSpeed)", "kt")
            metric("ALT", model.altitude.formatted(.number.locale(Locale(identifier: "en_US"))), "ft")
            metric("V/S", model.verticalSpeed > 0 ? "+\(model.verticalSpeed)" : "\(model.verticalSpeed)", "fpm")
            metric("HDG", String(format: "%03d°", model.heading), nil)
            if extended {
                metric("N1", String(format: "%.1f", model.n1), "%")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }

    private func metric(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(HUDStyle.caption)
                .foregroundStyle(.white.opacity(0.6))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(HUDStyle.metric(21))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(HUDStyle.unit)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Top-right cluster: one merged glass capsule of icon buttons. Camera is a native menu;
/// the rest open panels. The open panel's button takes the selection tint.
struct ToolCluster: View {
    @Bindable var model: HUDModel

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 0) {
                Menu {
                    Picker("Camera", selection: $model.camera) {
                        ForEach(HUDModel.Camera.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "video")
                        .frame(width: 48, height: 48)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Camera")
                panelButton(.map, symbol: "map")
                panelButton(.atc, symbol: "antenna.radiowaves.left.and.right")
                panelButton(.lights, symbol: "lightbulb")
                panelButton(.autopilot, text: "AP")
                panelButton(.settings, symbol: "gearshape")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private func panelButton(_ panel: HUDModel.Panel, symbol: String? = nil, text: String? = nil) -> some View {
        let isOpen = model.openPanel == panel
        return Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { model.toggle(panel) }
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else if let text {
                    Text(text).font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(isOpen ? Color.black : Color.white)
            .frame(width: 40, height: 40)
            .background { if isOpen { Circle().fill(.white) } }
            .frame(width: 48, height: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(panel.title)
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// Autopilot status, shown only while the autopilot is engaged: what it is holding, at a glance.
struct AutopilotStatus: View {
    let model: HUDModel

    var body: some View {
        // Widest that fits wins; targets drop out before anything wraps.
        ViewThatFits(in: .horizontal) {
            capsule(targets: 4)
            capsule(targets: 2)
            capsule(targets: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Autopilot engaged")
    }

    private func capsule(targets: Int) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(HUDStyle.engaged).frame(width: 8, height: 8)
                Text(model.autothrottle ? "AP · A/THR" : "AP")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(HUDStyle.engaged)
            }
            if targets >= 4 { target("SPD", "\(model.targetSpeed)") }
            if targets >= 2 { target("HDG", String(format: "%03d", model.targetHeading)) }
            if targets >= 2 { target("ALT", model.targetAltitude.formatted(.number.locale(Locale(identifier: "en_US")))) }
            if targets >= 4 { target("V/S", model.targetVerticalSpeed > 0 ? "+\(model.targetVerticalSpeed)" : "\(model.targetVerticalSpeed)") }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 16)
        .frame(height: 36)
        .glassEffect(.regular, in: .capsule)
    }

    private func target(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(HUDStyle.caption).foregroundStyle(.white.opacity(0.6))
            Text(value).font(HUDStyle.metric(15)).foregroundStyle(HUDStyle.selected)
        }
    }
}
