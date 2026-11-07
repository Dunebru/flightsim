import SwiftUI

/// A floating panel window: header with title and close key, then content. Panels drop from the
/// top bar and never cover the throttle or the right-hand controls.
struct PanelWindow<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased()).labelStyle(Palette.textPrimary, size: 10)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: Metrics.touch, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
            .padding(.leading, 12)
            .frame(height: 32)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            content.padding(12)
        }
        .background(Palette.panelFill, in: .rect(cornerRadius: Metrics.corner))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner).strokeBorder(Palette.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }
}

/// Autopilot control strip, laid out like a glareshield panel: four target windows in cyan with
/// step keys, and the engage keys below.
struct AutopilotPanel: View {
    @Bindable var model: HUDModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: Metrics.gap) {
                TargetWindow(label: "SPD", value: "\(model.targetSpeed)", unit: "KT") {
                    model.targetSpeed = min(max(model.targetSpeed + $0, 100), 399)
                }
                TargetWindow(label: "HDG", value: String(format: "%03d", model.targetHeading), unit: "MAG") {
                    model.targetHeading = ((model.targetHeading + $0 - 1) % 360 + 360) % 360 + 1
                }
                TargetWindow(label: "ALT", value: model.targetAltitude.formatted(.number.grouping(.automatic)), unit: "FT", step: 100) {
                    model.targetAltitude = min(max(model.targetAltitude + $0, 0), 45_000)
                }
                TargetWindow(label: "V/S", value: model.targetVerticalSpeed > 0 ? "+\(model.targetVerticalSpeed)" : "\(model.targetVerticalSpeed)", unit: "FPM", step: 100) {
                    model.targetVerticalSpeed = min(max(model.targetVerticalSpeed + $0, -6_000), 6_000)
                }
            }
            HStack(spacing: Metrics.gap) {
                BezelToggle(title: "AP", isOn: model.apMaster, width: 66) { model.apMaster.toggle() }
                BezelToggle(title: "A/THR", isOn: model.autothrottle, width: 66) { model.autothrottle.toggle() }
                BezelToggle(title: "LOC", isOn: model.locArmed, onColor: Palette.selected, width: 66) { model.locArmed.toggle() }
                BezelToggle(title: "APPR", isOn: model.approachArmed, onColor: Palette.selected, width: 66) { model.approachArmed.toggle() }
            }
        }
    }
}

/// One autopilot target: label, cyan value, and step keys that repeat when held.
struct TargetWindow: View {
    let label: String
    let value: String
    let unit: String
    var step = 1
    let change: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(label).labelStyle(Palette.textSecondary, size: 8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(Typeface.valueBold(17))
                    .foregroundStyle(Palette.selected)
                    .contentTransition(.numericText())
                Text(unit).labelStyle(Palette.textTertiary, size: 7)
            }
            .frame(height: 22)
            HStack(spacing: 0) {
                stepKey("minus", -step)
                Rectangle().fill(Palette.hairline).frame(width: 1, height: 18)
                stepKey("plus", step)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.hairline))
        }
        .frame(width: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected \(label)")
        .accessibilityValue("\(value) \(unit)")
        .accessibilityAdjustableAction { change($0 == .increment ? step : -step) }
    }

    private func stepKey(_ symbol: String, _ delta: Int) -> some View {
        Button { change(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 44, height: 30)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

struct LightsPanel: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(HUDModel.Light.allCases) { light in
                BezelToggle(title: light.rawValue, isOn: model.lights.contains(light), width: 54) {
                    model.toggle(light)
                }
            }
        }
    }
}

struct CameraPanel: View {
    @Bindable var model: HUDModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(HUDModel.Camera.allCases) { camera in
                Button { model.camera = camera } label: {
                    HStack {
                        Text(camera.rawValue)
                            .font(Typeface.text(13))
                            .foregroundStyle(model.camera == camera ? Palette.selected : Palette.textPrimary)
                        Spacer()
                        if model.camera == camera {
                            Rectangle().fill(Palette.selected).frame(width: 14, height: 2)
                        }
                    }
                    .frame(height: 36)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.camera == camera ? .isSelected : [])
            }
        }
        .frame(width: 200)
        .sensoryFeedback(.selection, trigger: model.camera)
    }
}

/// Stand-in body for panels whose systems do not exist yet. States the milestone plainly.
struct NotYetPanel: View {
    let what: String
    let milestone: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(what)
                .font(Typeface.text(13))
                .foregroundStyle(Palette.textPrimary)
            Text("Not built yet. Arrives in \(milestone).")
                .font(Typeface.text(11))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(width: 240, alignment: .leading)
    }
}
