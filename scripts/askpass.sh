#!/bin/sh
# Pide la contraseña de administrador con un diálogo de macOS.
# Lo llama sudo (SUDO_ASKPASS): la contraseña va por stdout directo a sudo y no pasa por otro lado.
exec /usr/bin/osascript -e 'try
	set r to display dialog "FanLite necesita permiso de administrador para mover los ventiladores.

Es una sola vez por arranque: no instala ningún helper ni servicio." default answer "" with hidden answer buttons {"Cancelar", "Continuar"} default button "Continuar" with title "FanLite" with icon caution
	return text returned of r
on error number -128
	return ""
end try'
