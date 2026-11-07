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
                Text("Flight")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
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

                Text("Placeholder menu. Flight plans, the hangar, the logbook and settings arrive in later milestones.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .preferredColorScheme(.dark)
    }

}

#if os(iOS)
#Preview(traits: .landscapeLeft) {
    MainMenuView()
}
#endif
