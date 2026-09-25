import Foundation
import Combine

/// Профиль сети: Work / Home.
enum NetworkProfile: String, CaseIterable, Identifiable {
    case work = "Work"
    case home = "Home"

    var id: String { rawValue }

    /// Имя проводной сетевой службы (networkservice).
    var ethernetServiceName: String {
        switch self {
        case .work: return "ethernet-work"
        case .home: return "ethernet-home"
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
    case commandFailed(command: String, exitCode: Int32, output: String)
    case cancelledByUser
    case locationNotFound(name: String)
    case serviceNotFound(name: String, available: [String])
    case verificationFailed(step: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let exitCode, let output):
            return "Command failed (exit \(exitCode)): \(command)\n\(output)"
        case .cancelledByUser:
            return "Cancelled (administrator password was not entered)."
        case .locationNotFound(let name):
            return "Location '\(name)' not found. Create it in System Settings → Network → Locations."
        case .serviceNotFound(let name, let available):
            return "Service '\(name)' not found. Available: \(available.joined(separator: ", "))"
        case .verificationFailed(let step, let expected, let actual):
            return "Verification failed after '\(step)': expected '\(expected)', got '\(actual)'."
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
    var connectionInfo: String = "unknown"
}

/// Обёртка над `/usr/sbin/networksetup`.
/// Все чтения выполняются напрямую, все изменения — через
/// `osascript -e 'do shell script "..." with administrator privileges'`
/// (системный prompt пароля, без SMJobBless).
final class NetworkManager: ObservableObject {
    static let networksetup = "/usr/sbin/networksetup"
    static let osascript = "/usr/bin/osascript"
    static let airportCLI = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

    @Published var currentLocation: String = "…"
    @Published var wifiDevice: String = "en0"
    @Published var wifiPowerOn: Bool = false
    @Published var wifiServices: [String] = []
    @Published var currentDNS: [String: String] = [:]
    @Published var isApplying: Bool = false
    @Published var lastError: String?
    @Published var lastSummary: String?
    @Published var lastScan: [String] = []
    @Published var connectionInfo: String = "unknown"

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
                exitCode: process.terminationStatus,
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
        let status = process.terminationStatus
        if status != 0 {
            // Код -128 / "User canceled" — пользователь нажал Cancel в prompt'е.
            // osascript пишет текст ошибки в stderr — он уже захвачен в `err` выше.
            if err.contains("User canceled") || err.contains("-128") {
                throw NetworkManagerError.cancelledByUser
            }
            throw NetworkManagerError.commandFailed(
                command: shellCommand,
                exitCode: status,
                output: (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Экранирование аргумента для sh (имена сервисов могут содержать пробелы).
    static func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Фоновый скан Wi-Fi сетей (`airport -s`). Best-effort: при любой ошибке
    /// возвращает [] и НЕ валит apply. Требует включённый радиомодуль,
    /// иначе список пуст. Deprecation-warning `airport` уходит в stderr и игнорируется.
    func scanWiFi() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.airportCLI)
        process.arguments = ["-s"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // SSID может содержать пробелы, поэтому режем строку по BSSID (MAC),
        // а не по пробелам. Строка-заголовок ("SSID BSSID ...") MAC не содержит и пропускается.
        guard let macRegex = try? NSRegularExpression(pattern: "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}") else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in out.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = macRegex.firstMatch(in: line, range: range),
                  let macRange = Range(match.range, in: line) else { continue }
            let ssid = String(line[..<macRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !ssid.isEmpty, !seen.contains(ssid) {
                seen.insert(ssid)
                result.append(ssid)
            }
        }
        return result
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

    /// `networksetup -listlocations` -> все существующие Locations.
    func listLocations() throws -> [String] {
        let out = try run(["-listlocations"])
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    /// Все сервисы из `networksetup -listallnetworkservices`,
    /// ВКЛЮЧАЯ отключённые (строки с `*` — префикс снимаем, сервис сохраняем).
    func getAllServices() throws -> [String] {
        let out = try run(["-listallnetworkservices"])
        var result: [String] = []
        for rawLine in out.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
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

    /// `networksetup -getnetworkserviceenabled <service>` -> true = Enabled.
    /// Вывод вида "Enabled" / "Disabled".
    func getServiceEnabled(_ service: String) throws -> Bool {
        let out = try run(["-getnetworkserviceenabled", service])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("Disabled") { return false }
        return trimmed.localizedCaseInsensitiveContains("Enabled")
    }

    /// Какая из двух ethernet-служб сейчас активна (enabled).
    func getActiveEthernetService() throws -> String {
        let workOn = try getServiceEnabled(NetworkProfile.work.ethernetServiceName)
        let homeOn = try getServiceEnabled(NetworkProfile.home.ethernetServiceName)
        switch (workOn, homeOn) {
        case (true, false): return NetworkProfile.work.ethernetServiceName
        case (false, true): return NetworkProfile.home.ethernetServiceName
        case (true, true): return "both enabled"
        case (false, false): return "none enabled"
        }
    }

    /// Сводка подключения БЕЗ привилегий, НЕ бросает (внутри try? + fallback "unknown"):
    /// SSID через `networksetup -getairportnetwork <device>` (сырой вывод как есть)
    /// + IP через `networksetup -getinfo <первый wifi-сервис>` (строка "IP address:").
    func getConnectionSummary() -> String {
        var ssid = "unknown"
        var ip = "unknown"
        let device = (try? detectWiFiDevice()) ?? "en0"
        if let out = try? run(["-getairportnetwork", device]) {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ssid = trimmed }
        }
        if let service = (try? getWiFiServices())?.first,
           let info = try? run(["-getinfo", service]) {
            for rawLine in info.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("IP address:") {
                    let value = line
                        .replacingOccurrences(of: "IP address:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { ip = value }
                    break
                }
            }
        }
        return "\(ssid), IP \(ip)"
    }

    // MARK: - Setters (с привилегиями, через системный prompt)

    /// `networksetup -switchtolocation <location>` (sudo).
    func switchLocation(_ location: String) throws {
        try runPrivileged("\(Self.networksetup) -switchtolocation \(Self.shellQuote(location))")
    }

    /// `networksetup -setnetworkserviceenabled <service> on|off` (sudo).
    func setServiceEnabled(_ service: String, enabled: Bool) throws {
        let state = enabled ? "on" : "off"
        try runPrivileged("\(Self.networksetup) -setnetworkserviceenabled \(Self.shellQuote(service)) \(state)")
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

    /// Сброс DNS-кэша после смены DNS (sudo):
    /// `dscacheutil -flushcache; killall -HUP mDNSResponder`.
    func flushDNS() throws {
        try runPrivileged("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
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
                status.location = try self.getActiveEthernetService()
                status.wifiPowerOn = try self.getWiFiPower(device: status.wifiDevice)
                status.wifiServices = try self.getWiFiServices()
                for service in status.wifiServices {
                    status.dnsByService[service] = (try? self.getDNS(service: service)) ?? "?"
                }
                status.connectionInfo = self.getConnectionSummary()
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
                self.connectionInfo = capturedStatus.connectionInfo
                self.lastError = capturedFailure
            }
        }
    }

    /// Применить комбинацию профиль + Wi-Fi:
    /// - Work + WiFi ON:  enable ethernet-work / disable ethernet-home + power on + DNS 192.168.105.11 на все Wi-Fi сервисы
    /// - Home + WiFi ON:  enable ethernet-home / disable ethernet-work + power on + DNS 8.8.8.8 на все Wi-Fi сервисы
    /// - WiFi OFF (любой): power off + переключение ethernet-служб
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
            var scan: [String] = []
            do {
                // 0. Проверка существования служб ДО переключения.
                let mine = profile.ethernetServiceName
                let other = (profile == .work ? NetworkProfile.home : NetworkProfile.work).ethernetServiceName
                let services = try self.getAllServices()
                guard services.contains(mine) else {
                    throw NetworkManagerError.serviceNotFound(name: mine, available: services)
                }
                guard services.contains(other) else {
                    throw NetworkManagerError.serviceNotFound(name: other, available: services)
                }
                // 1. Проводная часть: свою службу включаем, чужую выключаем + верификация обеих.
                try self.setServiceEnabled(mine, enabled: true)
                try self.setServiceEnabled(other, enabled: false)
                // Применение не мгновенное — даём системе время.
                Thread.sleep(forTimeInterval: 0.5)
                let mineOn = try self.getServiceEnabled(mine)
                guard mineOn else {
                    throw NetworkManagerError.verificationFailed(
                        step: "enable service '\(mine)'",
                        expected: "Enabled",
                        actual: "Disabled"
                    )
                }
                let otherOn = try self.getServiceEnabled(other)
                guard !otherOn else {
                    throw NetworkManagerError.verificationFailed(
                        step: "disable service '\(other)'",
                        expected: "Disabled",
                        actual: "Enabled"
                    )
                }
                // 2. Питание Wi-Fi + верификация.
                let device = (try? self.detectWiFiDevice()) ?? "en0"
                try self.setWiFiPower(device: device, on: wifiOn)
                let actualPower = try self.getWiFiPower(device: device)
                guard actualPower == wifiOn else {
                    throw NetworkManagerError.verificationFailed(
                        step: "set Wi-Fi power \(wifiOn ? "on" : "off") (\(device))",
                        expected: wifiOn ? "On" : "Off",
                        actual: actualPower ? "On" : "Off"
                    )
                }
                // 3. DNS — только когда Wi-Fi включён, на ВСЕ Wi-Fi сервисы + верификация + flush.
                var dnsTargets: [String] = []
                if wifiOn {
                    for service in try self.getWiFiServices() {
                        try self.setDNS(service: service, dns: profile.wifiDNS)
                        let actualDNS = (try? self.getDNS(service: service)) ?? "?"
                        guard actualDNS.contains(profile.wifiDNS) else {
                            throw NetworkManagerError.verificationFailed(
                                step: "set DNS on '\(service)'",
                                expected: profile.wifiDNS,
                                actual: actualDNS
                            )
                        }
                        dnsTargets.append(service)
                    }
                    try self.flushDNS()
                }
                if wifiOn {
                    // Режим поиска: обновляем список сетей для Control Center (best-effort).
                    scan = self.scanWiFi()
                    summary = "Applied: \(mine) + Wi-Fi ON (\(device)), DNS \(profile.wifiDNS) → \(dnsTargets.joined(separator: ", ")), scan: \(scan.count) nearby"
                } else {
                    scan = self.scanWiFi()
                    summary = "Applied: \(mine) + Wi-Fi OFF (\(device))"
                }
            } catch {
                failure = error.localizedDescription
            }
            let capturedFailure = failure
            let capturedSummary = summary
            let capturedScan = scan
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isApplying = false
                self.lastError = capturedFailure
                self.lastSummary = capturedSummary
                self.lastScan = capturedScan
                self.refresh()
            }
        }
    }

    /// Только вкл/выкл питания Wi-Fi — без ethernet-служб и DNS.
    /// Используется тогглом Wi-Fi в поповере.
    func applyWiFiOnly(on: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isApplying = true
            self?.lastError = nil
            self?.lastSummary = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var failure: String?
            var summary: String?
            var scan: [String] = []
            do {
                let device = (try? self.detectWiFiDevice()) ?? "en0"
                try self.setWiFiPower(device: device, on: on)
                let actualPower = try self.getWiFiPower(device: device)
                guard actualPower == on else {
                    throw NetworkManagerError.verificationFailed(
                        step: "set Wi-Fi power \(on ? "on" : "off") (\(device))",
                        expected: on ? "On" : "Off",
                        actual: actualPower ? "On" : "Off"
                    )
                }
                if on {
                    // Режим поиска: радиомодуль уже включён — обновляем список сетей,
                    // чтобы их было видно в Control Center. Best-effort, ошибки игнорим.
                    scan = self.scanWiFi()
                    summary = "Wi-Fi ON (\(device)), scan: \(scan.count) network(s) nearby"
                } else {
                    scan = self.scanWiFi()
                    summary = "Wi-Fi OFF (\(device))"
                }
            } catch {
                failure = error.localizedDescription
            }
            let capturedFailure = failure
            let capturedSummary = summary
            let capturedScan = scan
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isApplying = false
                self.lastError = capturedFailure
                self.lastSummary = capturedSummary
                self.lastScan = capturedScan
                self.refresh()
            }
        }
    }
}
