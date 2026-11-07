import SwiftUI

/// Glyphs SF Symbols does not have, drawn to sit beside them: round caps and joins, stroke
/// width proportional to size like a medium-weight symbol.
enum Glyph {
    case landingGear, flaps, spoilers

    func shape(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x = rect.minX, y = rect.minY
        var p = Path()
        switch self {
        case .landingGear:
            // Main gear seen from the front: strut, axle, two tyres.
            p.move(to: CGPoint(x: x + w * 0.50, y: y + h * 0.06))
            p.addLine(to: CGPoint(x: x + w * 0.50, y: y + h * 0.58))
            p.move(to: CGPoint(x: x + w * 0.28, y: y + h * 0.66))
            p.addLine(to: CGPoint(x: x + w * 0.72, y: y + h * 0.66))
            p.addRoundedRect(in: CGRect(x: x + w * 0.08, y: y + h * 0.42, width: w * 0.22, height: h * 0.50),
                             cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
            p.addRoundedRect(in: CGRect(x: x + w * 0.70, y: y + h * 0.42, width: w * 0.22, height: h * 0.50),
                             cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
        case .flaps:
            // Airfoil with a flap hinged down behind its trailing edge.
            p.move(to: CGPoint(x: x + w * 0.06, y: y + h * 0.44))
            p.addQuadCurve(to: CGPoint(x: x + w * 0.64, y: y + h * 0.42), control: CGPoint(x: x + w * 0.24, y: y + h * 0.14))
            p.addQuadCurve(to: CGPoint(x: x + w * 0.06, y: y + h * 0.44), control: CGPoint(x: x + w * 0.30, y: y + h * 0.60))
            p.closeSubpath()
            p.move(to: CGPoint(x: x + w * 0.70, y: y + h * 0.50))
            p.addLine(to: CGPoint(x: x + w * 0.94, y: y + h * 0.84))
        case .spoilers:
            // Airfoil with a panel raised from its upper surface.
            p.move(to: CGPoint(x: x + w * 0.04, y: y + h * 0.66))
            p.addQuadCurve(to: CGPoint(x: x + w * 0.96, y: y + h * 0.64), control: CGPoint(x: x + w * 0.34, y: y + h * 0.34))
            p.addQuadCurve(to: CGPoint(x: x + w * 0.04, y: y + h * 0.66), control: CGPoint(x: x + w * 0.40, y: y + h * 0.80))
            p.closeSubpath()
            p.move(to: CGPoint(x: x + w * 0.50, y: y + h * 0.48))
            p.addLine(to: CGPoint(x: x + w * 0.82, y: y + h * 0.14))
        }
        return p
    }
}

/// A `Glyph` rendered like an SF Symbol at a given point size.
struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            let path = glyph.shape(in: CGRect(origin: .zero, size: canvasSize))
            context.stroke(
                path,
                with: .foreground,
                style: StrokeStyle(lineWidth: max(1.6, size * 0.095), lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
