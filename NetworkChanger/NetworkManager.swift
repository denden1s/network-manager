import Foundation
import Combine

/// Профиль сети: Work / Home.
enum NetworkProfile: String, CaseIterable, Identifiable {
    case work = "Work"
    case home = "Home"

    var id: String { rawValue }

    /// Имя macOS Network Location для проводной части.
    var locationName: String {
        switch self {
        case .work: return "ethernet_work"
        case .home: return "ethernet_home"
        }
    }

    /// DNS, применяемый ко ВСЕМ Wi-Fi сервисам в этом профиле.
    var wifiDNS: String {
        switch self {
        case .work: return "192.168.105.11"
        case .home: return "8.8.8.8"
        }
    }
}

enum NetworkManagerError: LocalizedError {
    case commandFailed(command: String, output: String)
    case cancelledByUser

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let output):
            return "Command failed: \(command)\n\(output)"
        case .cancelledByUser:
            return "Cancelled (administrator password was not entered)."
        }
    }
}

/// Снапшот состояния, собираемый в фоне и публикуемый на main.
struct NetworkStatus {
    var location: String = "…"
    var wifiDevice: String = "en0"
    var wifiPowerOn: Bool = false
    var wifiServices: [String] = []
    var dnsByService: [String: String] = [:]
}

/// Обёртка над `/usr/sbin/networksetup`.
/// Все чтения выполняются напрямую, все изменения — через
/// `osascript -e 'do shell script "..." with administrator privileges'`
/// (системный prompt пароля, без SMJobBless).
final class NetworkManager: ObservableObject {
    static let networksetup = "/usr/sbin/networksetup"
    static let osascript = "/usr/bin/osascript"

    @Published var currentLocation: String = "…"
    @Published var wifiDevice: String = "en0"
    @Published var wifiPowerOn: Bool = false
    @Published var wifiServices: [String] = []
    @Published var currentDNS: [String: String] = [:]
    @Published var isApplying: Bool = false
    @Published var lastError: String?
    @Published var lastSummary: String?

    // MARK: - Low-level execution

    /// Запуск networksetup БЕЗ привилегий. Возвращает stdout, при ненулевом exit-коде бросает.
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.networksetup)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NetworkManagerError.commandFailed(
                command: "networksetup \(arguments.joined(separator: " "))",
                output: (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Запуск произвольной shell-команды С привилегиями через системный prompt пароля.
    @discardableResult
    func runPrivileged(_ shellCommand: String) throws -> String {
        // Экранируем для двойных кавычек внутри AppleScript-строки.
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.osascript)
        process.arguments = ["-e", script]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            // Код -128 / "User canceled" — пользователь нажал Cancel в prompt'е.
            if err.contains("User canceled") || err.contains("-128") {
                throw NetworkManagerError.cancelledByUser
            }
            throw NetworkManagerError.commandFailed(
                command: shellCommand,
                output: (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Экранирование аргумента для sh (имена сервисов могут содержать пробелы).
    static func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Getters (без привилегий)

    /// `networksetup -getcurrentlocation` -> "ethernet_work" / "ethernet_home".
    func getCurrentLocation() throws -> String {
        let out = try run(["-getcurrentlocation"])
        // Вывод вида "Current set: ethernet_work" — забираем часть после двоеточия.
        if let colon = out.firstIndex(of: ":") {
            return out[out.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    /// Имя Wi-Fi устройства (обычно en0) из `networksetup -listallhardwareports`.
    func detectWiFiDevice() throws -> String {
        let out = try run(["-listallhardwareports"])
        var isWiFiPort = false
        for rawLine in out.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Hardware Port: Wi-Fi" || line == "Hardware Port: AirPort" {
                isWiFiPort = true
            } else if line.hasPrefix("Device: "), isWiFiPort {
                return line.replacingOccurrences(of: "Device: ", with: "")
            } else if line.hasPrefix("Hardware Port: ") {
                isWiFiPort = false
            }
        }
        return "en0" // fallback
    }

    /// `networksetup -getairportpower <device>` -> true = On.
    func getWiFiPower(device: String) throws -> Bool {
        let out = try run(["-getairportpower", device])
        // Вывод вида "Wi-Fi Power (en0): On"
        return out.localizedCaseInsensitiveContains(": On")
    }

    /// Все включённые сервисы из `networksetup -listallnetworkservices`
    /// (строки с `*` — отключённые, пропускаем).
    func getAllServices() throws -> [String] {
        let out = try run(["-listallnetworkservices"])
        var result: [String] = []
        for rawLine in out.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") { continue } // отключённый сервис
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("An asterisk") { continue } // пояснение networksetup
            result.append(line)
        }
        return result
    }

    /// Подмножество сервисов, являющихся Wi-Fi (имя содержит Wi-Fi / AirPort).
    func getWiFiServices() throws -> [String] {
        return try getAllServices().filter {
            $0.localizedCaseInsensitiveContains("wi-fi")
                || $0.localizedCaseInsensitiveContains("airport")
        }
    }

    /// `networksetup -getdnsservers <service>` (сырой вывод).
    func getDNS(service: String) throws -> String {
        return try run(["-getdnsservers", service])
    }

    // MARK: - Setters (с привилегиями, через системный prompt)

    /// `networksetup -switchtolocation <location>` (sudo).
    func switchLocation(_ location: String) throws {
        try runPrivileged("\(Self.networksetup) -switchtolocation \(Self.shellQuote(location))")
    }

    /// `networksetup -setairportpower <device> on|off` (sudo).
    func setWiFiPower(device: String, on: Bool) throws {
        let state = on ? "on" : "off"
        try runPrivileged("\(Self.networksetup) -setairportpower \(device) \(state)")
    }

    /// `networksetup -setdnsservers <service> <dns>` (sudo).
    func setDNS(service: String, dns: String) throws {
        try runPrivileged("\(Self.networksetup) -setdnsservers \(Self.shellQuote(service)) \(dns)")
    }

    // MARK: - High-level logic

    /// Обновить статус (вызывать из UI). Тяжёлая работа — в фоне.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var status = NetworkStatus()
            var failure: String?
            do {
                status.wifiDevice = try self.detectWiFiDevice()
                status.location = try self.getCurrentLocation()
                status.wifiPowerOn = try self.getWiFiPower(device: status.wifiDevice)
                status.wifiServices = try self.getWiFiServices()
                for service in status.wifiServices {
                    status.dnsByService[service] = (try? self.getDNS(service: service)) ?? "?"
                }
            } catch {
                failure = error.localizedDescription
            }
            let capturedStatus = status
            let capturedFailure = failure
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.wifiDevice = capturedStatus.wifiDevice
                self.currentLocation = capturedStatus.location
                self.wifiPowerOn = capturedStatus.wifiPowerOn
                self.wifiServices = capturedStatus.wifiServices
                self.currentDNS = capturedStatus.dnsByService
                self.lastError = capturedFailure
            }
        }
    }

    /// Применить комбинацию профиль + Wi-Fi:
    /// - Work + WiFi ON:  switchtolocation ethernet_work + power on + DNS 192.168.105.11 на все Wi-Fi сервисы
    /// - Home + WiFi ON:  switchtolocation ethernet_home + power on + DNS 8.8.8.8 на все Wi-Fi сервисы
    /// - WiFi OFF (любой): power off + switchtolocation соответствующего Location
    func apply(profile: NetworkProfile, wifiOn: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isApplying = true
            self?.lastError = nil
            self?.lastSummary = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var failure: String?
            var summary: String?
            do {
                // 1. Проводная часть: Location переключаем всегда.
                try self.switchLocation(profile.locationName)
                // 2. Питание Wi-Fi.
                let device = (try? self.detectWiFiDevice()) ?? "en0"
                try self.setWiFiPower(device: device, on: wifiOn)
                // 3. DNS — только когда Wi-Fi включён, на ВСЕ Wi-Fi сервисы.
                var dnsTargets: [String] = []
                if wifiOn {
                    for service in try self.getWiFiServices() {
                        try self.setDNS(service: service, dns: profile.wifiDNS)
                        dnsTargets.append(service)
                    }
                }
                if wifiOn {
                    summary = "Applied: \(profile.locationName) + Wi-Fi ON (\(device)), DNS \(profile.wifiDNS) → \(dnsTargets.joined(separator: ", "))"
                } else {
                    summary = "Applied: \(profile.locationName) + Wi-Fi OFF (\(device))"
                }
            } catch {
                failure = error.localizedDescription
            }
            let capturedFailure = failure
            let capturedSummary = summary
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isApplying = false
                self.lastError = capturedFailure
                self.lastSummary = capturedSummary
                self.refresh()
            }
        }
    }
}
