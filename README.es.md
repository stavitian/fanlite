# FanLite

[English](README.md) · **Español**

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
| ~120 archivos fuente | 6 archivos Swift + la capa C del SMC |

## Números en esta Mac (MacBook Pro M5 Pro, Mac17,9, macOS 27.2)

| | FanPilot | FanLite |
|---|---|---|
| Procesos | 2 (app + helper root) | 1 |
| Memoria (footprint, panel cerrado) | 42 MB + 5 MB | **13 MB** |
| CPU con la curva andando | ~3.7 % | **~0.3 %** |
| Archivos que instala en el sistema | daemon en /Library/PrivilegedHelperTools, plist en /Library/LaunchDaemons, socket, /var/log | **ninguno** |

El panel se arma la primera vez que se abre y se libera al cerrarlo: en reposo la app no paga las
vistas ni las superficies de ventana. Con el panel abierto el footprint sube mientras está visible
y vuelve a bajar al cerrarlo.

## Optimización (lo que cambió respecto de la primera versión)

Antes, con dos ventiladores, cada vuelta leía 10 claves de ventilador (5 por ventilador: real,
objetivo, modo, mínimo y máximo) y además leía de vuelta después de cada escritura. Con el lazo de
2 s eso daba ~5 lecturas de ventilador por segundo.

- **2 claves por ventilador y por vuelta**: modo (`F<n>md`) y objetivo (`F<n>Tg`). Los RPM reales
  (`F<n>Ac`) solo se leen con el panel abierto, que es el único lugar donde se muestran. Los límites
  (`F<n>Mn/Mx`) se cachean y se releen cada ~1 minuto.
- **Banda muerta de escritura**: no se manda un objetivo nuevo hasta que la curva pide un cambio de
  ~1 % del rango del ventilador (~55 rpm acá) o hasta que el SMC se alejó >20 rpm de lo pedido.
  Antes se escribía casi en cada vuelta por cambios de 5–50 rpm.
- **Sin lectura de vuelta después de cada escritura**: la vuelta siguiente ya lee el objetivo y
  detecta la desviación. Se eliminó una lectura de ventilador por cada escritura.
- **Lazo adaptativo**: 2 s de base, 1,5 s si la temperatura se mueve >0,5 °C y 3 s tras tres
  lecturas tranquilas (≤0,2 °C de cambio). Auto usa 3 s y Máx 2,5 s.
- **Lecturas por lote**: temperaturas y estado de los ventiladores entran a la cola del SMC en una
  sola operación, en vez de dos `dispatch_sync` por clave.
- **UI perezosa**: el panel no se construye al arrancar y se libera al cerrarse.
- **Arrastre de la curva coalescido**: mover un punto ya no guarda el JSON y lee el SMC en cada
  evento del mouse; como máximo hay un commit cada 0,4 s mientras dura el arrastre.

Con el panel cerrado y la curva estable, el tráfico de ventilador queda en **~1,3 lecturas por
segundo** con dos ventiladores (4 lecturas cada 3 s), contra ~5 por segundo antes. El simulador
tiene una comprobación explícita de que una vuelta estable no relee límites ni RPM reales. Al
salir, la última línea de `~/Library/Logs/FanLite.log` resume las lecturas y escrituras SMC de la
corrida (sin contar el descubrimiento), para poder verificarlo.

## Cómo se usa

```sh
scripts/build_app.sh          # arma build/FanLite.app
open build/FanLite.app        # queda en la barra de menú
```

Arranca **en modo lectura** (temperaturas y RPM, sin tocar nada). Si la última vez usaste **Curva** o
**Máx**, FanLite pide la contraseña de administrador al iniciar y se reabre él mismo como root
(`sudo -A`), así ya queda con permisos sin que tengas que elegir el modo de nuevo. La opción
**“Pedir permisos al iniciar”** está al pie del panel y viene activada por defecto; si la
desactivás, la contraseña se pide recién cuando elegís Curva o Máx. En Auto nunca pide nada.

Si cancelás el diálogo, la app sigue en **solo lectura** y podés reintentar eligiendo Curva o Máx.
Sigue siendo **un solo proceso** y no instala nada. Cuando la cerrás (botón Salir, ⌘Q, Ctrl-C,
SIGTERM), los ventiladores vuelven a Auto.

Si el diálogo no aparece en tu Mac, hay dos caminos manuales que hacen lo mismo:

```
scripts/abrir-con-permisos.command    # doble clic: pide la contraseña en la Terminal y abre FanLite como root
sudo "build/FanLite.app/Contents/MacOS/FanLite" --run
```

Para saltear el pedido de contraseña al arrancar: `--no-elevate` (elegir Curva o Máx después sigue pidiendo permiso).

Probar que el control funciona de verdad (sube los ventiladores 6 s y los devuelve):

```
scripts/probar-control.command     # doble clic, pide contraseña, muestra el resultado
```

Modos de diagnóstico (no tocan el hardware):

```sh
BIN=build/FanLite.app/Contents/MacOS/FanLite
$BIN --dump         # sensores, límites y estado de los ventiladores
$BIN --simulate     # 31 comprobaciones de la lógica de control contra un SMC falso
```

## Cómo funciona

```
FanLite (un solo proceso)
  ├── SMC.swift        cliente AppleSMC: leer claves, escribir modo y objetivo
  ├── Controller.swift loop adaptativo (1,5–3 s): temperatura → curva → RPM, y reafirma si macOS lo pisa
  ├── UI.swift         barra de menú + editor de curva (AppKit, sin SwiftUI), panel perezoso
  ├── Simulate.swift   SMC falso + 31 comprobaciones de la lógica (--simulate)
  └── main.swift       --dump / --selftest / --simulate / arranque
```

- Los ventiladores se leen y escriben con las claves estándar: `F<n>Ac` (real), `F<n>Tg` (objetivo),
  `F<n>Mn`/`F<n>Mx` (límites), `F<n>md` (modo: 0 = macOS, 1 = manual).
- La temperatura de la curva es el **máximo** de hasta 18 sensores de CPU y GPU (`Tp*`, `Tm*`, `Tg*`),
  elegidos repartidos entre familias la primera vez y guardados para no volver a recorrer el SMC.
  Se suaviza con un promedio exponencial (0.4) para que el ventilador no haga escalones por el
  ruido de un núcleo; el failsafe mira la temperatura cruda.
- En Curva y Máx se leen el modo y el objetivo real de cada ventilador: si macOS
  (thermalmonitord) cambió el objetivo, se reescribe. En Auto alcanza con el modo, porque no hay
  objetivo propio que reafirmar. Los RPM reales se leen solo con el panel abierto y los límites se
  releen cada ~1 minuto.
- Límites y seguridad: todo objetivo se **clampa** contra `F<n>Mn`/`F<n>Mx`, se escribe con una
  **banda muerta** de ~1 % del rango (no se manda una escritura por cada décima de grado) y a
  **93 °C** los ventiladores van al máximo pase lo que pase. Si no hay lecturas de temperatura por
  30 s, se devuelven a Auto.
- El panel se construye al abrirlo y se libera al cerrarlo; mientras está cerrado no se repintan
  vistas ni se leen RPM que nadie va a mostrar.
- Al salir (botón Salir, ⌘Q, SIGTERM, SIGINT) se escribe modo 0 en cada ventilador antes de terminar.

## Límites conocidos

- Necesita root para escribir: es el SMC, no hay vuelta. La diferencia con FanPilot es *cuándo* lo
  pide: una vez por arranque, al iniciar si la última vez usaste Curva/Máx (o al elegir un modo si
  desactivaste el pedido automático), y solo si vas a usar Curva o Máx.
- Si el proceso muere de golpe (crash, kill -9), los ventiladores **quedan en manual** con el último
  objetivo hasta que los suelte otro programa o reinicies. FanPilot se salva de eso con el lease del
  daemon; acá no hay daemon. La app se auto-cura: al arrancar en modo Auto devuelve a Auto cualquier
  ventilador que encuentre en manual.
- Apple Silicon nada más (probado en M5 Pro; el resto de la línea usa las mismas claves).
- No está notarizada (no hay cuenta paga de desarrollador): la primera vez, Ajustes → Privacidad y
  seguridad → "Abrir igualmente".
- La interfaz está en español; el README tiene versión en inglés.

## Créditos

La capa C del SMC (`Sources/CSMC/smc.c`, `smc.h`) es de **FanPilot**, de [zyvren](https://github.com/zyvren),
MIT. Esa parte ya estaba probada en hardware y no tenía sentido reescribirla. El resto es de este repo.

## Licencia

MIT. Ver [LICENSE](LICENSE). La atribución de FanPilot está en [NOTICE](NOTICE).
