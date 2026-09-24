import SwiftUI

@main
struct NetworkChangerApp: App {
    var body: some Scene {
        MenuBarExtra("Network Changer", systemImage: "network") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
