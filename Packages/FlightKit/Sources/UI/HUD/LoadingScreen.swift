import SwiftUI

/// Shown while an airport and its scenery are prepared: the place, quietly, and progress.
struct LoadingScreen: View {
    let airport: String
    let place: String

    var body: some View {
        ZStack {
            WorldPlaceholder().ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 10) {
                Text(airport)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(place)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(HUDStyle.secondaryText)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Loading scenery")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .glassEffect(HUDStyle.glass, in: .capsule)
                .padding(.top, 14)
            }
        }
    }
}
