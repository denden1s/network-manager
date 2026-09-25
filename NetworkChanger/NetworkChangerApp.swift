import SwiftUI

@main
struct NetworkChangerApp: App {
    @StateObject private var manager = NetworkManager()

    var body: some Scene {
        MenuBarExtra("Network Changer", systemImage: manager.wifiPowerOn ? "wifi" : "cable.connector") {
            ContentView(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}
