import SwiftUI
import UI

@main
struct FlightApp: App {
    enum Screen { case menu, setup, flight }

    /// `-FlightStartScreen hud` opens straight into a flight, `setup` into free flight setup
    /// (used by scripts/verify.sh for screenshots).
    @State private var screen: Screen = FlightApp.launchScreen()

    private static func launchScreen() -> Screen {
        switch UserDefaults.standard.string(forKey: "FlightStartScreen") {
        case "hud": .flight
        case "setup": .setup
        default: .menu
        }
    }
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            Group {
                switch screen {
                case .menu:
                    MainMenuView { screen = .setup }
                        .transition(.opacity)
                case .setup:
                    FreeFlightSetupView(settings: settings, onStart: { screen = .flight }, onBack: { screen = .menu })
                        .transition(.opacity)
                case .flight:
                    FlightHUDView(settings: settings) { screen = .menu }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: screen)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        }
    }
}
