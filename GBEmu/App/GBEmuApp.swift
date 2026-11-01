import SwiftUI

@main
struct GBEmuApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(appState)
                .environment(appState.settings)
        }
    }
}
