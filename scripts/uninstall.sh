#!/usr/bin/env bash
#
# uninstall.sh — полное удаление NetworkManager с машины разработчика.
#
# Идемпотентно: безопасно запускать повторно, отсутствующие компоненты пропускаются.
#
# Что удаляет (по порядку):
#   1. LaunchAgent-автозапуск (unload + plist)
#   2. Запущенное приложение + /Applications/NetworkManager.app
#   3. Passwordless sudo (/etc/sudoers.d/network-manager, через sudo)
#   4. Логи агента в /tmp и preferences
#
# НЕ трогает (удалить вручную при необходимости):
#   - Login Item через SMAppService (тоггл "Launch at login" в приложении):
#     выключи тоггл в поповере ДО запуска скрипта, иначе в
#     System Settings → General → Login Items останется висячая запись —
#     удали её там кнопкой "–".
#   - Исходники и build/ в репозитории.
#
# Запуск:
#   ./scripts/uninstall.sh
#

set -euo pipefail

LABEL="com.networkmanager.app"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
APP_PATH="/Applications/NetworkManager.app"
SUDOERS_FILE="/etc/sudoers.d/network-manager"

echo "======================================"
echo " NetworkManager Uninstall"
echo "======================================"
echo ""

# --- 1. LaunchAgent -----------------------------------------------------------
echo "==> [1/4] LaunchAgent..."
if [[ -f "$PLIST_PATH" ]]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "    OK: removed $PLIST_PATH"
else
    echo "    SKIP: $PLIST_PATH not found"
fi

# --- 2. Приложение -------------------------------------------------------------
echo "==> [2/4] Application..."
if pgrep -x NetworkManager >/dev/null 2>&1; then
    pkill -x NetworkManager 2>/dev/null || true
    sleep 1
    echo "    OK: stopped running instance"
else
    echo "    SKIP: not running"
fi
if [[ -d "$APP_PATH" ]]; then
    rm -rf "$APP_PATH"
    echo "    OK: removed $APP_PATH"
else
    echo "    SKIP: $APP_PATH not found"
fi

# --- 3. Passwordless sudo ------------------------------------------------------
echo "==> [3/4] Passwordless sudo..."
if [[ -f "$SUDOERS_FILE" ]]; then
    # Защита от удаления чужого файла: наш содержит networksetup-allowlist.
    if grep -q "networksetup" "$SUDOERS_FILE" 2>/dev/null; then
        echo "    Запрошен пароль администратора (один раз)."
        # Не даём set -e уронить скрипт на отменённом prompt: файл тогда
        # остаётся, и финальная проверка ниже отрапортует FAIL.
        if ! sudo rm -f "$SUDOERS_FILE"; then
            echo "    ERROR: не удалось удалить $SUDOERS_FILE (см. вывод sudo выше)." >&2
        else
            echo "    OK: removed $SUDOERS_FILE"
        fi
    else
        echo "    WARNING: $SUDOERS_FILE не похож на наш (нет networksetup) — пропускаем, удали вручную."
    fi
else
    echo "    SKIP: $SUDOERS_FILE not found"
fi

# --- 4. Логи и preferences ------------------------------------------------------
echo "==> [4/4] Logs & preferences..."
rm -f "/tmp/${LABEL}.out.log" "/tmp/${LABEL}.err.log"
rm -f "${HOME}/Library/Preferences/local.NetworkManager.plist"
echo "    OK: cleaned"

# --- Проверка -------------------------------------------------------------------
echo ""
echo "==> Проверка..."
FAILED=false
for path in "$APP_PATH" "$PLIST_PATH" "$SUDOERS_FILE"; do
    if [[ -e "$path" ]]; then
        echo "    FAIL: still exists: $path"
        FAILED=true
    fi
done
if pgrep -x NetworkManager >/dev/null 2>&1; then
    echo "    FAIL: process still running"
    FAILED=true
fi

echo ""
if [[ "$FAILED" == true ]]; then
    echo "Uninstall incomplete — см. FAIL выше."
    exit 1
fi
echo "======================================"
echo " NetworkManager полностью удалён."
echo "======================================"
echo ""
echo "Напоминание: если был включён тоггл \"Launch at login\" в приложении —"
echo "проверь System Settings → General → Login Items и удали запись кнопкой \"–\"."
