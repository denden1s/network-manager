import Foundation
import Combine
import ServiceManagement

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
    case invalidDNS(address: String)
    case noActiveService

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
        case .invalidDNS(let address):
            return "Invalid DNS address: \(address)"
        case .noActiveService:
            return "No active service (no enabled non-VPN service found)."
        }
    }
}

/// Снапшот состояния, собираемый в фоне и публикуемый на main.
struct NetworkStatus {
    var wifiDevice: String = "en0"
    var wifiPowerOn: Bool = false
    var wifiServices: [String] = []
    var dnsByService: [String: String] = [:]
    var connectionInfo: String = "…"
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
    /// Источник SSID на macOS 15+ (`getsummary` печатает `SSID : ...`).
    /// Читается БЕЗ sudo: редирекцией управляет глобальная настройка HideWiFiInfo,
    /// а не права процесса. Единственный вызов под sudo — `sethidewifiinfo`
    /// по явному согласию пользователя (см. `grantSSIDDisclosureConsent`).
    static let ipconfig = "/usr/sbin/ipconfig"

    /// UserDefaults: пользователь РАЗРЕШИЛ показывать SSID (системное скрытие снято).
    private static let keySSIDConsent = "nm.ssidDisclosure.consentGranted"
    /// UserDefaults: пользователь отказался («не сейчас») — больше не предлагаем.
    private static let keySSIDDeclined = "nm.ssidDisclosure.declined"

    @Published var wifiDevice: String = "en0"
    @Published var wifiPowerOn: Bool = false
    @Published var wifiServices: [String] = []
    @Published var services: [ServiceState] = []
    @Published var currentDNS: [String: String] = [:]
    @Published var isApplying: Bool = false
    @Published var lastError: String?
    @Published var lastSummary: String?
    @Published var connectionInfo: String = "…"
    @Published var ipAddress: String = "?"
    @Published var gateway: String = "?"
    @Published var passwordlessReady: Bool = false
    @Published var autostartEnabled = false

    /// macOS скрывает SSID, сеть ассоциирована, и согласие ещё не дано (и не отказано) —
    /// UI должен предложить выбор. Молча снимать скрытие нельзя: это СИСТЕМНАЯ настройка
    /// приватности, после неё SSID/BSSID видят все процессы на Mac, включая чужие.
    @Published var isSSIDDisclosureAvailable: Bool = false
    /// Считаем, что скрытие Wi-Fi-инфо снято (мы это сделали по согласию) — показать откат.
    @Published var isWiFiInfoRedactionDisabled: Bool = false

    /// Согласие/отказ в UserDefaults, а не в @Published: UI интересуют только два флага выше.
    private var ssidDisclosureConsent: Bool
    private var ssidDisclosureDeclined: Bool

    init() {
        // Решение пользователя переживает перезапуск: иначе вопрос про раскрытие SSID
        // появлялся бы заново при каждом запуске приложения.
        let defaults = UserDefaults.standard
        let consent = defaults.bool(forKey: Self.keySSIDConsent)
        self.ssidDisclosureConsent = consent
        self.ssidDisclosureDeclined = defaults.bool(forKey: Self.keySSIDDeclined)
        // До первого зонда реальное состояние настройки неизвестно — считаем его по факту
        // нашего согласия; `restoreWiFiInfoRedaction` доступен в любом случае.
        self.isWiFiInfoRedactionDisabled = consent
    }

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

    /// VPN служба? Эвристика: имя содержит "vpn" (case-insensitive).
    /// VPN-службы эксклюзивным правилом никогда не затрагиваются.
    static func isVPNService(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("vpn")
    }

    /// Конкурирующий аплинк — служба, ради которой действительно стоит гасить другие:
    /// только Wi-Fi и Ethernet. Всё остальное (мосты, USB-тетердинг, PAN, виртуальные
    /// адаптеры) не является конкурентом выхода в интернет, и раньше правило «гасим всех
    /// не-VPN» выключало Thunderbolt Bridge и iPhone USB — то есть у живого тетерринга
    /// и моста пропадал интернет вместе с Wi-Fi.
    ///
    /// ПОЧЕМУ ПО ИМЕНИ, А НЕ ПО ЖЕЛЕЗУ: авторитетной команды нет. У `networksetup` на
    /// macOS 15 нет `-listnetworkservicehardwareports` (проверено: печатает usage и
    /// падает с "command is not recognized"), `SCNetworkConfiguration` из
    /// SystemConfiguration не отдаётся в Swift, а `system_profiler SPNetworkDataType`
    /// печатает только ВКЛЮЧЁННЫЕ службы — ровно те, которые эксклюзивность и не трогает.
    /// Остаётся имя, как в `isWiFiService`/`isVPNService`.
    ///
    /// ПОРЯДОК ПРОВЕРОК: сначала VPN и «не настоящий интерфейс» (у виртуального/туннельного
    /// адаптера в имени может встретиться «ethernet», поэтому его отсекаем первым), затем
    /// положительные маркеры аплинка. Всё неузнанное считается НЕ конкурентом: гасить
    /// чужую службу наугад — худшее поведение для разрушительной операции.
    ///
    /// «usb» в негативных маркерах намеренно НЕТ: USB — это вид шины, а не тип линии.
    /// Тетердинг отсекается более точными маркерами (iphone/android/tether/hotspot), а
    /// USB-Ethernet («USB 10/100/1000 LAN», «USB Ethernet») — это настоящий аплинк, и его
    /// мы ловим положительным маркером. Поэтому «lan» сравнивается ЦЕЛЫМ СЛОВОМ, иначе
    /// под «lan» попало бы что угодно (Island, Plan).
    static func isCompetingUplink(_ name: String) -> Bool {
        let n = name.lowercased()
        if isVPNService(name) { return false }
        let virtualMarkers = ["bridge", "tunnel", "loopback", "virtual", "vbox", "vmware",
                              "parallels", "docker", "utun", "wg", "tailscale", "bear",
                              "tether", "iphone", "android", "hotspot",
                              "modem", "wwan", "cellular", "bluetooth", "thunderbolt",
                              "personal area"]
        if virtualMarkers.contains(where: { n.contains($0) }) { return false }
        // Реальные конкуренты: Wi-Fi и Ethernet.
        if isWiFiService(name) || n.contains("ethernet") { return true }
        let words = n.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        return words.contains("lan")
    }

    /// DNS-адрес валиден? IPv4 (4 октета 0–255) или IPv6 (hex-группы через ':', простая проверка).
    /// Невалидный адрес — ошибка `invalidDNS` ДО любых системных вызовов.
    static func isValidDNS(_ value: String) -> Bool {
        isValidIPv4(value) || isValidIPv6(value)
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isNumber }) else { return false }
            guard let octet = Int(part), (0...255).contains(octet) else { return false }
        }
        return true
    }

    private static func isValidIPv6(_ value: String) -> Bool {
        guard value.contains(":") else { return false }
        if value == "::" { return true }
        // Одиночное ':' в начале/конце — невалидно ("::" — ок).
        if value.hasPrefix(":") && !value.hasPrefix("::") { return false }
        if value.hasSuffix(":") && !value.hasSuffix("::") { return false }
        // Сжатие "::" — не более одного.
        guard value.components(separatedBy: "::").count - 1 <= 1 else { return false }
        let groups = value.split(separator: ":", omittingEmptySubsequences: true)
        guard !groups.isEmpty, groups.count <= 8 else { return false }
        for group in groups {
            guard group.count >= 1, group.count <= 4,
                  group.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        // Без "::" — ровно 8 групп; с "::" — меньше 8 (сжатие заменяет минимум одну группу).
        if value.contains("::") {
            return groups.count <= 7
        }
        return groups.count == 8
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

    /// Накопитель вывода `Process` под двумя параллельными читателями:
    /// `readDataToEndOfFile()` на main нельзя (блокирует), а читать после
    /// `waitUntilExit()` нельзя — большой stdout забивает буфер Pipe (64 КБ)
    /// и процесс вечно висит на write(). Нужен, потому что читаем с двух пайпов.
    private final class ProcessOutputBox {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        var string: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// Что именно удалось вычитать из `ipconfig getsummary <device>`.
    /// Различать эти состояния обязательно: обычный `String?` на всё отвечал nil'ом
    /// и «macOS прячет имя сети», и «сети нет вообще» — а это противоположные вещи
    /// с противоположными последствиями (см. `grantSSIDDisclosureConsent`).
    private enum SSIDRead {
        /// Реальное имя сети.
        case value(String)
        /// Буквально "<redacted>": система скрывает имя (HideWiFiInfo включён).
        case redacted
        /// Строки SSID нет или она пустая — прятать нечего, назвать нечего.
        /// Wi-Fi выключен, нет ассоциации, неверное имя устройства, Ethernet-сессия.
        case absent
    }

    /// SSID из вывода `ipconfig getsummary <device>`; различает реальное значение,
    /// `<redacted>` (скрытие включено глобальной настройкой HideWiFiInfo — действует
    /// на все uid, включая root, поэтому правами редирекцию не обойти; лечится
    /// `sethidewifiinfo 0`, см. `grantSSIDDisclosureConsent`) и полное отсутствие строки.
    /// Реальная строка вывода: "  SSID : MyNet" (два ведущих пробела), и рядом ВСЕГДА
    /// лежит "  BSSID : ..." — поэтому сравниваем префикс ПОСЛЕ trim и строго "SSID",
    /// иначе "BSSID" матчился бы как SSID и в UI уехал бы MAC-адрес как имя сети.
    /// Значение режем по первому ":" с сохранением остатка (в имени сети двоеточие
    /// теоретически возможно), лишние пробелы по краям убираем.
    private static func parseSSID(fromIpconfigSummary output: String) -> SSIDRead {
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("SSID"), line.contains(":") else { continue }
            let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
            // `<redacted>` — не значение, а отказ системы раскрывать SSID: это отдельное
            // состояние, а не «nil», иначе выключенный Wi-Fi выглядел бы как редирекция.
            if value == "<redacted>" { return .redacted }
            guard !value.isEmpty else { continue }
            return .value(value)
        }
        return .absent
    }

    /// Есть ли в выводе `ipconfig getsummary` признак того, что интерфейс АССОЦИИРОВАН
    /// с сетью: непустая строка `BSSID : ...` (MAC точки доступа) появляется ровно при
    /// ассоциации и исчезает при выключенном/неассоциированном Wi-Fi. Проверяем по ТОМУ ЖЕ
    /// выводу, что уже прочитан — лишних процессов не надо.
    /// Значение, в том числе `<redacted>`, годится как доказательство: BSSID бывает
    /// скрыт той же настройкой HideWiFiInfo, что и SSID, т.е. в самом интересном для нас
    /// случае (реально подключено, но имя скрыто) она как раз и приходит непустой —
    /// требовать «некрасную» BSSID значило бы запретить лечение именно там, где оно нужно.
    private static func hasAssociationEvidence(fromIpconfigSummary output: String) -> Bool {
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("BSSID"), line.contains(":") else { continue }
            let value = line.components(separatedBy: ":").dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
            return !value.isEmpty
        }
        return false
    }

    /// Тихий запуск одного процесса: stdout при exit 0, иначе nil. НИКОГДА не показывает
    /// системный prompt пароля (osascript здесь не используется в принципе) и НИКОГДА
    /// не бросает — только для фоновых чтений, где отсутствие результата не ошибка.
    /// Антизависание — три вещи: stdin = /dev/null (вводить нечего, ждать нечего),
    /// оба пайпа читаются ПАРАЛЛЕЛЬНО с ожиданием процесса — очередь читателей должна быть
    /// ИМЕННО конкурентной, потому что на СЕРИАЛЬНОЙ очереди stdout дочитался бы раньше stderr,
    /// и ребёнок, забивший буфер stderr (64 КБ), застрял бы на write() до нашего read:
    /// классический deadlock Process, ровно который этот код и объявляет предотвращённым —
    /// и дедлайн на waitUntilExit: своего таймаута у Process нет, поэтому он уходит в
    /// отдельную очередь, а мы ждём семафором; по таймауту процесс terminate'ится и
    /// возвращается nil. Так зависший процесс не держит `refresh()` (а через него весь
    /// popover) дольше пары секунд.
    @discardableResult
    private func runSilent(_ executable: String, arguments: [String], timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let box = ProcessOutputBox()
        let reader = DispatchQueue(label: "nm.silent.read", qos: .userInitiated, attributes: .concurrent)
        reader.async { box.append(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        reader.async { _ = errPipe.fileHandleForReading.readDataToEndOfFile() }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return box.string
    }

    /// Чтение SSID через НЕПРИВИЛЕГИРОВАННЫЙ `ipconfig getsummary <device>`:
    /// что вычитали (`SSIDRead`) + есть ли признак ассоциации с сетью.
    /// Привилегии здесь НЕ нужны: на macOS 15+ за скрытие SSID/BSSID отвечает глобальная
    /// настройка HideWiFiInfo, одинаковая для всех uid (в том числе для root), — поэтому
    /// читаем БЕЗ sudo, а не «с привилегиями». Проброс идёт через общий тихий раннер,
    /// наружу не уходит ничего: ни ошибок, ни `lastError`, ни prompt'а.
    private func readSSIDViaIpconfig(device: String) -> (read: SSIDRead, associated: Bool) {
        guard let out = runSilent(Self.ipconfig, arguments: ["getsummary", device]) else {
            return (.absent, false)
        }
        return (Self.parseSSID(fromIpconfigSummary: out),
                Self.hasAssociationEvidence(fromIpconfigSummary: out))
    }

    /// Выключает глобальное скрытие Wi-Fi-инфо: `sudo -n /usr/sbin/ipconfig sethidewifiinfo 0`.
    /// Возвращает true, если настройка выключилась.
    ///
    /// ВАЖНО, ПОЧЕМУ ЭТОТ ВЫЗОВ ТОЛЬКО ПРИ ДОКАЗАННОЙ РЕДИРЕКЦИИ: `sethidewifiinfo` меняет
    /// СИСТЕМНУЮ приватность — после неё macOS отдаёт SSID/BSSID вообще всем процессам,
    /// включая сторонние приложения. Это заметно более широкий эффект, чем «показать сеть
    /// в поповерере», поэтому вызывается он только когда чтение вернуло именно `.redacted`
    /// (строка `<redacted>`) И в том же выводе нашлась непустая `BSSID :` — то есть мы
    /// ассоциированы с сетью, а имя от нас намеренно скрывают. Если SSID не найден вовсе
    /// (`.absent`: Wi-Fi выключен, нет ассоциации, неверное устройство, Ethernet), скрывать
    /// нечего и ломать настройку незачем. Не «упрощайте» вызов в шапку `getConnectionSummary`:
    /// он будет дёргать системную настройку на каждом refresh, то есть на каждом открытии
    /// поповера, даже когда SSID и так виден.
    ///
    /// Повторные попытки дёшевы и потому допустимы: успех лечит надолго (после него обычное
    /// чтение всегда успешно и в этот код мы больше не попадаем), а неудача — быстрый `sudo -n`
    /// с ненулевым exit (доли секунды), который молча уходит в false.
    ///
    /// Только `sudo -n` напрямую, НИКОГДА `runPrivilegedBin`: тот при неудаче падает в
    /// osascript-fallback с системным диалогом пароля, а `getConnectionSummary()` зовётся из
    /// `refresh()` на каждом открытии поповера — пользователь получил бы запрос пароля каждый
    /// раз. Единственный осознанный единичный prompt остался в `installPasswordless`.
    /// Применить `sudo -n ipconfig sethidewifiinfo <value>`; nil — не вышло.
    /// Общий тихий путь для grant и restore: без prompt'а пароля (см. инвариант в `runSilent`),
    /// с тем же таймаутом и с тем же правилом «верить тексту вывода, а не коду возврата».
    private func setWiFiInfoHiding(_ value: String) -> Bool {
        guard let out = runSilent(Self.sudo, arguments: ["-n", Self.ipconfig, "sethidewifiinfo", value]) else {
            return false
        }
        // `ipconfig sethidewifiinfo` при нехватке прав печатает "failed to set hide WiFi info"
        // и при этом ВЫХОДИТ С КОДОМ 0 — судить строго по тексту вывода, не по коду возврата.
        // `sudo -n` без allowlist-гранта падает ненулевым кодом раньше — это тоже nil.
        return !out.contains("failed")
    }

    /// Согласие пользователя: снять глобальное скрытие Wi-Fi-инфо и показать SSID.
    /// Вызывает ТОЛЬКО UI по явному нажатию, из `refresh()` сюда пути нет.
    /// Согласие пишется в UserDefaults ДО попытки: намерение пользователя сохраняется
    /// даже если на этой машине нет allowlist-гранта (тогда SSID просто не появится,
    /// а кнопка отката останется доступной). Успех → `isWiFiInfoRedactionDisabled`,
    /// `lastSummary`, затем `refresh()`; неудача → `lastError` с подсказкой про allowlist.
    func grantSSIDDisclosureConsent() {
        DispatchQueue.main.async { [weak self] in
            self?.ssidDisclosureConsent = true
            self?.ssidDisclosureDeclined = false
            UserDefaults.standard.set(true, forKey: Self.keySSIDConsent)
            UserDefaults.standard.set(false, forKey: Self.keySSIDDeclined)
            self?.isSSIDDisclosureAvailable = false
            self?.isApplying = true
            self?.lastSummary = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ok = self.setWiFiInfoHiding("0")
            // Настройка применяется не мгновенно — даём системе время перечитать.
            if ok { Thread.sleep(forTimeInterval: 0.5) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isApplying = false
                if ok {
                    self.isWiFiInfoRedactionDisabled = true
                    self.lastError = nil
                    self.lastSummary = "Wi-Fi info hiding OFF (SSID/BSSID видны всем процессам)"
                } else {
                    self.isWiFiInfoRedactionDisabled = false
                    self.lastSummary = nil
                    self.lastError = "Не удалось снять скрытие Wi-Fi-инфо: нужен passwordless-грант "
                        + "для `ipconfig sethidewifiinfo` в sudoers (см. «Enable passwordless»)."
                }
                self.refresh()
            }
        }
    }

    /// Отказ от раскрытия SSID («не сейчас»): запоминаем в UserDefaults и больше
    /// не предлагаем при каждом открытии поповера. Системные вызовы не нужны —
    /// отказ ничего не меняет. Откат (`restoreWiFiInfoRedaction`) стирает и этот ключ,
    /// поэтому после возврата скрытия вопрос снова может быть задан.
    func declineSSIDDisclosureConsent() {
        ssidDisclosureDeclined = true
        ssidDisclosureConsent = false
        UserDefaults.standard.set(true, forKey: Self.keySSIDDeclined)
        UserDefaults.standard.set(false, forKey: Self.keySSIDConsent)
        isSSIDDisclosureAvailable = false
    }

    /// Откат: вернуть системное скрытие Wi-Fi-инфо (`sethidewifiinfo default`) и
    /// забыть решение пользователя. ВАЖНО: НЕ гейтим на сохранённом согласии —
    /// вернуть приватность должен быть возможен всегда, даже если флаги говорят обратное
    /// (например, согласие выдано, а настройку сняли руками в терминале).
    /// Успех → `isWiFiInfoRedactionDisabled = false` + оба ключа UserDefaults очищены;
    /// неудача → `lastError`; состояние macOS и ключи при этом НЕ трогаем, чтобы
    /// не разойтись с реальностью.
    func restoreWiFiInfoRedaction() {
        DispatchQueue.main.async { [weak self] in
            self?.isApplying = true
            self?.lastSummary = nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ok = self.setWiFiInfoHiding("default")
            if ok { Thread.sleep(forTimeInterval: 0.5) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isApplying = false
                if ok {
                    self.isWiFiInfoRedactionDisabled = false
                    self.ssidDisclosureConsent = false
                    self.ssidDisclosureDeclined = false
                    UserDefaults.standard.set(false, forKey: Self.keySSIDConsent)
                    UserDefaults.standard.set(false, forKey: Self.keySSIDDeclined)
                    self.lastError = nil
                    self.lastSummary = "Wi-Fi info hiding restored to macOS default"
                } else {
                    self.lastSummary = nil
                    self.lastError = "Не удалось вернуть скрытие Wi-Fi-инфо: нужен passwordless-грант "
                        + "для `ipconfig sethidewifiinfo` в sudoers (см. «Enable passwordless»)."
                }
                self.refresh()
            }
        }
    }

    /// Сводка подключения БЕЗ привилегий, НЕ бросает (внутри try? + fallback "unknown"):
    /// SSID через самовосстанавливающийся `ipconfig getsummary`
    /// + IP через `networksetup -getinfo <первый wifi-сервис>` (строка "IP address:").
    /// Короткое имя активной сети для строки "Connected".
    ///
    /// Механизм скрытия SSID на macOS 15+ — ГЛОБАЛЬНАЯ настройка HideWiFiInfo, а не права
    /// процесса: пока она включена, `ipconfig getsummary` печатает `SSID : <redacted>` и
    /// `BSSID : <redacted>` ОДИНАКОВО для всех uid, включая root. Поэтому правами тут
    /// ничего не выиграть, и порядок источников такой:
    /// 1) `ipconfig getsummary` БЕЗ sudo — обычный быстрый путь, в нормальном состоянии
    ///    системы он сразу отдаёт реальное имя сети;
    /// 2) если имя СИСТЕМНО скрыто — вывод содержит `SSID : <redacted>` И непустую
    ///    `BSSID :` (признак ассоциации), — сами мы ничего не меняем: это глобальная
    ///    настройка приватности, поэтому только выставляем `isSSIDDisclosureAvailable`,
    ///    а снятие скрытия делает пользователь по явному согласию
    ///    (`grantSSIDDisclosureConsent`, отказ — `declineSSIDDisclosureConsent`,
    ///    откат — `restoreWiFiInfoRedaction`). Prompt'ов пароля здесь не бывает by design:
    ///    `sudo -n` без osascript-fallback;
    /// 3) `networksetup -getairportnetwork` — последний резерв для старых macOS: на 15.7.9
    ///    он безусловно печатает "You are not associated with an AirPort network." даже при
    ///    живой ассоциации (именно он раньше и давал ложное "нет сети"), поэтому его фильтр
    ///    служебных фраз остаётся корректным — он отсекает ложное срабатывание.
    /// Дальше — без изменений: службы Wi-Fi, затем Ethernet, затем "нет сети".
    /// IP сюда НЕ входит: он уже показан отдельной строкой статуса.
    /// Если Wi-Fi не ассоциирован, но живой Ethernet — показываем его службу,
    /// т.к. Ethernet-службы в этом приложении равноправны с Wi-Fi.
    func getConnectionSummary() -> String {
        let device = (try? detectWiFiDevice()) ?? "en0"
        let probe = readSSIDViaIpconfig(device: device)
        // Шаг 1: непривилегированное чтение — обычно сразу успех.
        if case .value(let ssid) = probe.read { return ssid }
        // Шаг 2: макос именно СКРЫВАЕТ имя ассоциированной сети. Само снятие скрытия —
        // системная настройка приватности, поэтому мы её НЕ делаем молча: только выставляем
        // флаг для UI (`isSSIDDisclosureAvailable`), чтобы предложить выбор. Согласие даёт
        // `grantSSIDDisclosureConsent`, отказ — `declineSSIDDisclosureConsent`. На `.absent`
        // (Wi-Fi выключен / нет ассоциации / неверное устройство / Ethernet) вопрос не
        // показываем: спрашивать не о чем.
        if case .redacted = probe.read, probe.associated {
            let shouldOffer = !ssidDisclosureConsent && !ssidDisclosureDeclined
            DispatchQueue.main.async { [weak self] in
                self?.isSSIDDisclosureAvailable = shouldOffer
            }
        } else {
            // Скрытия больше нет (или сети нет) — предложение снимаем в любом случае,
            // иначе флаг мог бы «залипнуть» после успешного grant/отката.
            DispatchQueue.main.async { [weak self] in
                self?.isSSIDDisclosureAvailable = false
            }
        }
        if let out = try? run(["-getairportnetwork", device]) {
            let ssid = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let isServiceMessage = ssid.isEmpty
                || ssid.hasPrefix("You are not associated")
                || ssid.lowercased().hasPrefix("could not find")
            if !isServiceMessage { return ssid }
        }
        // Живой Wi-Fi без читаемого SSID (не снялось скрытие инфо, нет allowlist
        // на sudo, старый непривилегированный macOS) — показываем имя службы,
        // а НЕ «нет сети»: сеть-то поднята, и это правда. Раньше Wi-Fi-службы в этом цикле
        // пропускались целиком, поэтому подключённый но «слепой» Wi-Fi выглядел как обрыв.
        for service in ((try? getAllServices()) ?? []) where Self.isWiFiService(service) {
            guard (try? getServiceEnabled(service)) == true else { continue }
            let ip = getIPAddress(service: service)
            if !ip.isEmpty && ip != "?" { return service }
        }
        for service in ((try? getAllServices()) ?? []) where !Self.isWiFiService(service) {
            guard (try? getServiceEnabled(service)) == true else { continue }
            let ip = getIPAddress(service: service)
            if !ip.isEmpty && ip != "?" { return service }
        }
        return "нет сети"
    }

    // MARK: - Setters (с привилегиями: сначала sudo -n, fallback — системный prompt)

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

    /// `networksetup -setdnsservers <service> <dns1> <dns2> ...` (sudo)
    /// + verify (`getDNS` содержит каждый адрес) + `flushDNS()`.
    /// Валидация адресов — ДО любых системных вызовов.
    func setDNSServers(service: String, servers: [String]) throws {
        let cleaned = servers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw NetworkManagerError.invalidDNS(address: "(empty — use Auto for DHCP)")
        }
        for server in cleaned {
            guard Self.isValidDNS(server) else {
                throw NetworkManagerError.invalidDNS(address: server)
            }
        }
        try runPrivilegedBin(path: Self.networksetup, args: ["-setdnsservers", service] + cleaned)
        // Применение не мгновенное — даём системе время.
        Thread.sleep(forTimeInterval: 0.5)
        let current = try getDNS(service: service)
        for server in cleaned {
            guard current.contains(server) else {
                throw NetworkManagerError.verificationFailed(
                    step: "set DNS servers for '\(service)'",
                    expected: cleaned.joined(separator: " "),
                    actual: current
                )
            }
        }
        try flushDNS()
    }

    /// Сброс DNS на автоматические (DHCP): `networksetup -setdnsservers <service> empty` (sudo)
    /// + `flushDNS()`. Verify не строгий: успех = отсутствие ошибки.
    func clearDNS(service: String) throws {
        try runPrivilegedBin(path: Self.networksetup, args: ["-setdnsservers", service, "empty"])
        try flushDNS()
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

    // MARK: - Autostart (SMAppService)

    /// Текущее состояние автозапуска через SMAppService.mainApp.
    func isAutostartEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Вкл/выкл автозапуска. Ошибку register (частый кейс — приложение
    /// не в /Applications) бросает как есть, без обёрток.
    func setAutostart(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Установка желаемого состояния автозапуска (фон, как остальные apply).
    /// Вызывается из set-кложура явного Binding в UI, поэтому программные
    /// публикации `autostartEnabled` из `refresh()` сюда не попадают: SwiftUI не вызывает
    /// set-клозору у Binding на программном изменении источника истины (он лишь перерисует
    /// view), поэтому и get здесь безопасен — цикла не возникает.
    /// Идемпотентно: совпадение с фактическим состоянием — no-op + `refresh()`.
    /// Ошибки → `lastError` текстом без обёрток, успех → `lastSummary`, в конце `refresh()`.
    func setAutostartEnabled(_ desired: Bool) {
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
                if self.isAutostartEnabled() != desired {
                    try self.setAutostart(enabled: desired)
                }
                summary = "Launch at login \(desired ? "ON" : "OFF")"
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

    // MARK: - High-level logic

    /// Обновить статус (вызывать из UI). Тяжёлая работа — в фоне.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var status = NetworkStatus()
            var serviceStates: [ServiceState] = []
            var failure: String?
            let passwordless = self.isPasswordless()
            let autostart = self.isAutostartEnabled()
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
                for service in allServices {
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
            let capturedAutostart = autostart
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
                self.autostartEnabled = capturedAutostart
                // Асимметрия с остальными apply-методами, где `lastError = capturedFailure`
                // (там присваивание nil корректно — операция сбрасывает СВОЮ прошлую
                // ошибку). З.refresh() вызывается в конце каждого apply, и его собственный
                // failure почти всегда nil: безусловное присваивание стирало бы ошибку,
                // которую apply только что показал, через ~100 мс после неё. Поэтому refresh
                // трогает lastError ТОЛЬКО если сам что-то упал, и не мешает чужому
                // сообщению дожить до следующего осознанного действия пользователя.
                if let capturedFailure { self.lastError = capturedFailure }
            }
        }
    }

    /// Вкл/выкл одной сетевой службы (фон, как остальные apply).
    /// Эксклюзивность: в один момент активна только одна не-VPN служба —
    /// при ВКЛЮЧЕНИИ конкурирующего аплинка (Wi-Fi или Ethernet) другие такие же
    /// конкуренты гасятся (каждая через `setServiceEnabled(..., false)`);
    /// VPN, мосты, USB-тетердинг, PAN и виртуальные адаптеры — никогда (см.
    /// `isCompetingUplink`). При включении VPN и при ВЫКЛЮЧЕНИИ любой службы —
    /// только она сама.
    /// Wi-Fi службы — особый случай поверх эксклюзивности: дополнительно питание
    /// радиомодуля (`setWiFiPower` + verify). Не-Wi-Fi службы — только enable/disable.
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
                let isVPN = Self.isVPNService(name)
                let isWiFi = Self.isWiFiService(name)
                let device = (try? self.detectWiFiDevice()) ?? "en0"
                // 1. Сама служба.
                try self.setServiceEnabled(name, enabled: enabled)
                // 2. Эксклюзивность: включаем КОНКУРИРУЮЩИЙ аплинк — гасим другие
                // конкурирующие аплинки (Wi-Fi ↔ Ethernet). Мосты, USB-тетердинг, PAN и
                // виртуальные адаптеры конкурентами не считаются и остаются как были:
                // иначе включение Wi-Fi убивало бы Thunderbolt Bridge и iPhone USB.
                // VPN не трогаем, как и раньше.
                var exclusiveOthers: [String] = []
                if enabled && !isVPN && Self.isCompetingUplink(name) {
                    for other in try self.getAllServices()
                            where other != name && Self.isCompetingUplink(other) {
                        try self.setServiceEnabled(other, enabled: false)
                        exclusiveOthers.append(other)
                    }
                }
                // Применение не мгновенное — даём системе время.
                Thread.sleep(forTimeInterval: 0.5)
                // 3. Верификация: включённая — on, остальные не-VPN — off.
                // VPN в verify не проверяем никогда.
                let actual = try self.getServiceEnabled(name)
                guard actual == enabled else {
                    throw NetworkManagerError.verificationFailed(
                        step: "\(enabled ? "enable" : "disable") service '\(name)'",
                        expected: enabled ? "Enabled" : "Disabled",
                        actual: actual ? "Enabled" : "Disabled"
                    )
                }
                for other in exclusiveOthers {
                    let otherOn = try self.getServiceEnabled(other)
                    guard !otherOn else {
                        throw NetworkManagerError.verificationFailed(
                            step: "disable service '\(other)' (exclusive)",
                            expected: "Disabled",
                            actual: "Enabled"
                        )
                    }
                }
                // 4. Wi-Fi: питание радиомодуля + verify.
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

    /// Активная служба для DNS: первая включённая не-VPN (та же логика, что exclusivity).
    /// Читает опубликованный `services` — вызывать с main (подпись в UI).
    func activeServiceName() -> String? {
        services.first(where: { $0.enabled && !Self.isVPNService($0.name) })?.name
    }

    /// Свежее разрешение активной службы в фоне (не зависит от кэша UI):
    /// первая включённая не-VPN, иначе `noActiveService`.
    private func resolveActiveService() throws -> String {
        for name in try getAllServices() where !Self.isVPNService(name) {
            if (try? getServiceEnabled(name)) ?? false {
                return name
            }
        }
        throw NetworkManagerError.noActiveService
    }

    /// Ручной DNS на активную службу (фон, как остальные apply).
    /// Ошибки → `lastError`, успех → `lastSummary`, в конце `refresh()`.
    func applyDNSServers(_ servers: [String]) {
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
                let active = try self.resolveActiveService()
                try self.setDNSServers(service: active, servers: servers)
                summary = "DNS for '\(active)' → \(servers.joined(separator: " "))"
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

    /// Сброс DNS активной службы на автоматические/DHCP (фон, как остальные apply).
    /// Ошибки → `lastError`, успех → `lastSummary`, в конце `refresh()`.
    func applyAutoDNS() {
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
                let active = try self.resolveActiveService()
                try self.clearDNS(service: active)
                summary = "DNS for '\(active)' → Auto (DHCP)"
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

    /// Разобранный список DNS-серверов активной службы (первая включённая, не VPN).
    /// Сырой вывод getDNS — многострочный текст; при отсутствии ручных серверов
    /// networksetup отдаёт "?" или "There aren't any DNS Servers set on ...".
    /// Эти маркеры отфильтровываются, результат — только валидные адреса.
    /// Чистое чтение опубликованного состояния: без Process и без побочных эффектов,
    /// безопасно вызывать прямо из SwiftUI `body`.
    var activeDNSServers: [String] {
        guard let active = activeServiceName(), let raw = currentDNS[active] else { return [] }
        return raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "?" && Self.isValidDNS($0) }
    }

    /// Добавляет один DNS-сервер в ручной список активной службы (фон, как остальные apply).
    /// Адрес проверяется `isValidDNS` ДО системных вызовов — мусор в GUI не должен доходить до sudo.
    /// В отличие от removeDNSServer ничего не выбрасывает: текущий список сохраняется целиком,
    /// новый адрес дописывается в конец. Если DNS сейчас на DHCP/auto (список пуст), результат —
    /// одно-серверный ручной список; clearDNS здесь не вызывается намеренно, иначе «добавить»
    /// тихо сбрасывало бы DHCP-адреса, выданные провайдером.
    /// Повторное добавление того же адреса — no-op с понятным summary, чтобы double-tap по кнопке
    /// не гонял `networksetup` вхолостую.
    /// Ошибки → `lastError`, успех → `lastSummary`, в конце `refresh()`.
    func addDNSServer(_ server: String) {
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
                let active = try self.resolveActiveService()
                guard Self.isValidDNS(server) else {
                    // Невалидный адрес: систему не трогаем, только дружелюбная ошибка в lastError.
                    throw NetworkManagerError.invalidDNS(address: server)
                }
                let current = (try? self.getDNS(service: active)) ?? "?"
                let list = current.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "?" && Self.isValidDNS($0) }
                if list.contains(server) {
                    // Сервер уже задан — систему не трогаем, только дружелюбный summary.
                    summary = "DNS for '\(active)' → без изменений (\(server) уже есть)"
                } else {
                    // Хвост сохраняем, новый адрес в конец (при пустом списке это единственный сервер).
                    let updated = list + [server]
                    try self.setDNSServers(service: active, servers: updated)
                    summary = "DNS for '\(active)' → \(updated.joined(separator: " "))"
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

    /// Удаляет один DNS-сервер из активной службы.
    /// Если это последний ручной сервер — уходит в clearDNS (DHCP), т.к. setDNSServers([])
    /// бросает invalidDNS("(empty — use Auto for DHCP)").
    func removeDNSServer(_ server: String) {
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
                let active = try self.resolveActiveService()
                let current = (try? self.getDNS(service: active)) ?? "?"
                let list = current.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "?" && Self.isValidDNS($0) }
                if !list.contains(server) {
                    // Сервера нет в списке — систему не трогаем, только дружелюбный summary.
                    summary = "DNS for '\(active)' → без изменений (\(server) не задан)"
                } else {
                    let remaining = list.filter { $0 != server }
                    if remaining.isEmpty {
                        // Последний ручной сервер: сброс на автоматические (DHCP).
                        try self.clearDNS(service: active)
                        summary = "DNS for '\(active)' → DHCP (последний сервер удалён)"
                    } else {
                        try self.setDNSServers(service: active, servers: remaining)
                        summary = "DNS for '\(active)' → \(remaining.joined(separator: " "))"
                    }
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
