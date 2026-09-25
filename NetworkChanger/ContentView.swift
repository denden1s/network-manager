import SwiftUI
import AppKit

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

            // Toggle 2 — только вкл/выкл питания Wi-Fi (без Location и DNS).
            Toggle("Wi-Fi", isOn: Binding(
                get: { wifiOn },
                set: { newValue in
                    wifiOn = newValue
                    manager.applyWiFiOnly(on: newValue)
                }
            ))
            .toggleStyle(.switch)
            .help("Только включает/выключает Wi-Fi")

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
                Text("Connected: \(manager.connectionInfo)")
                if manager.lastScan.isEmpty {
                    Text("Nearby: 0")
                } else {
                    Text("Nearby: \(manager.lastScan.count) (\(manager.lastScan.joined(separator: ", ")))")
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
                if !manager.passwordlessReady {
                    Button("Enable passwordless") { enablePasswordless() }
                        .disabled(manager.isApplying)
                        .help("Один раз спросит пароль, дальше Apply без промптов")
                }
                Spacer()
                if manager.isApplying {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            HStack {
                Button("Copy Diagnostics") { copyDiagnostics() }
                Spacer()
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            manager.refresh()
        }
        .onReceive(manager.$wifiPowerOn) { wifiOn = $0 }
    }

    private func apply() {
        manager.apply(profile: profile, wifiOn: wifiOn)
    }

    private func enablePasswordless() {
        manager.isApplying = true
        manager.lastError = nil
        manager.lastSummary = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let out = try manager.installPasswordless()
                let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    manager.isApplying = false
                    manager.lastSummary = text.isEmpty ? "Passwordless sudo installed." : text
                    manager.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    manager.isApplying = false
                    manager.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    manager.refresh()
                }
            }
        }
    }

    private func copyDiagnostics() {
        var lines: [String] = []
        lines.append("Service: \(manager.currentLocation)")
        lines.append("Wi-Fi (\(manager.wifiDevice)): \(manager.wifiPowerOn ? "ON" : "OFF")")
        lines.append("Connected: \(manager.connectionInfo)")
        if manager.wifiServices.isEmpty {
            lines.append("Wi-Fi services: none found")
        } else {
            for service in manager.wifiServices {
                lines.append("DNS \(service): \(manager.currentDNS[service] ?? "?")")
            }
        }
        if manager.lastScan.isEmpty {
            lines.append("Nearby: 0")
        } else {
            lines.append("Nearby: \(manager.lastScan.count) (\(manager.lastScan.joined(separator: ", ")))")
        }
        lines.append("Error: \(manager.lastError ?? "none")")
        lines.append("Summary: \(manager.lastSummary ?? "none")")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
