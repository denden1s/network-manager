import Foundation
import Combine

/// Состояние одной сетевой службы для списка тогглов в поповере.
struct ServiceState: Identifiable {
    let name: String
    var enabled: Bool
    var id: String { name }
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
    var wifiDevice: String = "en0"
    var wifiPowerOn: Bool = false
    var wifiServices: [String] = []
    var dnsByService: [String: String] = [:]
    var connectionInfo: String = "unknown"
    var ipAddress: String = "?"
    var gateway: String = "?"
}

/// Обёртка над `/usr/sbin/networksetup`.
/// Все чтения выполняются напрямую, все изменения — через `runPrivilegedBin`:
/// сначала пробуем `sudo -n <бинарь> <args>` напрямую без shell
/// (sudo матчит запускаемый бинарь — NOPASSWD-allowlist из
/// scripts/install-passwordless-sudo.sh разрешает только прямые вызовы),
/// при неудаче — fallback на
/// `osascript -e 'do shell script "..." with administrator privileges'`
/// (системный prompt пароля, без SMJobBless).
final class NetworkManager: ObservableObject {
    static let networksetup = "/usr/sbin/networksetup"
    static let osascript = "/usr/bin/osascript"
    static let sudo = "/usr/bin/sudo"
    static let dscacheutil = "/usr/bin/dscacheutil"
    static let killall = "/usr/bin/killall"
    static let route = "/sbin/route"
    static let netstat = "/usr/sbin/netstat"
    static let airportCLI = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

    @Published var wifiDevice: String = "en0"
    @Published var wifiPowerOn: Bool = false
    @Published var wifiServices: [String] = []
    @Published var services: [ServiceState] = []
    @Published var currentDNS: [String: String] = [:]
    @Published var isApplying: Bool = false
    @Published var lastError: String?
    @Published var lastSummary: String?
    @Published var connectionInfo: String = "unknown"
    @Published var ipAddress: String = "?"
    @Published var gateway: String = "?"
    @Published var passwordlessReady: Bool = false

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

    /// Запуск привилегированной команды БЕЗ shell: `sudo -n <path> <args>` напрямую.
    /// sudo матчит запускаемый бинарь, поэтому без `sh -c` (иначе видел бы `sh`
    /// и allowlist не срабатывал). При exit 0 — вернуть stdout.
    /// Иначе fallback: shell-строка из path+args (КАЖДЫЙ аргумент через `shellQuote`)
    /// выполняется osascript-путём. Ошибка при падении обоих — stderr обеих попыток.
    @discardableResult
    func runPrivilegedBin(path: String, args: [String]) throws -> String {
        // Путь 1: sudo -n напрямую, без shell.
        let sudoProcess = Process()
        sudoProcess.executableURL = URL(fileURLWithPath: Self.sudo)
        sudoProcess.arguments = ["-n", path] + args
        let sudoOutPipe = Pipe()
        let sudoErrPipe = Pipe()
        sudoProcess.standardOutput = sudoOutPipe
        sudoProcess.standardError = sudoErrPipe
        try sudoProcess.run()
        sudoProcess.waitUntilExit()
        let sudoOut = String(data: sudoOutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let sudoErr = String(data: sudoErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if sudoProcess.terminationStatus == 0 {
            return sudoOut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Путь 2 (fallback): shell-строка + системный prompt.
        let shellCommand = ([path] + args).map { Self.shellQuote($0) }.joined(separator: " ")
        do {
            return try runOsascriptPrivileged(shellCommand)
        } catch NetworkManagerError.cancelledByUser {
            throw NetworkManagerError.cancelledByUser
        } catch {
            guard let osaError = error as? NetworkManagerError,
                  case .commandFailed(_, let exitCode, let output) = osaError else {
                throw error
            }
            throw NetworkManagerError.commandFailed(
                command: shellCommand,
                exitCode: exitCode,
                output: "sudo -n failed: \(sudoErr.trimmingCharacters(in: .whitespacesAndNewlines))\nosascript failed: \(output)"
            )
        }
    }

    /// Привилегированный запуск shell-команды через системный prompt (osascript
    /// `do shell script "..." with administrator privileges`). Без попыток sudo.
    /// Используется как fallback из `runPrivilegedBin` и напрямую из `installPasswordless`
    /// (скрипт установки целиком требует shell — `sh` в allowlist нет и не нужен).
    @discardableResult
    func runOsascriptPrivileged(_ shellCommand: String) throws -> String {
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

    /// Проверка passwordless-режима через `sudo -n -l` (что разрешён NOPASSWD
    /// для networksetup), без throws. Не зависит от свежести sudo-timestamp,
    /// в отличие от `sudo -n true`. Используется UI, чтобы прятать кнопку "Enable passwordless".
    func isPasswordless() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sudo)
        process.arguments = ["-n", "-l"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("NOPASSWD") && out.contains("networksetup")
    }

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

    /// Wi-Fi служба? (имя содержит Wi-Fi / AirPort).
    static func isWiFiService(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("wi-fi")
            || name.localizedCaseInsensitiveContains("airport")
    }

    /// Подмножество сервисов, являющихся Wi-Fi.
    func getWiFiServices() throws -> [String] {
        return try getAllServices().filter { Self.isWiFiService($0) }
    }

    /// `networksetup -getdnsservers <service>` (сырой вывод).
    func getDNS(service: String) throws -> String {
        return try run(["-getdnsservers", service])
    }

    /// IP адрес сервиса через `networksetup -getinfo <service>` (строка "IP address:").
    /// Best-effort: при любой ошибке или пустом значении возвращает "?".
    func getIPAddress(service: String) -> String {
        guard let info = try? run(["-getinfo", service]) else { return "?" }
        for rawLine in info.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("IP address:") {
                let value = line
                    .replacingOccurrences(of: "IP address:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
                break
            }
        }
        return "?"
    }

    /// Шлюз по умолчанию: `route -n get default`, без sudo.
    /// Парсим строку вида `gateway: 192.168.1.1` (второй токен).
    /// При активном VPN default route уходит в utun без поля gateway —
    /// тогда fallback на `netstat -rn -f inet` (первый default с IP-шлюзом, не link#).
    func getDefaultGateway() throws -> String {
        if let viaRoute = try? getGatewayViaRoute() {
            return viaRoute
        }
        return try getGatewayViaNetstat()
    }

    private func getGatewayViaRoute() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.route)
        process.arguments = ["-n", "get", "default"]
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
                command: "route -n get default",
                exitCode: process.terminationStatus,
                output: (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        for rawLine in out.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("gateway:") {
                let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if tokens.count >= 2 { return tokens[1] }
            }
        }
        throw NetworkManagerError.commandFailed(
            command: "route -n get default",
            exitCode: 0,
            output: "gateway not found in output:\n\(out)"
        )
    }

    private func getGatewayViaNetstat() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.netstat)
        process.arguments = ["-rn", "-f", "inet"]
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
                command: "netstat -rn -f inet",
                exitCode: process.terminationStatus,
                output: (out + "\n" + err).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        // Строки вида: "default  192.168.222.1  UGScIg  en6"
        // Пропускаем VPN-заглушки вида "default  link#23  ...  utun6".
        for rawLine in out.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("default") else { continue }
            let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard tokens.count >= 2 else { continue }
            let gateway = tokens[1]
            if gateway.hasPrefix("link#") { continue }
            if !gateway.isEmpty { return gateway }
        }
        throw NetworkManagerError.commandFailed(
            command: "netstat -rn -f inet",
            exitCode: 0,
            output: "gateway not found in output:\n\(out)"
        )
    }

    /// `networksetup -getnetworkserviceenabled <service>` -> true = Enabled.
    /// Вывод вида "Enabled" / "Disabled".
    func getServiceEnabled(_ service: String) throws -> Bool {
        let out = try run(["-getnetworkserviceenabled", service])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("Disabled") { return false }
        return trimmed.localizedCaseInsensitiveContains("Enabled")
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

    // MARK: - Setters (с привилегиями: сначала sudo -n, fallback — системный prompt)

    /// `networksetup -switchtolocation <location>` (sudo).
    func switchLocation(_ location: String) throws {
        try runPrivilegedBin(path: Self.networksetup, args: ["-switchtolocation", location])
    }

    /// `networksetup -setnetworkserviceenabled <service> on|off` (sudo).
    func setServiceEnabled(_ service: String, enabled: Bool) throws {
        let state = enabled ? "on" : "off"
        try runPrivilegedBin(path: Self.networksetup, args: ["-setnetworkserviceenabled", service, state])
    }

    /// `networksetup -setairportpower <device> on|off` (sudo).
    func setWiFiPower(device: String, on: Bool) throws {
        let state = on ? "on" : "off"
        try runPrivilegedBin(path: Self.networksetup, args: ["-setairportpower", device, state])
    }

    /// `networksetup -setdnsservers <service> <dns>` (sudo).
    func setDNS(service: String, dns: String) throws {
        try runPrivilegedBin(path: Self.networksetup, args: ["-setdnsservers", service, dns])
    }

    /// Сброс DNS-кэша после смены DNS (sudo): два прямых вызова без shell —
    /// `dscacheutil -flushcache` и `killall -HUP mDNSResponder`.
    func flushDNS() throws {
        try runPrivilegedBin(path: Self.dscacheutil, args: ["-flushcache"])
        try runPrivilegedBin(path: Self.killall, args: ["-HUP", "mDNSResponder"])
    }

    /// Установка passwordless sudoers-allowlist через scripts/install-passwordless-sudo.sh.
    /// Запуск — напрямую через osascript-привилегированный путь (один системный промпт),
    /// БЕЗ попыток sudo -n (скрипт целиком требует shell — `sh` в allowlist нет и не нужен).
    /// Возвращает stdout скрипта или бросает commandFailed с его выводом.
    /// Скрипт должен лежать в Resources бандла (см. README → Passwordless).
    @discardableResult
    func installPasswordless() throws -> String {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw NetworkManagerError.commandFailed(
                command: "install-passwordless-sudo.sh",
                exitCode: -1,
                output: "Bundle.main.resourcePath is nil"
            )
        }
        let scriptPath = (resourcePath as NSString).appendingPathComponent("install-passwordless-sudo.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            throw NetworkManagerError.commandFailed(
                command: scriptPath,
                exitCode: -1,
                output: "Script not found in app Resources. See README → Passwordless: add scripts/install-passwordless-sudo.sh to Copy Files → Resources."
            )
        }
        return try runOsascriptPrivileged("/bin/sh \(Self.shellQuote(scriptPath))")
    }

    // MARK: - High-level logic

    /// Обновить статус (вызывать из UI). Тяжёлая работа — в фоне.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var status = NetworkStatus()
            var serviceStates: [ServiceState] = []
            var failure: String?
            let passwordless = self.isPasswordless()
            do {
                status.wifiDevice = try self.detectWiFiDevice()
                status.wifiPowerOn = try self.getWiFiPower(device: status.wifiDevice)
                let allServices = try self.getAllServices()
                status.wifiServices = allServices.filter { Self.isWiFiService($0) }
                for name in allServices {
                    // Best-effort по каждой службе: ошибку чтения считаем Disabled.
                    let enabled = (try? self.getServiceEnabled(name)) ?? false
                    serviceStates.append(ServiceState(name: name, enabled: enabled))
                }
                for service in status.wifiServices {
                    status.dnsByService[service] = (try? self.getDNS(service: service)) ?? "?"
                }
                status.connectionInfo = self.getConnectionSummary()
                // IP: Wi-Fi включён — первый Wi-Fi сервис, иначе первая включённая
                // не-Wi-Fi служба (активный Ethernet).
                if status.wifiPowerOn, let wifiService = status.wifiServices.first {
                    status.ipAddress = self.getIPAddress(service: wifiService)
                } else if let eth = serviceStates.first(where: { $0.enabled && !Self.isWiFiService($0.name) }) {
                    status.ipAddress = self.getIPAddress(service: eth.name)
                } else {
                    status.ipAddress = "?"
                }
                status.gateway = (try? self.getDefaultGateway()) ?? "?"
            } catch {
                failure = error.localizedDescription
            }
            let capturedStatus = status
            let capturedServices = serviceStates
            let capturedFailure = failure
            let capturedPasswordless = passwordless
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.wifiDevice = capturedStatus.wifiDevice
                self.wifiPowerOn = capturedStatus.wifiPowerOn
                self.wifiServices = capturedStatus.wifiServices
                self.services = capturedServices
                self.currentDNS = capturedStatus.dnsByService
                self.connectionInfo = capturedStatus.connectionInfo
                self.ipAddress = capturedStatus.ipAddress
                self.gateway = capturedStatus.gateway
                self.passwordlessReady = capturedPasswordless
                self.lastError = capturedFailure
            }
        }
    }

    /// Вкл/выкл одной сетевой службы (фон, как остальные apply).
    /// Wi-Fi службы — особый случай: дополнительно питание радиомодуля
    /// (`setWiFiPower` + verify), при включении — фоновый `scanWiFi()`
    /// (режим поиска для Control Center). Не-Wi-Fi службы — только enable/disable.
    /// Ошибки → `lastError`, успех → `lastSummary` ("Service 'X' ON/OFF"), в конце `refresh()`.
    func setService(name: String, enabled: Bool) {
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
                let isWiFi = Self.isWiFiService(name)
                let device = (try? self.detectWiFiDevice()) ?? "en0"
                // 1. Сама служба + верификация.
                try self.setServiceEnabled(name, enabled: enabled)
                // Применение не мгновенное — даём системе время.
                Thread.sleep(forTimeInterval: 0.5)
                let actual = try self.getServiceEnabled(name)
                guard actual == enabled else {
                    throw NetworkManagerError.verificationFailed(
                        step: "\(enabled ? "enable" : "disable") service '\(name)'",
                        expected: enabled ? "Enabled" : "Disabled",
                        actual: actual ? "Enabled" : "Disabled"
                    )
                }
                // 2. Wi-Fi: питание радиомодуля + verify; при включении — фоновый скан.
                if isWiFi {
                    try self.setWiFiPower(device: device, on: enabled)
                    let actualPower = try self.getWiFiPower(device: device)
                    guard actualPower == enabled else {
                        throw NetworkManagerError.verificationFailed(
                            step: "set Wi-Fi power \(enabled ? "on" : "off") (\(device))",
                            expected: enabled ? "On" : "Off",
                            actual: actualPower ? "On" : "Off"
                        )
                    }
                    if enabled {
                        // Режим поиска: обновляем список сетей для Control Center (best-effort).
                        _ = self.scanWiFi()
                    }
                }
                summary = "Service '\(name)' \(enabled ? "ON" : "OFF")"
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
