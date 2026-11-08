import SwiftUI

/// On-screen stick for flying without tilt: a glass well with a knob that follows the thumb and
/// springs back to centre on release. Pulling the knob down (toward the pilot) is nose up.
struct VirtualStick: View {
    /// Output: pitch (+ nose up) and roll (+ right), each -1...1.
    let onChange: (Double, Double) -> Void
    var size: CGFloat = 132

    @State private var offset: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        let radius = size / 2
        let knob = size * 0.38
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(HUDStyle.glassInteractive, in: .circle)
            // Centre mark and travel ring.
            Circle()
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                .padding(size * 0.12)
            Circle()
                .fill(.white)
                .frame(width: knob, height: knob)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .offset(offset)
        }
        .frame(width: size, height: size)
        .contentShape(.circle)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragging = true
                    var v = value.translation
                    let travel = radius - knob / 2
                    let length = (v.width * v.width + v.height * v.height).squareRoot()
                    if length > travel {
                        v.width *= travel / length
                        v.height *= travel / length
                    }
                    offset = v
                    onChange(Double(v.height / travel), Double(v.width / travel))
                }
                .onEnded { _ in
                    dragging = false
                    withAnimation(.spring(duration: 0.25, bounce: 0.3)) { offset = .zero }
                    onChange(0, 0)
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: dragging)
        .accessibilityElement()
        .accessibilityLabel("Control stick")
        .accessibilityValue("Pitch \(Int(Double(offset.height))), roll \(Int(Double(offset.width)))")
    }
}
