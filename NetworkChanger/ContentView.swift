import SwiftUI

/// Окно-поповер из menu-bar иконки: два Toggle + статус + Apply.
struct ContentView: View {
    @ObservedObject var manager: NetworkManager
    @State private var profile: NetworkProfile = .work
    @State private var wifiOn: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Changer")
                .font(.headline)

            // Toggle 1 — профиль сети (авто-применение при смене).
            Picker("Network", selection: Binding(
                get: { profile },
                set: { newValue in
                    profile = newValue
                    apply()
                }
            )) {
                Text("Work").tag(NetworkProfile.work)
                Text("Home").tag(NetworkProfile.home)
            }
            .pickerStyle(.segmented)

            // Toggle 2 — Wi-Fi ON/OFF (авто-применение при смене).
            Toggle("Wi-Fi", isOn: Binding(
                get: { wifiOn },
                set: { newValue in
                    wifiOn = newValue
                    apply()
                }
            ))
            .toggleStyle(.switch)
            .help(wifiOn
                ? "Wi-Fi включён: Location + Wi-Fi + DNS профиля"
                : "Wi-Fi выключен: активен Ethernet через текущий Location")

            Divider()

            // Текущий статус системы.
            Group {
                Text("Location: \(manager.currentLocation)")
                Text("Wi-Fi (\(manager.wifiDevice)): \(manager.wifiPowerOn ? "ON" : "OFF")")
                if manager.wifiServices.isEmpty {
                    Text("Wi-Fi services: none found")
                } else {
                    ForEach(manager.wifiServices, id: \.self) { service in
                        Text("DNS \(service): \(manager.currentDNS[service] ?? "?")")
                    }
                }
            }
            .font(.caption)
            .textSelection(.enabled)

            if let error = manager.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if let summary = manager.lastSummary {
                Text(summary)
                    .foregroundColor(.green)
                    .font(.caption)
            }

            HStack {
                Button("Apply") { apply() }
                    .disabled(manager.isApplying)
                    .keyboardShortcut(.defaultAction)
                Button("Refresh") { manager.refresh() }
                    .disabled(manager.isApplying)
                Spacer()
                if manager.isApplying {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            manager.refresh()
        }
    }

    private func apply() {
        manager.apply(profile: profile, wifiOn: wifiOn)
    }
}
