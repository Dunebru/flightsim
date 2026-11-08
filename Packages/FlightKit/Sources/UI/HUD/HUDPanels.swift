import FlightModel
import Renderer
import SwiftUI

/// A floating glass card that rises from the bottom bar. Title and a close button on top.
struct GlassPanel<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                if let trailing { trailing }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.18), in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
            content
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .glassEffect(HUDStyle.glass, in: .rect(cornerRadius: 28, style: .continuous))
    }
}

/// Autopilot, laid out like a glareshield: four selected targets; tap one to select it, then
/// adjust it with one row of fine and coarse keys. One adjuster instead of four keeps every key
/// at a full 44 pt and the panel narrow enough to sit between the thumb columns.
struct AutopilotPanel: View {
    @Bindable var model: HUDModel
    @State private var selected: Target = .altitude

    enum Target: CaseIterable {
        case speed, heading, altitude, verticalSpeed

        var label: String {
            switch self {
            case .speed: "Speed"
            case .heading: "Heading"
            case .altitude: "Altitude"
            case .verticalSpeed: "V/S"
            }
        }

        /// Fine and coarse steps.
        var steps: (fine: Int, coarse: Int) {
            switch self {
            case .speed: (1, 10)
            case .heading: (1, 10)
            case .altitude: (100, 1_000)
            case .verticalSpeed: (100, 500)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Target.allCases, id: \.self) { target in
                    chip(target)
                }
            }
            HStack(spacing: 6) {
                let s = selected.steps
                adjust("−\(s.coarse.formatted())", -s.coarse)
                adjust("−\(s.fine.formatted())", -s.fine)
                adjust("+\(s.fine.formatted())", s.fine)
                adjust("+\(s.coarse.formatted())", s.coarse)
            }
            Text("Autopilot logic arrives in M8: these targets do not fly the aircraft yet.")
                .font(.system(size: 12))
                .foregroundStyle(HUDStyle.secondaryText)
            HStack(spacing: 6) {
                mode("A/THR", isOn: model.autothrottle) { model.autothrottle.toggle() }
                mode("LOC", isOn: model.locArmed) { model.locArmed.toggle() }
                mode("APPR", isOn: model.approachArmed) { model.approachArmed.toggle() }
            }
        }
        .padding(.trailing, 10)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func value(_ target: Target) -> (String, String?) {
        switch target {
        case .speed: ("\(model.targetSpeed)", "kt")
        case .heading: (String(format: "%03d°", model.targetHeading), nil)
        case .altitude: (model.targetAltitude.formatted(.number.locale(Locale(identifier: "en_US"))), "ft")
        case .verticalSpeed: (model.targetVerticalSpeed > 0 ? "+\(model.targetVerticalSpeed)" : "\(model.targetVerticalSpeed)", "fpm")
        }
    }

    private func change(_ target: Target, by delta: Int) {
        switch target {
        case .speed: model.targetSpeed = min(max(model.targetSpeed + delta, 100), 399)
        case .heading: model.targetHeading = ((model.targetHeading + delta - 1) % 360 + 360) % 360 + 1
        case .altitude: model.targetAltitude = min(max(model.targetAltitude + delta, 0), 45_000)
        case .verticalSpeed: model.targetVerticalSpeed = min(max(model.targetVerticalSpeed + delta, -6_000), 6_000)
        }
    }

    private func chip(_ target: Target) -> some View {
        let isSelected = selected == target
        let (text, unit) = value(target)
        return Button { selected = target } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.7) : HUDStyle.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(text)
                        .font(HUDStyle.metric(20))
                        .foregroundStyle(isSelected ? Color.black : (model.apMaster ? HUDStyle.selected : .white))
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(HUDStyle.unit)
                            .foregroundStyle(isSelected ? Color.black.opacity(0.7) : HUDStyle.secondaryText)
                    }
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 92, minHeight: 56, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(HUDStyle.selected) : AnyShapeStyle(.white.opacity(0.12)),
                        in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Selected \(target.label)")
        .accessibilityValue("\(text) \(unit ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAdjustableAction { change(target, by: $0 == .increment ? target.steps.fine : -target.steps.fine) }
    }

    private func adjust(_ title: String, _ delta: Int) -> some View {
        Button { change(selected, by: delta) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.16), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel("\(delta > 0 ? "Increase" : "Decrease") \(selected.label) by \(abs(delta))")
    }

    private func mode(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? AnyShapeStyle(HUDStyle.engaged) : AnyShapeStyle(.white.opacity(0.16)), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Exterior lights as a Control Center-style row of round toggles with a caption under each.
struct LightsPanel: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                        .foregroundStyle(HUDStyle.secondaryText)
                }
            }
        }
        .padding(.trailing, 10)
    }
}

struct SettingsPanel: View {
    #if os(iOS)
    @Bindable var engine: WorldEngine
    let profile: AircraftProfile
    let onSelectAircraft: (AircraftProfile) -> Void
    let onReset: () -> Void
    let onCalibrateTilt: () -> Void
    #endif
    let onEndFlight: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            VStack(alignment: .leading, spacing: 6) {
                Text("Aircraft")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HUDStyle.secondaryText)
                Picker("Aircraft", selection: Binding(get: { profile }, set: { onSelectAircraft($0) })) {
                    ForEach(AircraftProfile.all) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(profile.fidelityNote)
                    .font(.system(size: 12))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: onReset) {
                    Text("Reset to runway").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.glass)
                Button(action: onCalibrateTilt) {
                    Text("Level tilt").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.glass)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Upscaling")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HUDStyle.secondaryText)
                Picker("Upscaling", selection: $engine.upscaler) {
                    Text("MetalFX").tag(UpscalerMode.temporal)
                    Text("Spatial").tag(UpscalerMode.spatial)
                    Text("Off").tag(UpscalerMode.off)
                }
                .pickerStyle(.segmented)
                .disabled(!engine.temporalSupported)
                if !engine.temporalSupported {
                    Text("MetalFX is not available on this device; rendering at full resolution.")
                        .font(.system(size: 12))
                        .foregroundStyle(HUDStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Frame statistics", isOn: $engine.showStats)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .tint(HUDStyle.engaged)
            #endif
            Text("More control and realism settings arrive in M3.")
                .font(.system(size: 13))
                .foregroundStyle(HUDStyle.secondaryText)
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
        .frame(width: 320)
        .padding(.trailing, 10)
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
            .frame(width: 300, height: 160)
            .padding(.trailing, 10)
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

    /// One distinct silhouette per light.
    var symbol: String {
        switch self {
        case .nav: "circle.grid.2x1.fill"          // the wingtip pair
        case .beacon: "light.beacon.max"
        case .strobe: "bolt.fill"
        case .landing: "headlight.high.beam"
        case .taxi: "flashlight.on.fill"
        case .logo: "airplane"
        }
    }
}
