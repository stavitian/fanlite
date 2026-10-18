<p align="center">
  <img src="docs/icon.png" width="112" alt="Ícono de FanLite">
</p>

<h1 align="center">FanLite</h1>

<p align="center">
  <b>Una curva de temperatura. Un botón de máximo. Sin daemon.</b><br>
  Control mínimo de ventiladores para Macs Apple Silicon, en un solo proceso.
</p>

<p align="center">
  <a href="https://github.com/stavitian/fanlite/releases/latest"><img src="https://img.shields.io/badge/Descargar-FanLite.dmg-2f6bff?style=for-the-badge&logo=apple&logoColor=white" alt="Descargar FanLite"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%20to%20M5-blue" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-5.10%2B-orange" alt="Swift">
  <img src="https://img.shields.io/badge/Apple-notarizada-success?logo=apple" alt="Notarizada por Apple">
  <img src="https://img.shields.io/badge/licencia-MIT-green" alt="Licencia MIT">
</p>

[English](README.md) · **Español**

---

## Por qué FanLite

Las Macs Apple Silicon mantienen los ventiladores apagados, o muy lentos, hasta que el chip ya está
caliente. Es silencioso, pero cuando renderizás, compilás o jugás durante mucho tiempo la Mac se
calienta y puede bajar el rendimiento. FanLite te da la parte útil del control de ventiladores sin
instalar nada:

- **Una curva, cinco filas.** Elegís la temperatura para 20 / 40 / 60 / 80 / 100 % del rango del
  ventilador. FanLite interpola entre las filas y sigue la curva en vivo.
- **Un botón de máximo.** Velocidad plena cuando lo pedís.
- **Un solo proceso.** Sin helper, sin daemon, sin LaunchAgent. La app se reabre con `sudo -A` solo
  cuando le pedís controlar los ventiladores.
- **No deja nada instalado.** Al salir, los ventiladores vuelven a macOS.

Nació de [FanPilot](https://github.com/zyvren/FanPilot): el mismo conocimiento del SMC, sin el
daemon, el catálogo de sensores, las reglas ni las ventanas extra.

## Capturas

<table>
  <tr>
    <td width="50%" align="center"><img src="docs/screenshot-curve.png" width="420" alt="Panel de FanLite en Curva"></td>
    <td width="50%" align="center"><img src="docs/screenshot-auto.png" width="420" alt="Panel de FanLite en Auto"></td>
  </tr>
  <tr>
    <td align="center"><b>Curva</b>: cinco porcentajes fijos con una temperatura editable cada uno.</td>
    <td align="center"><b>Auto / Máx</b>: las filas de la curva desaparecen; debajo de los modos queda solo el pie.</td>
  </tr>
</table>

## Descarga e instalación

1. Descargá **FanLite-1.0.0.dmg** desde el [último release](https://github.com/stavitian/fanlite/releases/latest).
2. Abrilo y arrastrá **FanLite** a **Aplicaciones**.
3. Abrí FanLite desde Aplicaciones. Vive en la barra de menú; no aparece en el Dock.
4. La versión oficial está **firmada con Developer ID y notarizada por Apple**, con Hardened
   Runtime, marca de tiempo segura y el ticket de notarización adjunto. Si el Mac permite apps de
   desarrolladores identificados, no hace falta **Abrir igualmente**. macOS puede mostrar la
   confirmación habitual al abrir por primera vez una app descargada.

**Requisitos:** una Mac con Apple Silicon (M1 a M5) y macOS 14 Sonoma o posterior. Las MacBook Air
sin ventiladores solo monitorean.

El release incluye las sumas SHA-256 en `SHA256SUMS.txt`. Una compilación propia necesita su propia
firma y notarización; el estado indicado arriba corresponde a la app oficial descargable.

## Primer arranque y permisos

- **El primer arranque nunca pide la contraseña de administrador.** FanLite abre en solo lectura
  para que veas temperaturas y velocidades de inmediato. Para controlar los ventiladores, hacé clic
  en **Curva** o **Máx**: macOS pide la contraseña una vez, con el diálogo estándar de `sudo`.
- **Auto nunca pide nada.** Solo lee temperaturas y devuelve los ventiladores a macOS.
- No hay helper ni daemon. La app escribe en el SMC desde el mismo proceso después de pedirle a
  `sudo` que la reabra como root. No instala nada en el sistema.
- Después del primer arranque, el check **“Pedir permisos al iniciar”** (activado por defecto)
  decide si FanLite pide la contraseña al abrir cuando el último modo fue Curva o Máx. Desactivalo
  si preferís que la pida solo al elegir un modo de control.
- `--no-elevate` saltea el pedido de contraseña al arrancar incluso si el check está activado.
  Elegir Curva o Máx después sigue pidiendo permiso.
- Al salir (Salir, ⌘Q, Ctrl-C, SIGTERM) cada ventilador vuelve a Auto.

## Qué hace

- **Curva**: cinco filas para **20 / 40 / 60 / 80 / 100 %**. Cada fila tiene una temperatura editable
  en °C. La validación es automática: **30–105 °C**, al menos **3 °C** entre filas, y la fila editada
  se clampea entre sus vecinas. Defaults: **33 / 40 / 65 / 75 / 83 °C**.
  Debajo de la primera fila la curva pide **0 %**: los ventiladores vuelven a macOS, que los apaga
  cuando la temperatura es baja. Se retoman al cruzar la primera fila.
- **Auto / Máx / Curva**: tres botones de ancho completo, con el modo elegido pintado con el color
  de resalte del sistema (azul si el acento es grafito). En Auto y Máx se esconden las filas de la
  curva, el texto de ayuda y la nota de solo lectura; debajo de los botones queda solo el pie.
- **Fila de ventiladores**: una etiqueta por ventilador, repartidas; con dos, el 1 queda a la
  izquierda y el 2 a la derecha.
- **Barra de menú**: la temperatura actual de CPU/GPU. Con clic derecho aparece un menú con
  *Abrir panel* y *Salir*.
- **Panel perezoso**: se arma al abrirlo y se libera al cerrarlo. Mientras está cerrado la app no
  repinta vistas ni lee RPM reales que nadie va a ver.
- **Una sola instancia.** La config vive en `~/Library/Application Support/FanLite`; el log en
  `~/Library/Logs/FanLite.log`.

## Seguridad

FanLite escribe objetivos de ventilador, así que es deliberadamente conservador:

- Cada objetivo se **clampea** contra el mínimo y el máximo reales del ventilador
  (`F<n>Mn`/`F<n>Mx`).
- **Failsafe térmico**: si la temperatura cruda llega a **93 °C**, los ventiladores van al máximo
  sin importar la curva.
- **Sin lecturas, sin control**: si no hay temperaturas válidas por unos 30 segundos, los
  ventiladores vuelven a Auto y el modo pasa a Auto.
- **Temperatura suavizada** (alpha 0.4) para que el ruido de un núcleo no haga escalones, y una
  **banda muerta** de ~1 % del rango para que un cambio de 0,1 °C no genere una escritura al SMC.
- Al salir, se escribe el modo 0 en cada ventilador antes de que termine el proceso.

No hay daemon, a propósito. Si el proceso muere de golpe (crash, `kill -9`), los ventiladores quedan
en manual con el último objetivo hasta que otro controlador los libere o se reinicie la Mac. Si
necesitás un helper con lease que los devuelva solo, usá
[FanPilot](https://github.com/zyvren/FanPilot).

## FanLite vs FanPilot

FanPilot es el proyecto completo del que salió FanLite. FanLite se queda con una curva y un botón
de máximo; si necesitás nombres de sensores por modelo, reglas de Auto Boost, ventana de sensores,
notificaciones o CLI, FanPilot es mejor opción.

| | FanPilot | FanLite |
|---|---|---|
| Procesos | 2 (app + daemon helper root) | **1** (se reabre con `sudo -A`) |
| Instala en el sistema | helper en `/Library/PrivilegedHelperTools`, LaunchDaemon, socket | **nada** |
| Control | RPM / % manual, Máx, Auto Boost, Curva | **Curva + Máx** (+ Auto) |
| Editor de curva | puntos libres para arrastrar | cinco filas fijas, temperaturas editables |
| Sensores | catálogo por modelo + clasificador | descubre `Tp*`/`Tm*`/`Tg*` una vez y los cachea |
| UI extra | ventana de sensores, ajustes, diagnóstico, CLI | un panel de barra de menú |
| Memoria (panel cerrado) | 42 MB + 5 MB | **~13 MB** |
| CPU con la curva andando | ~3,7 % | **~0,3 %** |

Los números se midieron en una MacBook Pro M5 Pro (Mac17,9), macOS 27.2. Son indicativos: el editor
de curva y el panel perezoso son las diferencias más grandes.

## Compilar desde el código

Requiere macOS 14+, Xcode o el toolchain de Swift 5.10+. No hace falta cuenta de Apple Developer;
la app usa Developer ID si encuentra una única identidad en el llavero y, en caso contrario, firma ad-hoc.

```sh
git clone https://github.com/stavitian/fanlite.git
cd fanlite

swift build                      # build debug
scripts/build_app.sh             # build/FanLite.app (release, Developer ID si está disponible)
scripts/make_dmg.sh --build      # dist/FanLite-<version>.dmg y .zip

.build/debug/FanLite --simulate  # 52 comprobaciones contra un SMC falso
.build/debug/FanLite --dump      # sensores, límites y estado actual
sudo .build/debug/FanLite --selftest   # prueba de hardware supervisada; devuelve a Auto
```

Para distribuir con firma, Hardened Runtime, marca de tiempo y notarización, ver [la guía de notarización](docs/NOTARIZATION.es.md).

El ícono de la app se genera con `scripts/make_icon.py` (requiere Pillow). El `.icns` está
commiteado, así que solo lo necesitás si cambiás el dibujo.

`--simulate` cubre la curva de cinco filas, el apagado debajo de la primera fila, el clamping, el
failsafe, la reafirmación por drift, la banda muerta de escritura, la migración de curvas viejas y
el tráfico SMC reducido por vuelta.

## Cómo funciona

```
FanLite (un solo proceso)
  ├── SMC.swift        cliente AppleSMC: lee claves, escribe modo y objetivo
  ├── Controller.swift loop adaptativo (1,5–3 s): temperatura → curva → RPM, reafirma si hay drift
  ├── Model.swift      curva, validación y ajustes (JSON)
  ├── UI.swift         barra de menú, editor de cinco filas, panel flotante
  ├── Simulate.swift   SMC falso + 52 comprobaciones (--simulate)
  └── main.swift       --dump / --selftest / --simulate / arranque
```

- Los ventiladores usan las claves estándar del SMC: `F<n>Ac` (RPM reales), `F<n>Tg` (objetivo),
  `F<n>Mn`/`F<n>Mx` (límites) y `F<n>md` (modo: 0 = macOS, 1 = manual).
- La temperatura de la curva es el **máximo** de hasta 18 sensores de CPU/GPU (`Tp*`, `Tm*`, `Tg*`),
  elegidos entre familias la primera vez y guardados para no recorrer el catálogo del SMC de nuevo.
- En Curva se leen el modo y el objetivo real de cada ventilador; si macOS (thermalmonitord) cambió
  el objetivo, se reescribe. En Auto alcanza con el modo.
- Todo objetivo se **clampea** contra los límites del ventilador. Las escrituras usan una **banda
  muerta** de ~1 % del rango y no hay lectura de vuelta después de cada escritura: la vuelta
  siguiente ya lee el objetivo y detecta el drift.
- El panel es un `NSPanel` sin borde con fondo de efecto visual. Se arma al abrirlo y se libera al
  cerrarlo; el alto sigue el contenido visible, así que en Auto / Máx es mucho más bajo que en Curva.
- El primer arranque de la GUI crea un marcador `first-launch.done` en el directorio de soporte y
  saltea la elevación al iniciar. El marcador está fuera de la config, que puede ser de root.
- Al salir se escribe el modo 0 en cada ventilador antes de terminar.

## Limitaciones conocidas

- Hace falta root para escribir los objetivos; no hay forma de evitarlo con el SMC. FanLite pide
  permiso una vez por arranque y solo si estás usando Curva o Máx.
- Si el proceso muere de golpe (crash, `kill -9`), los ventiladores quedan en manual con el último
  objetivo hasta que otro controlador los libere o se reinicie la Mac. No hay lease de daemon.
- Solo Apple Silicon; probado en una MacBook Pro M5 Pro (Mac17,9) con macOS 27.2. Otras Macs Apple
  Silicon usan la misma detección y deberían funcionar, pero no están probadas.
- Las MacBook Air sin ventiladores solo monitorean.
- La interfaz de la barra de menú está **solo en español**. Este README también está en
  [inglés](README.md).
- Usala bajo tu responsabilidad. Escribe en el SMC; mirá las temperaturas mientras probás una curva
  nueva.

## Créditos

Creado y mantenido por [stavitian](https://github.com/stavitian).

La capa C de AppleSMC (`Sources/CSMC/smc.c`, `Sources/CSMC/include/smc.h`) viene de **FanPilot**, de
[zyvren](https://github.com/zyvren), licencia MIT. Ver [NOTICE](NOTICE).

FanLite es un proyecto independiente y no está afiliado a Apple ni a ningún otro fabricante de
control de ventiladores.

## Licencia

MIT. Ver [LICENSE](LICENSE).

Usala bajo tu responsabilidad: FanLite cambia cómo se enfría tu Mac.
