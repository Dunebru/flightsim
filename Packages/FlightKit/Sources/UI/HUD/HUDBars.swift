import Airports
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
            if level >= 2 {
                if model.profile.isTurbine {
                    metric("N1", String(format: "%.1f", model.n1), "%")
                } else {
                    metric("RPM", String(format: "%.0f", model.n1), nil)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 22)
        .frame(height: 52)
        .hudSurface(in: .capsule)
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
        Group {
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
            .hudSurface(in: .capsule)
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
            // Flight mode annunciations: lateral and vertical modes, green when active; a mode
            // still capturing carries an asterisk.
            HStack(spacing: 8) {
                if !model.apLateral.isEmpty { mode(model.apLateral) }
                if !model.apVertical.isEmpty { mode(model.apVertical) }
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
        .hudSurface(in: .capsule)
    }

    private func mode(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(HUDStyle.engaged)
    }

    private func target(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(HUDStyle.caption).foregroundStyle(HUDStyle.secondaryText)
            Text(value).font(HUDStyle.metric(15)).foregroundStyle(HUDStyle.selected)
        }
    }
}

/// Stall warning: red, pulsing, with a warning haptic when it appears.
struct StallWarning: View {
    var body: some View {
        Text("STALL")
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 36)
            .background(HUDStyle.warning, in: .capsule)
            .phaseAnimator([1.0, 0.55]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.3) }
            .sensoryFeedback(.warning, trigger: true)
            .accessibilityLabel("Stall warning")
    }
}

/// Pushback, under the flight data: offered when parked (an airliner stopped with the parking
/// brake set), the three ways to push; while pushing, what is happening and a stop.
struct PushbackBar: View {
    @Bindable var model: HUDModel

    var body: some View {
        HStack(spacing: 6) {
            if model.pushingBack {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(HUDStyle.engaged)
                Text("Pushing back")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.trailing, 6)
                choice("Stop", symbol: "stop.fill") { model.pushbackStopRequested = true }
            } else {
                Text("Push back")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(HUDStyle.secondaryText)
                    .padding(.horizontal, 6)
                choice("Tail left", symbol: "arrow.turn.down.left") { model.pushbackRequest = .tailLeft }
                choice("Straight", symbol: "arrow.down") { model.pushbackRequest = .straight }
                choice("Tail right", symbol: "arrow.turn.down.right") { model.pushbackRequest = .tailRight }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 44)
        .hudSurface(in: .capsule)
    }

    private func choice(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.white.opacity(0.14), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// After touchdown: how the landing went, in one capsule card. Tap to dismiss.
struct LandingCard: View {
    let report: LandingReport
    let onDismiss: () -> Void

    private static func feet(_ metres: Double) -> String {
        Int((metres / 0.3048).rounded()).formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private var gradeColor: Color {
        switch report.grade {
        case .butter, .smooth: HUDStyle.engaged
        case .firm: .white
        case .hard, .veryHard: HUDStyle.warning
        }
    }

    /// Where on the runway, in a sentence.
    private var place: String? {
        guard let rw = report.runway, let past = report.pastThreshold, let off = report.offCentreline else { return nil }
        let along = past < 0 ? "\(Self.feet(-past)) ft short of the threshold" : "\(Self.feet(past)) ft past the threshold"
        let side = abs(off) < 1.5 ? "on the centerline" : "\(Self.feet(abs(off))) ft \(off > 0 ? "left" : "right") of the centerline"
        return "Runway \(rw), \(along), \(side)"
    }

    var body: some View {
        Button(action: onDismiss) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(report.grade.rawValue)
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(gradeColor)
                    Text("\(Int(report.sinkRate.rounded())) fpm")
                        .font(HUDStyle.metric(17)).foregroundStyle(.white)
                    Text(String(format: "%.2f g", report.peakG))
                        .font(HUDStyle.metric(17)).foregroundStyle(.white)
                    Text("\(Int(report.airspeedKnots.rounded())) kt")
                        .font(HUDStyle.metric(17)).foregroundStyle(.white)
                    Text(String(format: "pitch %.1f°  bank %.1f°", report.pitchDegrees, abs(report.bankDegrees)))
                        .font(HUDStyle.caption).foregroundStyle(HUDStyle.secondaryText)
                }
                if let place {
                    Text(place).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(HUDStyle.secondaryText)
                }
                if let rollout = report.rollout {
                    Text("Slowed to taxi speed in \(Self.feet(rollout)) ft")
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(HUDStyle.secondaryText)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .hudSurface(in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Landing: \(report.grade.rawValue), \(Int(report.sinkRate.rounded())) feet per minute")
    }
}

/// Watching the flight back: the world fills the screen; along the bottom, play or hold, a
/// scrubber over what was kept (the last ten minutes), the time, and a way back to flying.
struct ReplayOverlay: View {
    @Bindable var model: HUDModel

    private static func clock(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Circle().fill(HUDStyle.warning).frame(width: 9, height: 9)
                Text("Replay").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .hudSurface(in: .capsule)
            .padding(.top, 12)
            Spacer()
            HStack(spacing: 14) {
                Button {
                    if !model.replayPlaying && model.replayPosition >= model.replayDuration - 0.2 { model.replaySeek = 0 }
                    model.replayPlaying.toggle()
                } label: {
                    Image(systemName: model.replayPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.replayPlaying ? "Pause replay" : "Play replay")
                Text(Self.clock(model.replayPosition))
                    .font(HUDStyle.metric(15)).foregroundStyle(.white).monospacedDigit()
                Slider(value: Binding(get: { model.replayPosition },
                                      set: { model.replaySeek = $0; model.replayPosition = $0 }),
                       in: 0...max(model.replayDuration, 1))
                    .tint(.white)
                    .accessibilityLabel("Replay position")
                Text(Self.clock(model.replayDuration))
                    .font(HUDStyle.metric(15)).foregroundStyle(HUDStyle.secondaryText).monospacedDigit()
                Button {
                    withAnimation(.spring(duration: 0.3)) { model.replaying = false }
                } label: {
                    Text("Back to flying")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(.white, in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            .hudSurface(in: .capsule)
            .padding(.horizontal, 40)
            .padding(.bottom, 14)
        }
    }
}
