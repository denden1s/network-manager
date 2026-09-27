import SwiftUI

/// Окно-поповер из menu-bar иконки: тогглы всех служб + статус.
struct ContentView: View {
    @ObservedObject var manager: NetworkManager
    @State private var dnsInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Network Manager")
                .font(.headline)

            // Все сетевые службы системы, у каждой свой on/off тоггл.
            ForEach(manager.services) { service in
                Toggle(isOn: Binding(
                    get: { service.enabled },
                    set: { newValue in
                        manager.setService(name: service.name, enabled: newValue)
                    }
                )) {
                    Label(service.name, systemImage: NetworkManager.isWiFiService(service.name) ? "wifi" : "cable.connector")
                }
                .toggleStyle(.switch)
            }

            Divider()

            // Текущий статус системы.
            Group {
                Text("Wi-Fi (\(manager.wifiDevice)): \(manager.wifiPowerOn ? "ON" : "OFF")")
                Text("IP: \(manager.ipAddress)")
                Text("Gateway: \(manager.gateway)")
                Text("Connected: \(manager.connectionInfo)")
                if let active = manager.services.first(where: { $0.enabled && !NetworkManager.isVPNService($0.name) }),
                   let dns = manager.currentDNS[active.name] {
                    Text("DNS (\(active.name)): \(dns)")
                }
            }
            .font(.caption)
            .textSelection(.enabled)

            Divider()

            // Ручной DNS для активной службы (первая включённая не-VPN).
            // Поле после Set/Auto НЕ очищается — статус обновится через refresh.
            Group {
                TextField("DNS через пробел, напр. 8.8.8.8 1.1.1.1", text: $dnsInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Set") {
                        let servers = dnsInput.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                        manager.applyDNSServers(servers)
                    }
                    .disabled(manager.isApplying)
                    Button("Auto") {
                        manager.applyAutoDNS()
                    }
                    .disabled(manager.isApplying)
                    Spacer()
                }
                if let active = manager.activeServiceName() {
                    Text("→ \(active)")
                        .foregroundColor(.secondary)
                } else {
                    Text("нет активной службы")
                        .foregroundColor(.secondary)
                }
            }
            .font(.caption)

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

            VStack(spacing: 8) {
                if !manager.passwordlessReady {
                    Button("Enable passwordless") { enablePasswordless() }
                        .disabled(manager.isApplying)
                        .help("Один раз спросит пароль, дальше Apply без промптов")
                        .frame(maxWidth: .infinity)
                }
                if manager.isApplying {
                    HStack {
                        Spacer()
                        ProgressView()
                            .scaleEffect(0.6)
                        Spacer()
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            manager.refresh()
        }
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
}
