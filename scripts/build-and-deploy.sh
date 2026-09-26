#!/bin/bash
# Build + deploy NetworkManager via terminal.
# Usage: ./scripts/build-and-deploy.sh [--run] [--clean]
set -euo pipefail

PROJECT="NetworkManager.xcodeproj"
SCHEME="NetworkManager"
CONFIG="Release"
BUILD_DIR="$(pwd)/build"
APP_NAME="NetworkManager.app"
DEST="/Applications/${APP_NAME}"

RUN_AFTER=false
CLEAN=false
for arg in "$@"; do
  case "$arg" in
    --run) RUN_AFTER=true ;;
    --clean) CLEAN=true ;;
    *) echo "Unknown arg: $arg (allowed: --run --clean)"; exit 1 ;;
  esac
done

if ! command -v xcodebuild >/dev/null; then
  echo "error: нужен полный Xcode (xcodebuild не найден, стоят только CLT)"
  exit 1
fi

if [ "$CLEAN" = true ]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR" scripts

echo "==> Building ${SCHEME} (${CONFIG})..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  build

BUILT_APP="$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME" -type d | head -n 1)"
if [ -z "${BUILT_APP:-}" ]; then
  echo "error: .app не найден в $BUILD_DIR/DerivedData"
  exit 1
fi
echo "==> Built: $BUILT_APP"

echo "==> Deploying to $DEST..."
if pkill -x NetworkManager 2>/dev/null; then
  sleep 1
fi
rm -rf "$DEST"
cp -R "$BUILT_APP" "$DEST"
echo "==> Deployed: $DEST"

if [ "$RUN_AFTER" = true ]; then
  echo "==> Launching..."
  open "$DEST"
fi

echo "done."
