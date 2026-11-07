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
    /// Values the pilot selected (autopilot targets).
    static let selected = Color.cyan

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
    static let caption = Font.system(size: 11, weight: .medium)
}

extension View {
    /// Keeps white text legible over bright sky without a container.
    func overWorldLegibility() -> some View {
        shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
