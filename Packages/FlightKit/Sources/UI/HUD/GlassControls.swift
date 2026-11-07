import SwiftUI

/// What a slider shows at its foot: an SF Symbol or one of our own glyphs.
enum SliderIcon {
    case symbol(String)
    case glyph(Glyph)

    @ViewBuilder
    func view(size: CGFloat) -> some View {
        switch self {
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.9, weight: .semibold))
        case .glyph(let glyph):
            GlyphView(glyph: glyph, size: size)
        }
    }
}

/// A vertical slider in the manner of Control Center's brightness and volume controls: a tall
/// glass shape that fills as the value grows. Dragging is relative, so a thumb can grab it
/// anywhere without the value jumping, and it stretches slightly past its ends like Control
/// Center does.
///
/// Thrust fills from the bottom (push up for more, like a throttle). Levers that extend
/// downward in the cockpit, flaps and speedbrake, fill from the top and list every detent.
struct GlassSlider: View {
    @Binding var value: Double          // 0...1
    var detents: [String]? = nil        // labels top-to-bottom order of travel; nil = continuous
    var fillsFromTop = false
    var fill: Color = HUDStyle.sliderFill
    let icon: SliderIcon
    var readout: String? = nil          // continuous sliders show their value at the far end
    var width: CGFloat = 64
    let accessibilityLabel: String

    @State private var dragStart: Double?
    @State private var overshoot: Double = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let shape = RoundedRectangle(cornerRadius: HUDStyle.sliderCorner, style: .continuous)
            let fillAlignment: Alignment = fillsFromTop ? .top : .bottom
            let filled = fillHeight(total: h)
            ZStack(alignment: fillAlignment) {
                Rectangle()
                    .fill(fill)
                    .frame(height: filled)
                // Content in white over glass, inverted to black where the fill covers it.
                content(color: .white, height: h)
                    .overWorldLegibility()
                content(color: .black.opacity(0.85), height: h)
                    .mask(alignment: fillAlignment) { Rectangle().frame(height: filled) }
            }
            .frame(width: width, height: h)
            .clipShape(shape)
            .background { Color.clear.glassEffect(HUDStyle.glassInteractive, in: shape) }
            .contentShape(shape)
            .scaleEffect(x: 1 - abs(overshoot) * 0.15, y: 1 + abs(overshoot) * 0.35,
                         anchor: (overshoot > 0) != fillsFromTop ? .bottom : .top)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        let direction: Double = fillsFromTop ? 1 : -1
                        let proposed = start + direction * drag.translation.height / h
                        set(proposed)
                        // Rubber band past the ends, capped and eased.
                        let past = proposed > 1 ? proposed - 1 : (proposed < 0 ? proposed : 0)
                        overshoot = max(-0.12, min(0.12, past * 0.25))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { overshoot = 0 }
                    }
            )
        }
        .frame(width: width)
        .sensoryFeedback(.selection, trigger: detents == nil ? 0 : detentIndex)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(detents.map { $0[detentIndex] } ?? (readout ?? ""))
        .accessibilityAdjustableAction { direction in
            let delta = detents.map { 1 / Double($0.count - 1) } ?? 0.05
            set(value + (direction == .increment ? delta : -delta))
        }
    }

    /// Continuous sliders fill in proportion. Detented sliders fill down to just past the
    /// current detent's name, so the named position is always the edge of the fill.
    private func fillHeight(total h: CGFloat) -> CGFloat {
        guard let detents, detents.count > 1 else { return h * value }
        if detentIndex == 0 { return 0 }
        if detentIndex == detents.count - 1 { return h }
        let span = h - Self.detentInset - 22
        return Self.detentInset + span * Double(detentIndex) / Double(detents.count - 1) + 12
    }

    private static let detentInset: CGFloat = 46

    private var detentIndex: Int {
        guard let detents else { return 0 }
        return Int((value * Double(detents.count - 1)).rounded())
    }

    private func set(_ proposed: Double) {
        let clamped = min(max(proposed, 0), 1)
        if let detents, detents.count > 1 {
            let n = Double(detents.count - 1)
            value = (clamped * n).rounded() / n
        } else {
            value = clamped
        }
    }

    @ViewBuilder
    private func content(color: Color, height: CGFloat) -> some View {
        if let detents {
            detentScale(detents, color: color, height: height)
        } else {
            VStack {
                if let readout {
                    Text(readout)
                        .font(HUDStyle.metric(17))
                        .contentTransition(.numericText())
                        .padding(.top, 14)
                }
                Spacer()
                icon.view(size: 22).padding(.bottom, 16)
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
        }
    }

    /// Every detent named down the slider; the current one in bold. The icon sits at the
    /// stowed end so it is never covered by a small extension.
    private func detentScale(_ labels: [String], color: Color, height: CGFloat) -> some View {
        let inset = Self.detentInset
        let span = height - inset - 22
        return ZStack(alignment: .top) {
            icon.view(size: width < 56 ? 18 : 20)
                .padding(.top, 14)
                .frame(maxWidth: .infinity)
            ForEach(labels.indices, id: \.self) { i in
                Text(labels[i])
                    .font(.system(size: i == detentIndex ? 13 : 11,
                                  weight: i == detentIndex ? .bold : .medium,
                                  design: .rounded))
                    .opacity(i == detentIndex ? 1 : 0.7)
                    .frame(maxWidth: .infinity)
                    .offset(y: inset + span * Double(i) / Double(max(labels.count - 1, 1)) - 7)
            }
        }
        .foregroundStyle(color)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A round glass toggle in the manner of Control Center's buttons: glass when off, a solid
/// state color when on with a dark glyph, so every "on" color keeps its true hue and contrast.
struct GlassCircleToggle<Label: View>: View {
    let isOn: Bool
    var onColor: Color = .white
    var size: CGFloat = HUDStyle.circle
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background {
                    ZStack {
                        Color.clear.glassEffect(HUDStyle.glassInteractive, in: .circle)
                        if isOn { Circle().fill(onColor) }
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
