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
/// glass shape that fills from the bottom. Dragging is relative, so a thumb can grab it anywhere
/// without the value jumping. With `steps`, it snaps to detents and clicks on each one.
struct GlassSlider: View {
    @Binding var value: Double          // 0...1
    var steps: Int? = nil               // number of detents including both ends
    var fill: Color = HUDStyle.sliderFill
    let icon: SliderIcon
    let topText: String
    var width: CGFloat = 64
    let accessibilityLabel: String

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let shape = RoundedRectangle(cornerRadius: HUDStyle.sliderCorner, style: .continuous)
            ZStack(alignment: .bottom) {
                // Fill
                Rectangle()
                    .fill(fill)
                    .frame(height: h * value)
                // Content in white over glass, inverted to black where the fill covers it.
                content(color: .white)
                    .overWorldLegibility()
                content(color: .black.opacity(0.85))
                    .mask(alignment: .bottom) { Rectangle().frame(height: h * value) }
                if let steps, steps > 2 {
                    detentMarks(steps: steps, height: h)
                }
            }
            .frame(width: width, height: h)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        set(start - drag.translation.height / h)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .frame(width: width)
        .sensoryFeedback(.selection, trigger: steps == nil ? 0 : detent)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(topText)
        .accessibilityAdjustableAction { direction in
            let delta = steps.map { 1 / Double($0 - 1) } ?? 0.05
            set(value + (direction == .increment ? delta : -delta))
        }
    }

    private var detent: Int {
        guard let steps else { return 0 }
        return Int((value * Double(steps - 1)).rounded())
    }

    private func set(_ proposed: Double) {
        let clamped = min(max(proposed, 0), 1)
        if let steps, steps > 1 {
            let n = Double(steps - 1)
            value = (clamped * n).rounded() / n
        } else {
            value = clamped
        }
    }

    private func content(color: Color) -> some View {
        VStack {
            Text(topText)
                .font(HUDStyle.metric(width < 56 ? 13 : 17))
                .contentTransition(.numericText())
                .padding(.top, 14)
            Spacer()
            icon.view(size: width < 56 ? 18 : 22)
                .padding(.bottom, 16)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
    }

    private func detentMarks(steps: Int, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ForEach(1..<(steps - 1), id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 10, height: 2)
                    .offset(y: -height * Double(i) / Double(steps - 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 6)
    }
}

/// A round glass toggle in the manner of Control Center's buttons: glass when off, filled with
/// its state color when on.
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
                .foregroundStyle(isOn ? (onColor == .white ? Color.black : Color.white) : Color.white)
                .frame(width: size, height: size)
                .background {
                    if isOn { Circle().fill(onColor) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
