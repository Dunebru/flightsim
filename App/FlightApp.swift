import SwiftUI
import UI

@main
struct FlightApp: App {
    /// `-FlightStartScreen hud` on the launch arguments opens straight into the HUD
    /// (used by scripts/verify.sh to screenshot it).
    @State private var inFlight = UserDefaults.standard.string(forKey: "FlightStartScreen") == "hud"

    var body: some Scene {
        WindowGroup {
            Group {
                if inFlight {
                    FlightHUDView { inFlight = false }
                        .transition(.opacity)
                } else {
                    MainMenuView { inFlight = true }
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: inFlight)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        }
    }
}
