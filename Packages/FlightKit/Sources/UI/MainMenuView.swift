public import SwiftUI

/// Main menu. Placeholder (M0): layout and styling are not yet the Infinite Flight style;
/// M3 rebuilds every screen against reference screenshots. Buttons are inert.
public struct MainMenuView: View {
    public init() {}

    private let items: [(title: String, symbol: String)] = [
        ("Free Flight", "airplane.departure"),
        ("Flight Plan", "point.topleft.down.to.point.bottomright.curvepath"),
        ("Hangar", "airplane"),
        ("Logbook", "book.closed"),
        ("Settings", "gearshape"),
    ]

    public var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.02)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            HStack(alignment: .center, spacing: 48) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Flight")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Placeholder menu (M0)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260, alignment: .leading)

                VStack(spacing: 10) {
                    ForEach(items, id: \.title) { item in
                        Button {} label: {
                            HStack(spacing: 14) {
                                Image(systemName: item.symbol)
                                    .frame(width: 28)
                                Text(item.title)
                            }
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 340)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

#Preview(traits: .landscapeLeft) {
    MainMenuView()
}
