#!/bin/bash
# Arma dist/FanLite-<version>.dmg y dist/FanLite-<version>.zip desde build/FanLite.app.
# Si la app no existe (o si se pasa --build) primero corre scripts/build_app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/FanLite.app"
if [ "${1:-}" = "--build" ] || [ ! -d "$APP" ]; then
    scripts/build_app.sh
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DIST="dist"
mkdir -p "$DIST"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/FanLite.app"
ln -s /Applications "$STAGE/Applications"

DMG="$DIST/FanLite-$VERSION.dmg"
ZIP="$DIST/FanLite-$VERSION.zip"
rm -f "$DMG" "$ZIP"
# El ZIP primero: si hdiutil no puede crear el DMG, al menos queda el ZIP.
ditto -c -k --keepParent "$APP" "$ZIP"
hdiutil create -volname "FanLite $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
( cd "$DIST" && shasum -a 256 "FanLite-$VERSION.dmg" "FanLite-$VERSION.zip" > SHA256SUMS.txt )

echo "listo: $PWD/$DMG"
echo "listo: $PWD/$ZIP"
echo "listo: $PWD/$DIST/SHA256SUMS.txt"
