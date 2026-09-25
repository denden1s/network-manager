#!/usr/bin/env bash
#
# install-passwordless-sudo.sh — один запрос пароля при установке, дальше ноль промптов.
#
# Идемпотентно создаёт /etc/sudoers.d/network-changer с NOPASSWD-allowlist
# только для команд, которые использует NetworkChanger.
#
# Запуск вручную:
#   sudo ./scripts/install-passwordless-sudo.sh
# (sudo спросит пароль один раз в начале; дальше всё идёт через sudo -n без промптов)
#
set -euo pipefail

SUDOERS_FILE="/etc/sudoers.d/network-changer"
STAGE_FILE="/tmp/network-changer-sudoers.stage"
ALLOWLIST='%admin ALL=(root) NOPASSWD: /usr/sbin/networksetup -setairportpower *, /usr/sbin/networksetup -setnetworkserviceenabled *, /usr/sbin/networksetup -setdnsservers *, /usr/bin/dscacheutil -flushcache, /usr/bin/killall -HUP mDNSResponder'

# Один запрос пароля на весь скрипт (кеширует timestamp для последующих sudo -n).
sudo -v

# Готовим содержимое локально (идемпотентно — повторный запуск даёт тот же текст).
TMP_LOCAL="$(mktemp /tmp/network-changer-sudoers.XXXXXX)"
trap 'rm -f "$TMP_LOCAL"' EXIT
printf '%s\n' "$ALLOWLIST" > "$TMP_LOCAL"

# Пишем во временный файл через sudo tee, затем ставим на место с правами 0440.
sudo tee "$STAGE_FILE" > /dev/null < "$TMP_LOCAL"
sudo install -m 0440 "$STAGE_FILE" "$SUDOERS_FILE"
sudo rm -f "$STAGE_FILE"

# Обязательная валидация синтаксиса; при ошибке — удалить файл и выйти nonzero.
if ! sudo visudo -cf "$SUDOERS_FILE"; then
    sudo rm -f "$SUDOERS_FILE"
    echo "ERROR: sudoers validation failed, removed $SUDOERS_FILE" >&2
    exit 1
fi

# Финальная проверка passwordless-пути без промпта.
sudo -n true
sudo -n /usr/sbin/networksetup -getairportpower en0

echo "OK: passwordless sudo installed at $SUDOERS_FILE"
