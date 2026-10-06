#!/usr/bin/env bash
#
# install-autostart.sh — регистрирует NetworkManager в LaunchAgents
# для автозапуска при входе пользователя в систему.
#
# Идемпотентно: повторный запуск перезаписывает plist и перезагружает агент.
#
# Запуск:
#   ./scripts/install-autostart.sh
#
# Удаление:
#   ./scripts/install-autostart.sh --remove
#
set -euo pipefail

LABEL="com.networkmanager.app"
PLIST_NAME="${LABEL}.plist"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENTS_DIR}/${PLIST_NAME}"
APP_PATH="/Applications/NetworkManager.app"

# --- Удаление ----------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
    if [[ -f "$PLIST_PATH" ]]; then
        launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "OK: autostart removed ($PLIST_PATH deleted)"
    else
        echo "OK: autostart not installed, nothing to remove"
    fi
    exit 0
fi

# --- Проверка наличия приложения ---------------------------------------------
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: $APP_PATH not found" >&2
    echo "       Build and install first: ./scripts/build-and-deploy.sh" >&2
    exit 1
fi

# --- Создание директории LaunchAgents -----------------------------------------
mkdir -p "$LAUNCH_AGENTS_DIR"

# --- Генерация plist ----------------------------------------------------------
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>${APP_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/${LABEL}.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${LABEL}.err.log</string>
</dict>
</plist>
PLIST

# --- (Перезагрузка агента ----------------------------------------------------
# Сначала bootout (игнорируем ошибку, если агент не был загружен).
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true

# Затем bootstrap. stderr launchctl не глушим — там причина, но добавляем
# понятную строку, чтобы по выводу было видно, что именно не так.
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"; then
    echo "ERROR: launchctl bootstrap failed (см. вывод launchctl выше)" >&2
    exit 1
fi

# --- Проверка -----------------------------------------------------------------
if launchctl print "gui/$(id -u)/${LABEL}" &>/dev/null; then
    echo "OK: autostart installed — NetworkManager will launch at login"
    echo "    plist: $PLIST_PATH"
    echo "    logs:  /tmp/${LABEL}.out.log, /tmp/${LABEL}.err.log"
else
    echo "ERROR: failed to load LaunchAgent" >&2
    exit 1
fi
