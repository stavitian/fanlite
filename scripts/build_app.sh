#!/bin/bash
# Arma build/FanLite.app. Usa Developer ID si hay una única identidad disponible.
# SIGNING_IDENTITY permite elegir certificado; '-' fuerza firma ad-hoc para uso local.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning | sed -n '/"Developer ID Application:/s/.*) \([A-Fa-f0-9]*\) .*/\1/p')"
    COUNT="$(printf '%s\n' "$IDENTITIES" | sed '/^$/d' | wc -l | tr -d ' ')"
    case "$COUNT" in
        0) SIGNING_IDENTITY="-" ;;
        1) SIGNING_IDENTITY="$IDENTITIES" ;;
        *) echo "Hay varias identidades Developer ID. Elegí una con SIGNING_IDENTITY." >&2; exit 1 ;;
    esac
fi

swift build -c "$CONFIG"

APP="build/FanLite.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/FanLite" "$APP/Contents/MacOS/FanLite"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp scripts/askpass.sh "$APP/Contents/Resources/askpass.sh"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/MacOS/FanLite" "$APP/Contents/Resources/askpass.sh"

if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - --options runtime "$APP"
    echo "aviso: firma ad-hoc para uso local; no apta para notarización" >&2
else
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "listo: $PWD/$APP"
echo "para probarlo:   open $APP"
echo "autotest:        \"$PWD/$APP/Contents/MacOS/FanLite\" --selftest"
