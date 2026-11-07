import SwiftUI
import CoreText

/// Design language: "glass cockpit".
///
/// The look comes from real avionics rather than from any app: dark bezels that let the outside
/// view through, hairline borders, square-shouldered shapes, and the industry color convention
/// pilots already read without thinking (cyan = selected by the pilot, green = engaged/active,
/// magenta = route, amber = caution, red = warning). Type is B612, the open-license face Airbus
/// designed for cockpit displays. Its figures are tabular (every digit is 0.65 em, measured), so
/// changing values never jitter, while its punctuation stays narrow.
enum Palette {
    /// Bezel fill behind every control. Opaque enough for legibility over a bright sky,
    /// transparent enough that the world stays visible.
    static let bezel = Color.black.opacity(0.62)
    static let bezelPressed = Color.black.opacity(0.78)
    /// Panel windows sit over other controls on small phones, so they are nearly opaque.
    static let panelFill = Color(red: 0.05, green: 0.055, blue: 0.06).opacity(0.94)
    static let hairline = Color.white.opacity(0.16)
    static let hairlineStrong = Color.white.opacity(0.32)

    static let textPrimary = Color(red: 0.95, green: 0.96, blue: 0.96)
    static let textSecondary = Color(red: 0.62, green: 0.66, blue: 0.69)
    static let textTertiary = Color(red: 0.42, green: 0.45, blue: 0.48)

    /// Pilot-selected targets (autopilot speed, heading, altitude).
    static let selected = Color(red: 0.25, green: 0.82, blue: 0.93)
    /// Engaged modes, healthy states, gear down and locked.
    static let active = Color(red: 0.30, green: 0.86, blue: 0.44)
    /// Flight plan route and FMS-managed values.
    static let route = Color(red: 0.88, green: 0.36, blue: 0.95)
    /// Caution: reverse thrust, parking brake set, spoilers extended.
    static let caution = Color(red: 1.00, green: 0.69, blue: 0.13)
    /// Warning: gear in transit, stall.
    static let warning = Color(red: 1.00, green: 0.30, blue: 0.30)
}

/// B612 type ramp. Labels are uppercase with open tracking; values use the tabular figures.
public enum Typeface {
    static func label(_ size: CGFloat = 9) -> Font { .custom("B612-Bold", fixedSize: size) }
    static func text(_ size: CGFloat = 13) -> Font { .custom("B612-Regular", fixedSize: size) }
    static func title(_ size: CGFloat = 13) -> Font { .custom("B612-Bold", fixedSize: size) }
    static func value(_ size: CGFloat = 19) -> Font { .custom("B612-Regular", fixedSize: size) }
    static func valueBold(_ size: CGFloat = 19) -> Font { .custom("B612-Bold", fixedSize: size) }

    /// Tracking for uppercase labels, in points.
    static let labelTracking: CGFloat = 1.1

    /// Registers the bundled B612 fonts with the process. Call once at launch.
    /// Returns the number of font files that failed to register (0 on success).
    @discardableResult
    public static func registerBundledFonts() -> Int {
        let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        var failures = urls.isEmpty ? 1 : 0
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (e.g. a second scene) is fine; anything else is a failure.
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue { failures += 1 }
            }
        }
        return failures
    }
}

/// Spacing and sizing, in points. Touch targets never go below 44 pt.
enum Metrics {
    static let edge: CGFloat = 12
    static let gap: CGFloat = 8
    static let corner: CGFloat = 6
    static let touch: CGFloat = 44
    static let toolbarHeight: CGFloat = 40
}

extension View {
    /// The standard bezel: dark translucent fill with a hairline border.
    func bezel(corner: CGFloat = Metrics.corner, pressed: Bool = false) -> some View {
        background(pressed ? Palette.bezelPressed : Palette.bezel, in: .rect(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    /// Uppercase label styling.
    func labelStyle(_ color: Color = Palette.textSecondary, size: CGFloat = 9) -> some View {
        font(Typeface.label(size)).tracking(Typeface.labelTracking).foregroundStyle(color)
    }
}
