#!/bin/bash
# Build DMG for NetworkManager distribution.
# Usage: ./scripts/create-dmg.sh [--clean]
set -euo pipefail

PROJECT="NetworkManager.xcodeproj"
SCHEME="NetworkManager"
CONFIG="Release"
BUILD_DIR="$(pwd)/build"
APP_NAME="NetworkManager.app"
DMG_NAME="NetworkManager.dmg"
SCRIPTS_DIR="$(dirname "$0")"

CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=true ;;
    *) echo "error: unknown arg: $arg (allowed: --clean)" >&2; exit 1 ;;
  esac
done

if ! command -v xcodebuild >/dev/null; then
  echo "error: нужен полный Xcode (xcodebuild не найден, стоят только CLT)" >&2
  exit 1
fi

if [ ! -d "$PROJECT" ]; then
  echo "error: $PROJECT не найден — запускай скрипт из корня репозитория" >&2
  exit 1
fi

if [ "$CLEAN" = true ]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

echo "==> Building ${SCHEME} (${CONFIG})..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  build

# `|| true`: head закрывает пайп после первой строки, find ловит SIGPIPE — без
# этого pipefail+set -e роняют скрипт на успешной сборке.
BUILT_APP="$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME" -type d | head -n 1 || true)"
if [ -z "${BUILT_APP:-}" ]; then
  echo "error: .app не найден в $BUILD_DIR/DerivedData" >&2
  exit 1
fi
echo "==> Built: $BUILT_APP"

# Сборка DMG многошаговая и падает на любом шаге, поэтому временная папка
# убирается и на ошибке, а не только в конце (иначе мусор в TMP после Ctrl-C).
DMG_TMP=""
cleanup() {
  if [ -n "$DMG_TMP" ]; then
    rm -rf "$DMG_TMP"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "==> Creating DMG..."
DMG_TMP="$(mktemp -d)"
# Spotlight индексирует staging-папку и держит на файлах ресурсы, пока hdiutil
# их читает — метка отключает индексацию и снимает этот класс помех.
touch "$DMG_TMP/.metadata_never_index"
cp -R "$BUILT_APP" "$DMG_TMP/"
ln -s /Applications "$DMG_TMP/Applications"

# Копируем Setup.command и скрипты установки
cp "$SCRIPTS_DIR/setup.command" "$DMG_TMP/"
chmod +x "$DMG_TMP/setup.command"
mkdir -p "$DMG_TMP/Scripts"
cp "$SCRIPTS_DIR/install-passwordless-sudo.sh" "$DMG_TMP/Scripts/"
cp "$SCRIPTS_DIR/install-autostart.sh" "$DMG_TMP/Scripts/"
chmod +x "$DMG_TMP/Scripts/"*.sh

rm -f "$DMG_NAME"
# На GitHub-раннерах hdiutil периодически падает с «Resource busy»: XProtectBehaviorService
# и Spotlight в этот момент держат ресурсы диска. Команда у нас корректная, это флаки
# окружения, поэтому не чиним вызов, а повторяем его.
DMG_CREATED=false
for attempt in 1 2 3 4 5; do
  # Прошлый упавший запуск мог оставить том смонтированным — снимаем перед новой попыткой.
  hdiutil detach -force "/Volumes/Network Manager" >/dev/null 2>&1 || true
  if hdiutil create -volname "Network Manager" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_NAME"; then
    DMG_CREATED=true
    break
  fi
  # hdiutil при ошибке может оставить огрызок образа — он негодный, убираем.
  rm -f "$DMG_NAME"
  if [ "$attempt" -lt 5 ]; then
    echo "==> hdiutil не справился (попытка $attempt/5), повтор через $((attempt * 5)) с" >&2
    sleep $((attempt * 5))
  fi
done

if [ "$DMG_CREATED" != true ]; then
  rm -f "$DMG_NAME"
  echo "error: hdiutil create не удался после 5 попыток (см. вывод выше)" >&2
  exit 1
fi

rm -rf "$DMG_TMP"
DMG_TMP=""

echo "==> DMG created: $DMG_NAME"
ls -lh "$DMG_NAME"
