#!/bin/bash
# Arma build/FanLite.app a partir del binario de release. Firma ad-hoc: no hace falta
# cuenta de desarrollador de Apple.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

APP="build/FanLite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/FanLite" "$APP/Contents/MacOS/FanLite"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/askpass.sh "$APP/Contents/Resources/askpass.sh"
chmod +x "$APP/Contents/MacOS/FanLite" "$APP/Contents/Resources/askpass.sh"

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "aviso: no se pudo firmar (igual funciona)"

echo "listo: $PWD/$APP"
echo "para probarlo:   open $APP"
echo "autotest:        \"$PWD/$APP/Contents/MacOS/FanLite\" --selftest"
