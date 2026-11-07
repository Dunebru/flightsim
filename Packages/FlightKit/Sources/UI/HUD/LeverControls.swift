import SwiftUI

/// Thrust lever: a vertical track under the left thumb. Forward thrust above the idle line,
/// reverse below it behind a gate, shaded amber. The readout above shows THR or REV.
struct ThrottleLever: View {
    @Bindable var model: HUDModel

    private let range = HUDModel.throttleRange
    private let handleHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: Metrics.gap) {
            readout
            GeometryReader { geo in
                let height = geo.size.height
                ZStack(alignment: .top) {
                    track(height: height)
                    handle
                        .offset(y: y(for: model.throttle, height: height) - handleHeight / 2)
                }
                .frame(width: geo.size.width, height: height)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { model.setThrottle(value(atY: $0.location.y, height: height)) }
                )
            }
            .padding(.vertical, 10)
            .bezel()
        }
        .frame(width: 64)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.isReverse)
        .accessibilityElement()
        .accessibilityLabel("Throttle")
        .accessibilityValue(model.isReverse ? "Reverse \(percent) percent" : "\(percent) percent")
        .accessibilityAdjustableAction { direction in
            model.setThrottle(model.throttle + (direction == .increment ? 0.05 : -0.05))
        }
    }

    private var percent: Int {
        Int((model.isReverse ? -model.throttle / -range.lowerBound : model.throttle) * 100 + 0.5)
    }

    private var readout: some View {
        VStack(spacing: 2) {
            Text(model.isReverse ? "REV" : "THR")
                .labelStyle(model.isReverse ? Palette.caution : Palette.textSecondary)
            Text("\(percent)")
                .font(Typeface.valueBold(18))
                .foregroundStyle(model.isReverse ? Palette.caution : Palette.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .bezel()
    }

    private func track(height: CGFloat) -> some View {
        let idleY = y(for: 0, height: height)
        return ZStack(alignment: .topLeading) {
            // Reverse zone.
            Rectangle()
                .fill(Palette.caution.opacity(0.16))
                .frame(height: height - idleY)
                .offset(y: idleY)
            // Slot.
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(width: 6)
                .frame(maxWidth: .infinity)
            // Scale.
            ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { mark in
                tick(width: 10).offset(x: 4, y: y(for: mark, height: height))
            }
            tick(width: 56, color: Palette.textSecondary).offset(y: idleY)
            Text("IDLE").labelStyle(Palette.textSecondary, size: 7)
                .offset(x: 4, y: idleY - 11)
            Text("REV").labelStyle(Palette.caution, size: 7)
                .offset(x: 4, y: idleY + 4)
        }
    }

    private func tick(width: CGFloat, color: Color = Palette.textTertiary) -> some View {
        Rectangle().fill(color).frame(width: width, height: 1)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(model.isReverse ? Palette.caution : Palette.textPrimary)
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 48, height: handleHeight)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    private func y(for value: Double, height: CGFloat) -> CGFloat {
        let t = (range.upperBound - value) / (range.upperBound - range.lowerBound)
        return CGFloat(t) * height
    }

    private func value(atY y: CGFloat, height: CGFloat) -> Double {
        let t = Double(min(max(y / max(height, 1), 0), 1))
        return range.upperBound - t * (range.upperBound - range.lowerBound)
    }
}

/// A vertical lever with named detents (flaps, spoilers). Drag the handle or tap a detent name.
struct DetentLever: View {
    let title: String
    let detents: [String]
    @Binding var index: Int
    /// Color of the current detent's name, so state reads at a glance (e.g. spoilers armed = green).
    var accent: (Int) -> Color = { _ in Palette.textPrimary }

    var body: some View {
        VStack(spacing: 6) {
            Text(title).labelStyle()
            GeometryReader { geo in
                let step = geo.size.height / CGFloat(max(detents.count - 1, 1))
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 4, height: geo.size.height)
                        .offset(x: 10)
                    ForEach(detents.indices, id: \.self) { i in
                        let isCurrent = i == index
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(isCurrent ? accent(i) : Palette.textTertiary)
                                .frame(width: isCurrent ? 24 : 10, height: isCurrent ? 6 : 1)
                                .clipShape(.rect(cornerRadius: 2))
                                .frame(width: 24, alignment: .leading)
                            Text(detents[i])
                                .font(isCurrent ? Typeface.title(11) : Typeface.text(10))
                                .foregroundStyle(isCurrent ? accent(i) : Palette.textTertiary)
                        }
                        .frame(height: 20)
                        .offset(y: CGFloat(i) * step - 10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { drag in
                        let i = Int((drag.location.y / step).rounded())
                        index = min(max(i, 0), detents.count - 1)
                    }
                )
            }
            .padding(.vertical, 12)
            .padding(.leading, 8)
        }
        .padding(.top, 8)
        .frame(width: 72)
        .bezel()
        .sensoryFeedback(.selection, trigger: index)
        .animation(.snappy(duration: 0.18), value: index)
        .accessibilityElement()
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(detents[index])
        .accessibilityAdjustableAction { direction in
            index = min(max(index + (direction == .increment ? 1 : -1), 0), detents.count - 1)
        }
    }
}

/// Gear handle with the three position lights pilots check: green down and locked, red in transit.
struct GearButton: View {
    @Bindable var model: HUDModel

    var body: some View {
        Button { model.toggleGear() } label: {
            VStack(spacing: 6) {
                Text("GEAR").labelStyle()
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(lightColor)
                            .frame(width: 11, height: 11)
                    }
                }
                Text(stateText).labelStyle(lightColor == .clear ? Palette.textTertiary : lightColor, size: 8)
            }
            .frame(width: 72, height: 64)
            .bezel()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.gear)
        .accessibilityLabel("Landing gear")
        .accessibilityValue(stateText)
    }

    private var lightColor: Color {
        switch model.gear {
        case .down: Palette.active
        case .transit: Palette.warning
        case .up: Color.white.opacity(0.10)
        }
    }

    private var stateText: String {
        switch model.gear {
        case .down: "DOWN"
        case .transit: "TRANSIT"
        case .up: "UP"
        }
    }
}

/// A two-state key in the bezel style. `onColor` follows the avionics convention for the switch.
struct BezelToggle: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    var onColor: Color = Palette.active
    var width: CGFloat = 72
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).labelStyle(isOn ? onColor : Palette.textSecondary)
                Rectangle()
                    .fill(isOn ? onColor : Color.white.opacity(0.10))
                    .frame(width: 26, height: 3)
                if let subtitle {
                    Text(subtitle).labelStyle(Palette.textTertiary, size: 7)
                }
            }
            .frame(width: width, height: subtitle == nil ? Metrics.touch : 64)
            .bezel()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Elevator trim: two keys and a position indicator, next to the throttle.
struct TrimControl: View {
    @Bindable var model: HUDModel

    var body: some View {
        VStack(spacing: 6) {
            Text("TRIM").labelStyle()
            key("chevron.up", delta: 0.04)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .top) {
                    Capsule().fill(Color.white.opacity(0.08)).frame(width: 4)
                    Rectangle().fill(Palette.textTertiary).frame(width: 14, height: 1).offset(y: h / 2)
                    Capsule()
                        .fill(Palette.textPrimary)
                        .frame(width: 14, height: 4)
                        .offset(y: CGFloat((1 - model.trim) / 2) * h - 2)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 64)
            key("chevron.down", delta: -0.04)
        }
        .padding(.vertical, 8)
        .frame(width: 48)
        .bezel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elevator trim")
        .accessibilityValue("\(Int(model.trim * 100)) percent nose \(model.trim >= 0 ? "up" : "down")")
        .accessibilityAdjustableAction { model.nudgeTrim($0 == .increment ? 0.04 : -0.04) }
    }

    private func key(_ symbol: String, delta: Double) -> some View {
        Button { model.nudgeTrim(delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 40, height: 36)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}
