import SwiftUI

/// The HUD speaks Apple's platform language: Liquid Glass over the world, SF Pro Rounded
/// numerals, SF Symbols, and semantic colors with fixed meanings across every control.
enum HUDStyle {
    /// Engaged automation and healthy state (autopilot on, gear down and locked).
    static let engaged = Color.green
    /// Caution: reverse thrust, parking brake set, gear in transit, spoilers deployed.
    static let caution = Color.orange
    /// Warning: stall, gear unsafe.
    static let warning = Color.red
    /// Values the pilot selected (autopilot targets). Cyan, not system blue: it is the cockpit
    /// convention for selected targets (PRODUCT.md principle 4), and blue disappears against sky.
    static let selected = Color.cyan
    /// The active route on the map: magenta, as on every navigation display.
    static let route = Color(red: 1.0, green: 0.25, blue: 0.85)
    /// Secondary labels over glass.
    static let secondaryText = Color.white.opacity(0.9)

    /// HUD glass carries a light smoke tint: over a bright sky, untinted glass cannot hold
    /// 4.5:1 for small white labels (measured 2.98:1 in review).
    static let glass = Glass.regular.tint(Color.black.opacity(0.28))
    static let glassInteractive = Glass.regular.tint(Color.black.opacity(0.28)).interactive()

    /// Fill of a Control Center-style slider.
    static let sliderFill = Color.white

    static let edge: CGFloat = 16
    static let gap: CGFloat = 10
    static let circle: CGFloat = 52
    static let sliderCorner: CGFloat = 22

    static func metric(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    static let unit = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let caption = Font.system(size: 12, weight: .semibold)
}

extension View {
    /// Keeps white text legible over bright sky without a container.
    func overWorldLegibility() -> some View {
        shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}

extension View {
    /// The always-on flight HUD's surface: a translucent dark fill with a hairline edge, as
    /// mobile flight sims draw theirs. Not Liquid Glass: glass re-blurs the live 3D view under
    /// every control each frame, which cost the phone about 5 ms of GPU time (measured with the
    /// HUD shown and hidden: 45 fps against 60). Panels and menus, open briefly, keep the glass.
    func hudSurface<S: Shape>(in shape: S) -> some View {
        background {
            shape.fill(Color.black.opacity(0.38))
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}
