import SwiftUI

/// Glyphs SF Symbols does not have, drawn as filled shapes so they sit beside filled symbols
/// (flame.fill, parkingsign) at the same visual weight.
enum Glyph {
    case landingGear, flaps, spoilers

    /// Filled parts; `evenOdd` parts punch holes (a wheel's hub).
    func parts(in rect: CGRect) -> [(path: Path, evenOdd: Bool)] {
        let w = rect.width, h = rect.height
        let x = rect.minX, y = rect.minY
        func pt(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + w * px, y: y + h * py) }
        func box(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
            CGRect(x: x + w * x0, y: y + h * y0, width: w * (x1 - x0), height: h * (y1 - y0))
        }

        switch self {
        case .landingGear:
            // Side view: mounting beam, strut, and a tyre with its hub cut out.
            var mount = Path()
            mount.addRoundedRect(in: box(0.20, 0.02, 0.80, 0.14), cornerSize: CGSize(width: w * 0.05, height: w * 0.05))
            var strut = Path()
            strut.addRoundedRect(in: box(0.42, 0.08, 0.58, 0.50), cornerSize: CGSize(width: w * 0.04, height: w * 0.04))
            var tyre = Path()
            tyre.addEllipse(in: box(0.20, 0.40, 0.80, 1.00))
            tyre.addEllipse(in: box(0.38, 0.58, 0.62, 0.82))
            var axle = Path()
            axle.addEllipse(in: box(0.45, 0.65, 0.55, 0.75))
            return [(mount, false), (strut, false), (tyre, true), (axle, false)]

        case .flaps:
            // Airfoil, and the flap hinged down and aft of it.
            var wing = Path()
            wing.move(to: pt(0.02, 0.40))
            wing.addQuadCurve(to: pt(0.68, 0.40), control: pt(0.20, 0.08))
            wing.addQuadCurve(to: pt(0.02, 0.40), control: pt(0.26, 0.58))
            wing.closeSubpath()
            var flap = Path()
            flap.move(to: pt(0.70, 0.46))
            flap.addQuadCurve(to: pt(0.98, 0.86), control: pt(0.92, 0.50))
            flap.addLine(to: pt(0.90, 0.92))
            flap.addQuadCurve(to: pt(0.66, 0.56), control: pt(0.70, 0.66))
            flap.closeSubpath()
            return [(wing, false), (flap, false)]

        case .spoilers:
            // Airfoil, and a panel raised from its upper surface.
            var wing = Path()
            wing.move(to: pt(0.02, 0.70))
            wing.addQuadCurve(to: pt(0.98, 0.68), control: pt(0.30, 0.36))
            wing.addQuadCurve(to: pt(0.02, 0.70), control: pt(0.40, 0.88))
            wing.closeSubpath()
            var panel = Path()
            panel.move(to: pt(0.44, 0.56))
            panel.addLine(to: pt(0.74, 0.10))
            panel.addLine(to: pt(0.84, 0.16))
            panel.addLine(to: pt(0.58, 0.58))
            panel.closeSubpath()
            return [(wing, false), (panel, false)]
        }
    }
}

/// A `Glyph` rendered like an SF Symbol at a given point size, in the current foreground style.
struct GlyphView: View {
    let glyph: Glyph
    var size: CGFloat = 20

    var body: some View {
        Canvas { context, canvasSize in
            for part in glyph.parts(in: CGRect(origin: .zero, size: canvasSize)) {
                context.fill(part.path, with: .foreground, style: FillStyle(eoFill: part.evenOdd))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
