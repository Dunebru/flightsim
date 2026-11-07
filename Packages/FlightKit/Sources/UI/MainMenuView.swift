public import SwiftUI

/// Main menu. Placeholder: Free Flight opens the HUD prototype directly; setup screens (aircraft,
/// livery, airport, gate, weight, time, weather) and the other destinations arrive in M3 and later.
public struct MainMenuView: View {
    private let onFreeFlight: () -> Void

    public init(onFreeFlight: @escaping () -> Void = {}) {
        self.onFreeFlight = onFreeFlight
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            WorldPlaceholder().ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Flight")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                    Text("Placeholder menu")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)

                Button(action: onFreeFlight) {
                    Label("Free Flight", systemImage: "airplane.departure")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(.white)
                .foregroundStyle(.black)

                GlassEffectContainer {
                    HStack(spacing: 8) {
                        later("Flight Plan", "point.topleft.down.to.point.bottomright.curvepath")
                        later("Hangar", "airplane")
                        later("Logbook", "book.closed")
                        later("Settings", "gearshape")
                    }
                }
                Text("Flight Plan, Hangar, Logbook and Settings arrive in later milestones.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .preferredColorScheme(.dark)
    }

    private func later(_ title: String, _ symbol: String) -> some View {
        Button {} label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(height: 44)
        }
        .buttonStyle(.glass)
        .disabled(true)
    }
}

#if os(iOS)
#Preview(traits: .landscapeLeft) {
    MainMenuView()
}
#endif
