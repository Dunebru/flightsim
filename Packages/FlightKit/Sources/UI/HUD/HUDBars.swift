import SwiftUI

/// Flight data across the top center: the numbers you fly by in one glass capsule. Rounded
/// semibold numerals with small units. Drops the least essential values before it would squeeze.
struct MetricsBar: View {
    let model: HUDModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(level: 2)
            bar(level: 1)
            bar(level: 0)
        }
    }

    /// level 2: six values; 1: five; 0: four.
    private func bar(level: Int) -> some View {
        HStack(spacing: 20) {
            metric("IAS", "\(model.indicatedAirspeed)", "kt")
            if level >= 1 { metric("GS", "\(model.groundSpeed)", "kt") }
            metric("ALT", model.altitude.formatted(.number.locale(Locale(identifier: "en_US"))), "ft")
            metric("V/S", model.verticalSpeed > 0 ? "+\(model.verticalSpeed)" : "\(model.verticalSpeed)", "fpm")
            metric("HDG", String(format: "%03d°", model.heading), nil)
            if level >= 2 { metric("N1", String(format: "%.1f", model.n1), "%") }
        }
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(height: 52)
        .glassEffect(HUDStyle.glass, in: .capsule)
        .fixedSize()
    }

    private func metric(_ label: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(HUDStyle.caption)
                .foregroundStyle(HUDStyle.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(HUDStyle.metric(20))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(HUDStyle.unit)
                        .foregroundStyle(HUDStyle.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Bottom center: one merged glass capsule of buttons. Camera is a native menu; the rest open
/// panels, which rise from just above this bar. The open panel's button turns white.
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
                    Image(systemName: "video.fill")
                        .frame(width: 48, height: 48)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Camera")
                panelButton(.map, symbol: "map.fill")
                panelButton(.atc, symbol: "antenna.radiowaves.left.and.right")
                panelButton(.autopilot, text: "AP")
                panelButton(.lights, symbol: "lightbulb.fill")
                panelButton(.settings, symbol: "gearshape.fill")
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .glassEffect(HUDStyle.glassInteractive, in: .capsule)
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

/// Autopilot status under the flight data while the autopilot is engaged: what it is holding.
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
        .frame(height: 34)
        .glassEffect(HUDStyle.glass, in: .capsule)
    }

    private func target(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(HUDStyle.caption).foregroundStyle(HUDStyle.secondaryText)
            Text(value).font(HUDStyle.metric(15)).foregroundStyle(HUDStyle.selected)
        }
    }
}
