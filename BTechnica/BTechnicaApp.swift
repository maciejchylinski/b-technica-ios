import SwiftUI

@main
struct BTechnicaApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .tint(Theme.blue)
        }
    }
}
