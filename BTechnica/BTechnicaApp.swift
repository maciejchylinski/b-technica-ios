import SwiftUI

@main
struct BTechnicaApp: App {
    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            AppGateView()
                .environmentObject(auth)
                .tint(Theme.blue)
        }
    }
}
