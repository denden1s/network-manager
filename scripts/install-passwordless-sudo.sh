#!/usr/bin/env bash
#
# install-passwordless-sudo.sh — один запрос пароля при установке, дальше ноль промптов.
#
# Идемпотентно создаёт /etc/sudoers.d/network-manager с NOPASSWD-allowlist
# только для команд, которые использует NetworkManager.
#
# Запуск:
#   ./scripts/install-passwordless-sudo.sh
#   sudo ./scripts/install-passwordless-sudo.sh
# (пароль спрашивается один раз в начале; дальше всё идёт через sudo -n без промптов)
#
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/network-manager"
# Сужение до regex пробовалось и ПРОВАЛИЛОСЬ на живой машине, поэтому здесь wildcard.
# sudo склеивает argv в одну строку и матчит её так, что `^[^ ]+ (on|off)$` не
# подошёл ни к `-setairportpower en0 on`, ни к `-setnetworkserviceenabled Wi-Fi on`
# (sudo -n отдавал «password is required» на обоих). Не выяснено, включается ли в
# склейку подкоманда и как именно, — а проверять это можно только установкой
# sudoers, которая требует пароль root. Риск тут неприемлемый: сломанное правило
# означает osascript-диалог пароля на переключении Wi-Fi и служб, то есть ровно тот
# баг, ради которого и существует passwordless-режим.
# Эскалации через wildcard нет: бинарь матчится по абсолютному пути, шелл не участвует,
# аргументы передаются массивом, а значения проверены isValidDNS до вызова sudo.
# Единственное правило с regex — sethidewifiinfo — проверено вживую (работает).
ALLOWLIST='%admin ALL=(root) NOPASSWD: /usr/sbin/networksetup -setairportpower *, /usr/sbin/networksetup -setnetworkserviceenabled *, /usr/sbin/networksetup -setdnsservers *, /usr/sbin/ipconfig ^sethidewifiinfo (0|1|default)$, /usr/bin/dscacheutil -flushcache, /usr/bin/killall ^-HUP mDNSResponder$'

# Один запрос пароля на весь скрипт (кеширует timestamp для последующих sudo -n).
sudo -v

# Стейдж создаём через sudo mktemp: /tmp доступен всем локальным юзерам, а
# predictable-имя (тем более уже существующий файл или симлинк) позволило бы
# перехватить запись — sudo tee пишет по ссылке, то есть от root в чужой файл.
STAGE_FILE=""
cleanup() {
    if [[ -n "$STAGE_FILE" ]]; then
        sudo -n rm -f "$STAGE_FILE" >/dev/null 2>&1 || true
    fi
}
# Ловим и INT/TERM, не только EXIT: прерывание между tee и install иначе
# оставляет root-файл в /tmp.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Содержимое фиксировано, повторный запуск даёт тот же текст (идемпотентность).
STAGE_FILE="$(sudo mktemp /tmp/network-manager-sudoers.XXXXXX)"
printf '%s\n' "$ALLOWLIST" | sudo tee "$STAGE_FILE" > /dev/null

# Валидируем ДО установки на место: /etc/sudoers.d включается глобально, и
# битый файл ломает sudo для всех до правки руками (даже не наш sudoers).
if ! sudo visudo -cf "$STAGE_FILE"; then
    echo "ERROR: allowlist не проходит visudo, $SUDOERS_FILE не тронут" >&2
    exit 1
fi

# Ставим на место с правами 0440.
sudo install -m 0440 "$STAGE_FILE" "$SUDOERS_FILE"
# Стейдж убираем сразу (trap остаётся страховкой на прерывание): через 5 минут
# истекает timestamp и sudo -n в trap уже не смог бы убрать файл.
sudo rm -f "$STAGE_FILE"
STAGE_FILE=""

# Страховка после установки: если что-то пошло не так (другая ФС, битый mount),
# файл всё равно не должен остаться сломанным.
if ! sudo visudo -cf "$SUDOERS_FILE" > /dev/null; then
    sudo rm -f "$SUDOERS_FILE"
    echo "ERROR: sudoers validation failed, removed $SUDOERS_FILE" >&2
    exit 1
fi

# Финальная проверка passwordless-пути без промпта.
# `sudo -n true` проверяет только свежесть timestamp (при запуске от root он
# проходит вообще без allowlist), поэтому список правил смотрим отдельно —
# тем же `sudo -n -l`, что и приложение.
if ! sudo -n true; then
    echo "ERROR: sudo -n не проходит без пароля" >&2
    exit 1
fi
if ! sudo -n -l 2>/dev/null | grep -q 'NOPASSWD.*networksetup'; then
    echo "WARNING: NOPASSWD-allowlist не виден в sudo -n -l (скрипт запущен от root?)" >&2
fi

# Последний пункт отключает системную маскировку имени Wi-Fi сети
# (HideWiFiInfo). Это нужно, чтобы в приложении было видно, к какой сети
# подключён Mac. Возврат: sudo ipconfig sethidewifiinfo default.
# Команда из allowlist, поэтому работает и без пароля — это и есть главная
# проверка, что allowlist действительно работает, а не закэширован timestamp.
sudo -n /usr/sbin/ipconfig sethidewifiinfo 0

# Проверяем, что маскировка действительно снята и SSID читается.
# Проверка непривилегированная — именно так читает и приложение.
DEV="$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi|AirPort/{getline; print $2; exit}')"
SSID_LINE="$(ipconfig getsummary "$DEV" 2>/dev/null | awk -F ' SSID : ' '/ SSID : / {print $2; exit}' || true)"
if [ -z "$DEV" ]; then
    echo "WARNING: Wi-Fi порт не найден в networksetup, проверка SSID не выполнена." >&2
elif [ "$SSID_LINE" = "<redacted>" ]; then
    echo "WARNING: sethidewifiinfo отработал, но SSID всё ещё <redacted>" >&2
    echo "         (возможно, радиомодуль выключен — включите Wi-Fi и перезапустите)" >&2
elif [ -z "$SSID_LINE" ]; then
    echo "WARNING: SSID пуст — вероятно, Wi-Fi не подключён. Проверка не выполнена." >&2
else
    echo "OK: SSID читается, сеть '$SSID_LINE'"
fi

echo "OK: passwordless sudo installed at $SUDOERS_FILE"
