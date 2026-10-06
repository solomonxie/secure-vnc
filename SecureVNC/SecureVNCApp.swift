import SwiftUI

@main
struct SecureVNCApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            HostsView()
                .environmentObject(store)
        }
    }
}
