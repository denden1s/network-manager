# Network Manager

Нативное Swift menu-bar приложение (macOS 13+, SwiftUI, `MenuBarExtra`).
Иконка в верхней панели (динамическая: `wifi` / `cable.connector`), окно-поповер:
список всех сетевых служб с тогглами + статус (IP, шлюз, DNS, подключение).

## Quick Start: от исходников до запущенного приложения

1. Требования: macOS 15 Sequoia, полный Xcode 16.x (не только Command Line Tools).
   Проверка: `xcodebuild -version` (Xcode 26.x на Sequoia НЕ работает — битые плагины).
2. Привяжи Xcode:
   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   xcodebuild -runFirstLaunch
   ```
3. Сборка + установка в `/Applications` + запуск:
   ```bash
   ./scripts/build-and-deploy.sh --run
   ```
   Флаги: `--clean` — чистая сборка; без `--run` — только собрать и положить.
   Или вручную из Xcode: `open NetworkManager.xcodeproj`, scheme **NetworkManager**, `⌘R`.
4. Один раз включи passwordless: кнопка **Enable passwordless** в поповере
   (один промпт пароля; скрипт должен лежать в Resources бандла — см. ниже)
   или из терминала:
   ```bash
   sudo ./scripts/install-passwordless-sudo.sh
   ```
   Дальше все тогглы — без запросов пароля. Откат:
   ```bash
   sudo rm /etc/sudoers.d/network-manager
   ```
5. Пользуйся: включаешь одну службу — остальные не-VPN гаснут сами
   (эксклюзивный режим); VPN-службы не трогаются. Статус внизу показывает
   IP, шлюз и DNS активной службы. Правый клик по иконке трея — меню с Quit.

## Что делает

- Список всех сетевых служб (`networksetup -listallnetworkservices`), у каждой свой on/off тоггл.
- Эксклюзивность: включается одна не-VPN служба, остальные не-VPN выключаются
  (служба с «vpn» в имени не затрагивается никогда).
- Wi-Fi служба: дополнительно управляет радиомодулем (`setairportpower`) —
  при включении идёт фоновый скан `airport -s` (режим поиска, список сетей
  обновляется для Control Center), система сама джойнится к известной сети.
- Статус: IP (Wi-Fi либо активной проводной службы), шлюз по умолчанию,
  DNS активной службы (нижняя строка), SSID/подключение.
- Пароль: один раз при установке passwordless, дальше `sudo -n` без промптов;
  без allowlist — fallback на системный промпт через osascript.

## Какие команды используются

Без привилегий (чтение):
- `networksetup -listallnetworkservices` — все службы (включая выключенные)
- `networksetup -getnetworkserviceenabled <service>` — вкл/выкл
- `networksetup -listallhardwareports` — поиск Wi-Fi устройства (обычно `en0`)
- `networksetup -getairportpower <device>`, `-getdnsservers <service>`, `-getinfo <service>` (IP)
- `/sbin/route -n get default` — шлюз
- `airport -s` — фоновый скан сетей (deprecated-утилита, warning игнорируется)

С привилегиями (через `sudo -n` при установленном allowlist, иначе osascript-промпт):
- `networksetup -setnetworkserviceenabled <service> on|off`
- `networksetup -setairportpower <device> on|off`
- `dscacheutil -flushcache`, `killall -HUP mDNSResponder` (после смены DNS)

## Passwordless (один пароль навсегда)

Приложение использует sudoers-allowlist (GUI НЕ запускается под root, SMJobBless НЕ используется).

Как включить:
1. Кнопка **Enable passwordless** в поповере (рядом с Quit) — один системный
   промпт, дальше всё без запросов. Кнопка прячется сама, когда режим активен
   (проверка `sudo -n -l` на наличие NOPASSWD-правила при каждом refresh).
2. Или вручную: `sudo ./scripts/install-passwordless-sudo.sh`

Что пишется в sudoers: файл `/etc/sudoers.d/network-manager` (права `0440`,
синтаксис проверяется через `visudo -cf`):
```
%admin ALL=(root) NOPASSWD: /usr/sbin/networksetup -setairportpower *, /usr/sbin/networksetup -setnetworkserviceenabled *, /usr/sbin/networksetup -setdnsservers *, /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder
```

Как это работает: `runPrivilegedBin` запускает целевой бинарь напрямую через
`sudo -n <бинарь> <аргументы>` без `sh`-посредника (иначе sudoers не матчится —
sudo смотрит на запускаемый бинарь) и только без allowlist показывает промпт через osascript.

Как откатить: `sudo rm /etc/sudoers.d/network-manager`

Важно для сборки: `scripts/install-passwordless-sudo.sh` должен попадать в Resources
приложения (кнопка ищет его в `Bundle.main.resourcePath`), иначе установка из UI
упадёт с ошибкой «Script not found in app Resources». `*.pbxproj` здесь не правится —
добавь файл в Xcode вручную: Target → Build Phases → Copy Files (Destination: Resources,
Subpath пустой) → `+` → `scripts/install-passwordless-sudo.sh`.

## Сборка

Требуется полный Xcode (не только Command Line Tools), macOS 13 SDK+.
Подпись: ad-hoc (`CODE_SIGN_IDENTITY = "-"`), team не нужен.
Sandbox **не** включён (иначе `networksetup`/`osascript` блокировались бы).
`NSAppleEventsUsageDescription` в `Info.plist` (нужен для `osascript`-fallback).
`LSUIElement = true` — иконка только в menu bar, без иконки в Dock.
Правый клик по иконке трея — меню с Quit (AppDelegate + локальный монитор
правой кнопки только на нашей статус-иконке, левый клик и поповер не тронуты).

## Структура

- `NetworkManager/NetworkManagerApp.swift` — `@main` App, `MenuBarExtra` + AppDelegate (правый клик → Quit)
- `NetworkManager/ContentView.swift` — список служб с тогглами, статус (IP/шлюз/DNS/Connected), Enable passwordless, Quit
- `NetworkManager/NetworkManager.swift` — обёртка над `networksetup`/`route`/`airport`: чтение без привилегий, изменения через `sudo -n` с fallback на osascript
- `NetworkManager/Info.plist` — `LSUIElement`, `NSAppleEventsUsageDescription`
- `scripts/build-and-deploy.sh` — сборка Release + установка в `/Applications` (`--run` — запустить, `--clean` — чистая сборка)
- `scripts/install-passwordless-sudo.sh` — установка sudoers-allowlist (один пароль)
