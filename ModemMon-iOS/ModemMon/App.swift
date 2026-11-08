import SwiftUI

@main
struct ModemMonApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(.accentColor)
        }
    }
}
