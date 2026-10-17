# FanLite

Control de ventiladores para Macs Apple Silicon: **una curva de temperatura y un botón de máximo**.
Nada más. Un solo proceso, sin helper, sin daemon, sin LaunchAgent, sin LaunchDaemon.

Nació de FanPilot (https://github.com/zyvren/FanPilot), que funciona bien pero trae mucho más de lo
que hace falta: catálogo de sensores por modelo, reglas de Auto Boost, logging CSV, notificaciones,
CLI, ventana de sensores, atajos globales, tres paneles de ajustes. FanLite se queda con lo útil.

## Qué hace

- **Curva**: arrastrás los puntos (temperatura → % de ventilador) y los ventiladores la siguen en vivo.
- **Máx**: ventiladores al máximo, un clic.
- **Auto**: se los devuelve a macOS.
- **Temperatura en la barra de menú** y velocidades en el panel.

## Qué se dejó afuera a propósito

| FanPilot | FanLite |
|---|---|
| App + daemon root (2 procesos, socket, leases, peer auth) | 1 proceso, se reabre como root una vez |
| Catálogo de sensores por modelo + clasificador | descubrimiento de claves `Tp*/Tm*/Tg*` una vez, cacheado |
| Auto Boost por reglas, por fuente de energía | — |
| Logging CSV, notificaciones, atajos, CLI, ventana de sensores | — |
| ~120 archivos fuente | 5 archivos Swift + la capa C del SMC |

## Números en esta Mac (MacBook Pro M5 Pro, Mac17,9, macOS 27.2)

| | FanPilot | FanLite |
|---|---|---|
| Procesos | 2 (app + helper root) | 1 |
| Memoria (footprint) | 42 MB + 5 MB | **15 MB** |
| CPU con la curva andando | ~3.7 % | **~0.3 %** |
| Archivos que instala en el sistema | daemon en /Library/PrivilegedHelperTools, plist en /Library/LaunchDaemons, socket, /var/log | **ninguno** |

## Cómo se usa

```sh
scripts/build_app.sh          # arma build/FanLite.app
open build/FanLite.app        # queda en la barra de menú
```

Arranca **en modo lectura** (temperaturas y RPM, sin tocar nada). La primera vez que elegís
**Curva** o **Máx**, FanLite te avisa y pide la contraseña de administrador con un diálogo de macOS:
se reabre él mismo como root (`sudo -A`) y sigue siendo **un solo proceso**. No instala nada.
Cuando lo cerrás (botón Salir, ⌘Q, Ctrl-C, SIGTERM), los ventiladores vuelven a Auto.

Si el diálogo no aparece en tu Mac, hay dos caminos manuales que hacen lo mismo:

```
scripts/abrir-con-permisos.command    # doble clic: pide la contraseña en la Terminal y abre FanLite como root
sudo "build/FanLite.app/Contents/MacOS/FanLite" --run
```

Probar que el control funciona de verdad (sube los ventiladores 6 s y los devuelve):

```
scripts/probar-control.command     # doble clic, pide contraseña, muestra el resultado
```

Modos de diagnóstico (no tocan el hardware):

```sh
BIN=build/FanLite.app/Contents/MacOS/FanLite
$BIN --dump         # sensores, límites y estado de los ventiladores
$BIN --simulate     # 24 comprobaciones de la lógica de control contra un SMC falso
```

## Cómo funciona

```
FanLite (un solo proceso)
  ├── SMC.swift        cliente AppleSMC: leer claves, escribir modo y objetivo
  ├── Controller.swift loop de 2 s: temperatura → curva → RPM, y reafirma si macOS lo pisa
  ├── UI.swift         barra de menú + editor de curva (AppKit, sin SwiftUI)
  ├── Simulate.swift   SMC falso + 24 comprobaciones de la lógica (--simulate)
  └── main.swift       --dump / --selftest / --simulate / arranque
```

- Los ventiladores se leen y escriben con las claves estándar: `F<n>Ac` (real), `F<n>Tg` (objetivo),
  `F<n>Mn`/`F<n>Mx` (límites), `F<n>md` (modo: 0 = macOS, 1 = manual).
- La temperatura de la curva es el **máximo** de hasta 18 sensores de CPU y GPU (`Tp*`, `Tm*`, `Tg*`),
  elegidos repartidos entre familias la primera vez y guardados para no volver a recorrer el SMC.
  Se suaviza con un promedio exponencial (0.4) para que el ventilador no haga escalones por el
  ruido de un núcleo; el failsafe mira la temperatura cruda.
- Cada 2 s se relee el objetivo real: si macOS (thermalmonitord) lo cambió, se reescribe.
  Si el sistema gana la pulseada, se nota en el panel.
- Límites y seguridad: todo objetivo se **clampa** contra `F<n>Mn`/`F<n>Mx` releídos en cada vuelta,
  cada escritura se **verifica leyendo de vuelta**, y a **93 °C** los ventiladores van al máximo pase
  lo que pase. Si no hay lecturas de temperatura por 30 s, se devuelven a Auto.
- Al salir (botón Salir, ⌘Q, SIGTERM, SIGINT) se escribe modo 0 en cada ventilador antes de terminar.

## Límites conocidos

- Necesita root para escribir: es el SMC, no hay vuelta. La diferencia con FanPilot es *cuándo* lo
  pide: una vez por arranque, y solo si vas a usar Curva o Máx.
- Si el proceso muere de golpe (crash, kill -9), los ventiladores **quedan en manual** con el último
  objetivo hasta que los suelte otro programa o reinicies. FanPilot se salva de eso con el lease del
  daemon; acá no hay daemon. La app se auto-cura: al arrancar en modo Auto devuelve a Auto cualquier
  ventilador que encuentre en manual.
- Apple Silicon nada más (probado en M5 Pro; el resto de la línea usa las mismas claves).
- No está notarizada (no hay cuenta paga de desarrollador): la primera vez, Ajustes → Privacidad y
  seguridad → "Abrir igualmente".

## Créditos

La capa C del SMC (`Sources/CSMC/smc.c`, `smc.h`) es de **FanPilot**, de [zyvren](https://github.com/zyvren),
MIT. Esa parte ya estaba probada en hardware y no tenía sentido reescribirla. El resto es de este repo.
