# Network Changer

Нативное Swift menu-bar приложение (macOS 13+, SwiftUI, `MenuBarExtra`).
Иконка в верхней панели (SF Symbol `network`), окно-поповер с двумя Toggle и статусом.

## Что делает

| Toggle 1 (профиль) | Toggle 2 (Wi-Fi) | Выполняемые действия |
|---|---|---|
| Work | ON | `switchtolocation ethernet_work` + `setairportpower <dev> on` + DNS `192.168.105.11` на все Wi-Fi сервисы |
| Home | ON | `switchtolocation ethernet_home` + `setairportpower <dev> on` + DNS `8.8.8.8` на все Wi-Fi сервисы |
| Work / Home | OFF | `setairportpower <dev> off` + `switchtolocation ethernet_work` / `ethernet_home` (активен Ethernet через Location) |

Переключение любого Toggle применяется автоматически, есть также кнопка **Apply**.
Статус показывает: активный Location (`-getcurrentlocation`), power Wi-Fi (`-getairportpower`),
DNS каждого Wi-Fi сервиса (`-getdnsservers`).

## Какие команды `networksetup` используются

Без привилегий (чтение):
- `networksetup -getcurrentlocation`
- `networksetup -listallhardwareports` — поиск Wi-Fi устройства (обычно `en0`)
- `networksetup -getairportpower <device>`
- `networksetup -listallnetworkservices` — из них Wi-Fi сервисы = имя содержит `Wi-Fi`/`AirPort`
- `networksetup -getdnsservers <service>`

С привилегиями (каждая — системный prompt пароля через
`osascript -e 'do shell script "..." with administrator privileges'`, без SMJobBless):
- `networksetup -switchtolocation ethernet_work` / `ethernet_home`
- `networksetup -setairportpower <device> on` / `off`
- `networksetup -setdnsservers <service> 192.168.105.11` / `8.8.8.8` (для каждого Wi-Fi сервиса)

Предварительно в системе должны существовать Locations `ethernet_work` и `ethernet_home`
(Системные настройки → Сеть → … → Locations).

## Как открыть и собрать

Требуется полный Xcode (не только Command Line Tools), macOS 13 SDK+.

```bash
open NetworkChanger.xcodeproj
```

В Xcode: scheme **NetworkChanger**, target — My Mac, `⌘R` для запуска,
`⌘B` для сборки. Подпись: ad-hoc (`CODE_SIGN_IDENTITY = "-"`), team не нужен.
Sandbox **не** включён (иначе `networksetup`/`osascript` блокировались бы).
`NSAppleEventsUsageDescription` добавлен в `Info.plist` (нужен для `osascript`).
`LSUIElement = true` — иконка только в menu bar, без иконки в Dock.

Проверка из терминала (когда доступен Xcode):

```bash
xcodebuild -project NetworkChanger.xcodeproj -scheme NetworkChanger -showBuildSettings
xcodebuild -project NetworkChanger.xcodeproj -scheme NetworkChanger -configuration Debug build
```

## Структура

- `NetworkChanger/NetworkChangerApp.swift` — `@main` App, `MenuBarExtra` + поповер
- `NetworkChanger/ContentView.swift` — два Toggle (профиль Work/Home, Wi-Fi ON/OFF), статус, Apply/Refresh
- `NetworkChanger/NetworkManager.swift` — вся обёртка над `networksetup` + `runPrivileged` через osascript
- `NetworkChanger/Info.plist` — `LSUIElement`, `NSAppleEventsUsageDescription`
