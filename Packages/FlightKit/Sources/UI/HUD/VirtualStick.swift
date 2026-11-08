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
                .hudSurface(in: .circle)
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

/// The rudder: a horizontal slider that springs back to centre when you let go, as rudder
/// pedals do. Left of centre is left rudder (and nosewheel left on the ground).
struct RudderSlider: View {
    /// Output: -1 full left ... 1 full right.
    let onChange: (Double) -> Void
    var width: CGFloat = 240

    @State private var offset: CGFloat = 0
    @State private var centred = true

    var body: some View {
        let knob: CGFloat = 34
        let travel = (width - knob) / 2 - 4
        ZStack {
            Capsule()
                .fill(.clear)
                .hudSurface(in: .capsule)
            // Centre mark.
            Rectangle()
                .fill(.white.opacity(0.35))
                .frame(width: 1.5, height: 14)
            Capsule()
                .fill(.white)
                .frame(width: knob, height: 26)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                .offset(x: offset)
        }
        .frame(width: width, height: 36)
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    offset = max(-travel, min(travel, value.translation.width))
                    centred = abs(offset) < 2
                    onChange(Double(offset / travel))
                }
                .onEnded { _ in
                    withAnimation(.spring(duration: 0.25, bounce: 0.2)) { offset = 0 }
                    centred = true
                    onChange(0)
                }
        )
        .sensoryFeedback(.selection, trigger: centred) { _, now in now }
        .accessibilityElement()
        .accessibilityLabel("Rudder")
        .accessibilityValue(offset == 0 ? "Centred" : (offset < 0 ? "Left" : "Right"))
    }
}
