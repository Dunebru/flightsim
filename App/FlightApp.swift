import SwiftUI
import UI

@main
struct FlightApp: App {
    var body: some Scene {
        WindowGroup {
            MainMenuView()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
