#!/bin/bash
# Doble clic para probar que FanLite pueda mover los ventiladores de verdad.
# macOS pide la contraseña de administrador una vez; nadie más la ve.
set -u
cd "$(dirname "$0")/.."

BIN="build/FanLite.app/Contents/MacOS/FanLite"
LOG="$HOME/Library/Logs/FanLite.log"

echo "== FanLite: prueba de control de ventiladores =="
echo
echo "  1. macOS te va a pedir la contraseña de administrador."
echo "  2. Los ventiladores suben al 40% durante 6 segundos y vuelven solos a Auto."
echo "     (deberías escucharlos)"
echo

if [ ! -x "$BIN" ]; then
    echo "Falta el binario: corré scripts/build_app.sh primero."
    read -n 1 -s -r -p "Enter para cerrar"
    exit 1
fi

"$BIN" --selftest
echo "esperando a que termine la prueba…"
sleep 20

echo
echo "== últimas líneas de $LOG =="
tail -n 30 "$LOG"
echo
read -n 1 -s -r -p "Enter para cerrar esta ventana"
