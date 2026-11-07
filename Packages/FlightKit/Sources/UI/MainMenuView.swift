public import SwiftUI

/// Main menu. Placeholder: Free Flight opens the HUD prototype directly; the setup screens
/// (aircraft, livery, airport, gate, weight, time, weather) and the other entries arrive in M3.
public struct MainMenuView: View {
    private let onFreeFlight: () -> Void

    public init(onFreeFlight: @escaping () -> Void = {}) {
        self.onFreeFlight = onFreeFlight
    }

    private struct Item: Identifiable {
        let title: String
        let detail: String
        let enabled: Bool
        var id: String { title }
    }

    private let items: [Item] = [
        Item(title: "FREE FLIGHT", detail: "HUD prototype", enabled: true),
        Item(title: "FLIGHT PLAN", detail: "M8", enabled: false),
        Item(title: "HANGAR", detail: "M6", enabled: false),
        Item(title: "LOGBOOK", detail: "M10", enabled: false),
        Item(title: "SETTINGS", detail: "M3", enabled: false),
    ]

    public var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.045).ignoresSafeArea()

            HStack(alignment: .center, spacing: 56) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FLIGHT")
                        .font(Typeface.title(40))
                        .tracking(8)
                        .foregroundStyle(Palette.textPrimary)
                    Rectangle().fill(Palette.selected).frame(width: 40, height: 3)
                    Text("PLACEHOLDER MENU · M0")
                        .labelStyle(Palette.textTertiary, size: 9)
                }
                .frame(maxWidth: 280, alignment: .leading)

                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            if item.enabled { onFreeFlight() }
                        } label: {
                            HStack {
                                Text(item.title)
                                    .labelStyle(item.enabled ? Palette.textPrimary : Palette.textTertiary, size: 13)
                                Spacer()
                                Text(item.detail)
                                    .labelStyle(item.enabled ? Palette.selected : Palette.textTertiary, size: 9)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(item.enabled ? Palette.textSecondary : Palette.textTertiary.opacity(0.5))
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.enabled)
                        if item.id != items.last?.id {
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                        }
                    }
                }
                .frame(maxWidth: 360)
                .bezel()
            }
            .padding(40)
        }
        .preferredColorScheme(.dark)
    }
}

#if os(iOS)
#Preview(traits: .landscapeLeft) {
    let _ = Typeface.registerBundledFonts()
    MainMenuView()
}
#endif
