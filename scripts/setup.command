#!/usr/bin/env bash
#
# Setup.command — полная установка NetworkManager из DMG.
#
# Запуск: дважды кликнуть по Setup.command внутри смонтированного DMG.
#
# Что делает:
#   1. Копирует NetworkManager.app в /Applications
#   2. Устанавливает passwordless sudo (один запрос пароля)
#   3. Регистрирует автозапуск при входе в систему
#
# Xcode не нужен — приложение уже собрано и лежит в этом DMG, скрипт только
# раскладывает файлы. Ошибка одного шага не роняет установку целиком: в конце
# печатается сводка, и окно держится на Enter (при двой-клике Terminal иначе
# просто закроется, не показав ни слова).
#
# Удаление:
#   bash Scripts/install-autostart.sh --remove
#   sudo rm -f /etc/sudoers.d/network-manager
#

set -euo pipefail

APP_NAME="NetworkManager.app"
APP_PATH="/Applications/${APP_NAME}"
DMG_SETUP_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${DMG_SETUP_DIR}/Scripts"
FAILED=false

echo "======================================"
echo " NetworkManager Setup"
echo "======================================"
echo ""

# --- 1. Копирование в /Applications ------------------------------------------
echo "==> [1/3] Установка приложения в /Applications..."
if pgrep -x NetworkManager >/dev/null 2>&1; then
  echo "    Завершаем запущенную копию..."
  pkill -x NetworkManager 2>/dev/null || true
  sleep 1
fi
if [ ! -d "${DMG_SETUP_DIR}/${APP_NAME}" ]; then
  echo "    ERROR: в этом DMG нет ${APP_NAME} — нечего устанавливать." >&2
  FAILED=true
else
  if [ -d "$APP_PATH" ]; then
    echo "    Обнаружена существующая версия, обновляем..."
    rm -rf "$APP_PATH"
  fi
  if cp -R "${DMG_SETUP_DIR}/${APP_NAME}" "$APP_PATH"; then
    echo "    OK: установлено в $APP_PATH"
  else
    echo "    ERROR: не удалось скопировать в /Applications — проверь права." >&2
    FAILED=true
  fi
fi

# --- 2. Passwordless sudo -----------------------------------------------------
echo ""
echo "==> [2/3] Настройка passwordless sudo..."
if [ ! -f "${SCRIPTS_DIR}/install-passwordless-sudo.sh" ]; then
  echo "    WARNING: install-passwordless-sudo.sh не найден, пропускаем."
  echo "             Приложение будет спрашивать пароль на каждое действие."
else
  echo "    Будет запрошен пароль администратора (один раз)."
  if ! bash "${SCRIPTS_DIR}/install-passwordless-sudo.sh"; then
    FAILED=true
    echo "    ERROR: passwordless sudo не установлен (см. вывод выше)." >&2
  fi
fi

# --- 3. Автозапуск ------------------------------------------------------------
echo ""
echo "==> [3/3] Настройка автозапуска..."
if [ ! -f "${SCRIPTS_DIR}/install-autostart.sh" ]; then
  echo "    WARNING: install-autostart.sh не найден, пропускаем."
  echo "             Приложение не будет стартовать само при входе."
elif ! bash "${SCRIPTS_DIR}/install-autostart.sh"; then
  FAILED=true
  echo "    ERROR: автозапуск не зарегистрирован (см. вывод выше)." >&2
fi

# --- Готово -------------------------------------------------------------------
echo ""
if [ "$FAILED" = true ]; then
  echo "======================================"
  echo " Установка завершилась с ошибками."
  echo "======================================"
  echo ""
  echo "Что-то не установилось — посмотри строки ERROR выше."
else
  echo "======================================"
  echo " Установка завершена!"
  echo "======================================"
  echo ""
  echo "NetworkManager запущен и будет автоматически стартовать при входе в систему."
fi

echo ""
echo "Управление:"
echo "  • Открыть приложение:  open -a NetworkManager"
echo "  • Удалить автозапуск:  bash ${SCRIPTS_DIR}/install-autostart.sh --remove"
echo "  • Удалить sudo права:  sudo rm /etc/sudoers.d/network-manager"
echo ""
read -p "Нажмите Enter для закрытия..."
