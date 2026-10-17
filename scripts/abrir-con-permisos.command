#!/bin/bash
# Doble clic: abre FanLite con permisos de administrador desde la Terminal.
# Es el camino manual, por si el diálogo de la app no anda en tu Mac.
set -u
cd "$(dirname "$0")/.."

BIN="$PWD/build/FanLite.app/Contents/MacOS/FanLite"
[ -x "$BIN" ] || { echo "falta el binario: corré primero scripts/build_app.sh"; read -n1 -s -r -p "Enter para cerrar"; exit 1; }

echo "FanLite con permisos: la contraseña se escribe acá abajo."
echo "Para cerrarlo: Ctrl-C en esta ventana (o el botón Salir del panel)."
echo "Si cerrás la ventana, FanLite se apaga y los ventiladores vuelven a Auto."
echo
exec sudo "$BIN" --run
