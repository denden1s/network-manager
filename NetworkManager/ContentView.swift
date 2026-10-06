import SwiftUI

/// Окно-поповер из menu-bar иконки: тогглы всех служб + статус.
struct ContentView: View {
    @ObservedObject var manager: NetworkManager
    @State private var dnsInput: String = ""
    @State private var isDNSInputVisible: Bool = false
    // Фокус ставим вручную: поповер открыт кликом по иконке меню, SwiftUI сам в поле не войдёт.
    @FocusState private var isDNSInputFocused: Bool
    @State private var summaryClearWorkItem: DispatchWorkItem?
    // Подтверждение первого снятия скрытия: показывается по клику, живёт до согласия,
    // отказа или смены флагов под собой — «зависнуть» в поповере оно не должно.
    @State private var isSSIDDisclosureConfirmVisible: Bool = false
    @State private var isSSIDDisclosureConfirmed: Bool = false

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
                // Без этого два быстрых переключения запускают два setService, гасящих
                // друг друга: первый закончит — и гасит isApplying, пока второй ещё идёт.
                .disabled(manager.isApplying)
                .opacity(manager.isApplying ? 0.3 : 1)
                .animation(.easeOut(duration: 0.15), value: manager.isApplying)
            }

            Divider()

            // Текущий статус системы.
            Group {
                HStack(spacing: 4) {
                    // Когда имя сети скрыто настройкой macOS, сюда честно встаёт имя службы.
                    // Заглушку вида «показываем…» не рисуем: имени может не быть вообще.
                    Text("Connected: \(manager.connectionInfo)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    connectedSSIDHint
                }
                if isSSIDDisclosureConfirmVisible {
                    ssidConfirmationRow
                }
                Text("Wi-Fi (\(manager.wifiDevice)): \(manager.wifiPowerOn ? "ON" : "OFF")")
                Text("IP: \(manager.ipAddress)")
                Text("Gateway: \(manager.gateway)")
            }
            .font(.caption)
            .textSelection(.enabled)

            Divider()

            // Ручной DNS для активной службы: сервера, удаление по одному, добавление через «+».
            // Блок всегда раскрыт — свёрнутый вариант прятал кнопку добавления при 0–1 сервере.
            dnsSection
                .font(.caption)

            if let error = manager.lastError {
                messageRow(error, color: .red, help: "Скрыть ошибку") {
                    dismissMessages()
                }
            }
            if let summary = manager.lastSummary {
                messageRow(summary, color: .green, help: "Скрыть") {
                    dismissMessages()
                }
            }

            VStack(spacing: 8) {
                if !manager.passwordlessReady {
                    Button("Enable passwordless") { enablePasswordless() }
                        .disabled(manager.isApplying)
                        .help("Один раз спросит пароль, дальше Apply без промптов")
                        .frame(maxWidth: .infinity)
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { manager.autostartEnabled },
                    set: { manager.setAutostartEnabled($0) }
                ))
                .disabled(manager.isApplying)
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
        .onChange(of: manager.isSSIDDisclosureAvailable) { available in
            // Подтверждение спрашивает ровно про эту ситуацию: если предложения больше нет
            // (согласие дали, отказали, сеть сменилась) — вопрос устарел, закрываем.
            if !available { isSSIDDisclosureConfirmVisible = false }
        }
        .onChange(of: manager.isWiFiInfoRedactionDisabled) { _ in
            // То же самое при смене обратного флага: иначе строка осталась бы висеть
            // над уже показанным именем сети.
            isSSIDDisclosureConfirmVisible = false
        }
        .onChange(of: manager.isApplying) { applying in
            // Ушли в системный вызов — показать вопрос не на чем.
            if applying { isSSIDDisclosureConfirmVisible = false }
        }
        .onChange(of: manager.lastSummary) { _ in
            // Зелёная надпись с последним действием гаснет спустя 5 сек.
            summaryClearWorkItem?.cancel()
            if manager.lastSummary != nil {
                let work = DispatchWorkItem { manager.lastSummary = nil }
                summaryClearWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            }
        }
    }

    /// Строка ошибки или успеха + крестик. Крестик обязателен: ошибка теперь живёт до
    /// следующей операции, а таймер гашения есть только у зелёной строки.
    private func messageRow(_ text: String, color: Color, help: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(text)
                .foregroundColor(color)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help(help)
        }
    }

    /// Ручное скрытие сообщений: таймер зелёной строки гасим, иначе он сработает
    /// по уже невидимому тексту. Ошибку таймером не гасим — её надо успеть прочитать.
    private func dismissMessages() {
        summaryClearWorkItem?.cancel()
        summaryClearWorkItem = nil
        manager.lastError = nil
        manager.lastSummary = nil
    }

    /// ВНИМАНИЕ, НЕ ВОЗВРАЩАТЬ В ТЕЛО ПОПОВЕРА: пользователь убрал карточку согласия
    /// из тела дважды — сначала в правый клик, потом вообще. Мешала именно она, а не фича:
    /// блок про «имя сети увидят все приложения» перебивал статус и DNS. Поэтому здесь
    /// только молчаливый переключатель, а следствие живёт одноразовым подтверждением
    /// под строкой Connected и только в момент первого включения.
    ///
    /// Значок показывает ТЕКУЩЕЕ состояние (`eye` — имя видно, `eye.slash` — скрыто),
    /// а наведение/клик — куда оно сдвинется. Оба символа различимы без подсказки,
    /// поэтому «видно или нет» читается с одного взгляда на строку.
    private var connectedSSIDHint: some View {
        Group {
            if manager.isWiFiInfoRedactionDisabled {
                Button {
                    // Направление «назад» ничего не раскрывает, поэтому подтверждения не спрашиваем.
                    manager.restoreWiFiInfoRedaction()
                } label: {
                    Image(systemName: "eye")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(manager.isApplying)
                .opacity(manager.isApplying ? 0.3 : 1)
                .animation(.easeOut(duration: 0.15), value: manager.isApplying)
                .help("Имя сети видно всем приложениям — нажмите, чтобы вернуть скрытие")
            } else if manager.isSSIDDisclosureAvailable {
                Button {
                    // Первое снятие скрытия — единственный раз, когда спрашиваем подтверждение.
                    if isSSIDDisclosureConfirmed {
                        manager.grantSSIDDisclosureConsent()
                    } else {
                        isSSIDDisclosureConfirmVisible = true
                    }
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(manager.isApplying)
                .opacity(manager.isApplying ? 0.3 : 1)
                .animation(.easeOut(duration: 0.15), value: manager.isApplying)
                .help("Имя сети скрыто настройкой macOS — нажмите, чтобы показать")
            }
        }
        .animation(.easeOut(duration: 0.18), value: manager.isSSIDDisclosureAvailable)
        .animation(.easeOut(duration: 0.18), value: manager.isWiFiInfoRedactionDisabled)
    }

    /// Одноразовое подтверждение первого снятия скрытия. Живёт ПОД строкой Connected,
    /// а не карточкой в теле: та пользователя раздражала. Одна строка последствия плюс
    /// две кнопки — по размеру меньше блока статуса, ничего не перекрывает.
    private var ssidConfirmationRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Имя сети станет читать всё ПО на этом Mac")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Показать") {
                isSSIDDisclosureConfirmed = true
                isSSIDDisclosureConfirmVisible = false
                manager.grantSSIDDisclosureConsent()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)
            .disabled(manager.isApplying)
            .help("Выключить скрытие имени сети на этом Mac")
            Button("Отмена") {
                // Отмена ничего не меняет в системе — просто закрываем подтверждение.
                isSSIDDisclosureConfirmVisible = false
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .help("Оставить имя скрытым")
        }
        .transition(.opacity)
    }

    /// DNS-блок поповера: строка статуса, список серверов с удалением, «+» с однострочным
    /// полем ввода и сброс на DHCP. Список не сворачивается — добавить сервер можно в любой момент.
    @ViewBuilder
    private var dnsSection: some View {
        let service = manager.activeServiceName() ?? "—"
        let servers = manager.activeDNSServers
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                // Хвост с количеством переживает обрезку середины, поэтому виден всегда.
                Text(dnsHeadline(service: service, servers: servers))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                dnsAddButton
            }
            if !servers.isEmpty {
                // Тонкая линия слева связывает строки с заголовком списка.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(servers, id: \.self) { server in
                        dnsRow(server)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 1)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeOut(duration: 0.18), value: servers)
            }
            if isDNSInputVisible {
                dnsInputRow
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Spacer()
                // Auto остаётся: ручной список — не единственный способ задать DNS.
                Button("Auto") {
                    manager.applyAutoDNS()
                }
                .disabled(manager.isApplying)
                .help("Вернуть DNS-серверы от DHCP")
            }
        }
    }

    /// Заголовок блока: ручные сервера списком либо строка, которую сейчас отдал DHCP.
    private func dnsHeadline(service: String, servers: [String]) -> String {
        if !servers.isEmpty {
            return "DNS (\(service)): \(servers.joined(separator: ", ")) (\(servers.count))"
        }
        if let name = manager.activeServiceName(),
           let dns = manager.currentDNS[name], !dns.isEmpty {
            return "DNS (\(name)): \(dns)"
        }
        return "DNS (\(service)): нет ручных серверов"
    }

    /// Кнопка «+»: раскрывает однострочное поле ровно для одного сервера.
    private var dnsAddButton: some View {
        Button {
            dnsInput = ""
            withAnimation(.easeOut(duration: 0.18)) { isDNSInputVisible = true }
            isDNSInputFocused = true
        } label: {
            Image(systemName: "plus.circle")
                .font(.caption)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .disabled(manager.isApplying)
        .opacity(manager.isApplying ? 0.3 : 1)
        .animation(.easeOut(duration: 0.15), value: manager.isApplying)
        .help("Добавить DNS-сервер")
    }

    /// Инлайн-поле: один сервер, Return — добавить, Esc — отменить и закрыть.
    private var dnsInputRow: some View {
        HStack(spacing: 6) {
            TextField("напр. 8.8.8.8", text: $dnsInput)
                .textFieldStyle(.roundedBorder)
                .focused($isDNSInputFocused)
                .onSubmit(commitDNSInput)
                .onExitCommand {
                    // Esc закрывает поле без обращения к менеджеру.
                    closeDNSInput()
                }
            Button {
                commitDNSInput()
            } label: {
                Image(systemName: "arrow.down")
                    .font(.caption)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            // Валидность адреса считает сам NetworkManager — здесь только гасим кнопку.
            .disabled(!canCommitDNSInput || manager.isApplying)
            .help(canCommitDNSInput ? "Добавить сервер" : "Нужен корректный адрес DNS")
        }
        .disabled(manager.isApplying)
        .opacity(manager.isApplying ? 0.3 : 1)
        .animation(.easeOut(duration: 0.15), value: manager.isApplying)
    }

    /// Return или кнопка-стрелка: пустое поле просто закрываем, остальное уходит в менеджер.
    private func commitDNSInput() {
        let value = dnsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { closeDNSInput(); return }
        // Мусор не отправляем, но текст оставляем — так его проще поправить, не набирать заново.
        guard canCommitDNSInput else { return }
        manager.addDNSServer(value)
        closeDNSInput()
    }

    private var canCommitDNSInput: Bool {
        NetworkManager.isValidDNS(dnsInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func closeDNSInput() {
        isDNSInputFocused = false
        withAnimation(.easeOut(duration: 0.18)) {
            dnsInput = ""
            isDNSInputVisible = false
        }
    }

    /// Строка одного DNS-сервера: адрес + удаление из активной службы.
    private func dnsRow(_ server: String) -> some View {
        HStack(spacing: 6) {
            Text(server)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                manager.removeDNSServer(server)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.caption)
                    .frame(width: 18, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .disabled(manager.isApplying)
            .opacity(manager.isApplying ? 0.3 : 1)
            .animation(.easeOut(duration: 0.15), value: manager.isApplying)
            .help("Удалить \(server)")
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
