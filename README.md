# FanLite

**English** · [Español](README.es.md)

Minimal fan control for Apple Silicon Macs: **one temperature curve and one max button**. Nothing
else. A single process — no helper, no daemon, no LaunchAgent, no LaunchDaemon.

FanLite started as a trimmed-down version of [FanPilot](https://github.com/zyvren/FanPilot), which
works well but ships far more than most people need: a per-model sensor catalog, Auto Boost rules,
CSV logging, notifications, a CLI, a sensor window, global shortcuts, and three settings panels.
FanLite keeps the useful part.

## What it does

- **Curve**: drag the points (temperature → fan percentage) and the fans follow the curve live.
- **Max**: fans at full speed with one click.
- **Auto**: hand the fans back to macOS.
- **Menu bar temperature** and fan speeds in the popover.

## Intentionally left out

| FanPilot | FanLite |
|---|---|
| App + root daemon (2 processes, socket, leases, peer auth) | 1 process, re-executed as root once |
| Per-model sensor catalog + classifier | one-time discovery of `Tp*/Tm*/Tg*` keys, cached |
| Auto Boost rules, per power source | — |
| CSV logging, notifications, shortcuts, CLI, sensor window | — |
| ~120 source files | 6 Swift files + the C SMC layer |

## Performance

Measured on a MacBook Pro M5 Pro (Mac17,9), macOS 27.2.

| | FanPilot | FanLite |
|---|---|---|
| Processes | 2 (app + root helper) | 1 |
| Memory footprint (popover closed) | 42 MB + 5 MB | **13 MB** |
| CPU with the curve active | ~3.7 % | **~0.3 %** |
| Files installed system-wide | helper in `/Library/PrivilegedHelperTools`, plist in `/Library/LaunchDaemons`, socket, `/var/log` | **none** |

The popover is created the first time it is opened and released when it closes, so the app does not
pay for its views or window surfaces while idle. With the popover open, macOS may attribute large
graphics surfaces to the process in `footprint`; those are window-server resources, not retained
heap, and they go away when the popover closes.

## Installation

```sh
scripts/build_app.sh          # builds build/FanLite.app
open build/FanLite.app        # lives in the menu bar
```

The app starts in **read-only mode**: it reads temperatures and fan speeds but does not touch the
SMC. It is not notarized (there is no paid Apple Developer account); on first launch, use
**System Settings → Privacy & Security → Open Anyway**.

## First run and permissions

Writing fan targets requires root. There is no helper and no daemon: FanLite re-executes its own
binary as root with `sudo -A` and a macOS password dialog, and keeps running as **one process**.

- If the last used mode was **Curve** or **Max**, FanLite asks for the administrator password at
  launch and restores that mode automatically. The **“Request permissions at launch”** checkbox at
  the bottom of the popover controls this behavior and is enabled by default.
- If the previous mode was **Auto**, launching never prompts; the app just reads sensors. The
  password is requested when you first choose Curve or Max.
- If you disable the checkbox, the password is requested only when you choose a control mode.
- If you cancel the password dialog, the app stays read-only and you can retry by choosing Curve or
  Max again.
- Use `--no-elevate` to skip the launch prompt even when it is enabled. Choosing Curve or Max
  later still asks for the password.

Nothing is installed on the system. When the app exits (Quit, ⌘Q, Ctrl-C, SIGTERM), the fans are
returned to Auto.

If the password dialog does not appear on your Mac, use one of the manual paths:

```sh
scripts/abrir-con-permisos.command    # double-click; asks for the password in Terminal
sudo "build/FanLite.app/Contents/MacOS/FanLite" --run
```

To verify that fan control actually works (fans ramp to 40 % for six seconds and return to Auto):

```sh
scripts/probar-control.command
```

## Diagnostics

These modes do not write to the SMC:

```sh
BIN=build/FanLite.app/Contents/MacOS/FanLite
$BIN --dump         # sensors, limits and current fan state
$BIN --simulate     # 31 control-logic checks against a fake SMC
```

The simulator covers curve interpolation, clamping, failsafe behavior, drift re-assertion, release
to Auto, missing-temperature fallback, write deadband, and the reduced per-cycle SMC traffic.

## How it works

```
FanLite (single process)
  ├── SMC.swift        AppleSMC client: read keys, write fan mode and target
  ├── Controller.swift adaptive loop (1.5–3 s): temperature → curve → RPM, re-assert on drift
  ├── UI.swift         menu bar + curve editor (AppKit, no SwiftUI), lazy popover
  ├── Simulate.swift   fake SMC + 31 logic checks (--simulate)
  └── main.swift       --dump / --selftest / --simulate / startup
```

- Fans use the standard SMC keys: `F<n>Ac` (actual RPM), `F<n>Tg` (target), `F<n>Mn`/`F<n>Mx`
  (limits), and `F<n>md` (mode: 0 = macOS, 1 = manual).
- The curve temperature is the **maximum** of up to 18 CPU/GPU sensors (`Tp*`, `Tm*`, `Tg*`),
  selected across sensor families on first run and cached so the SMC key catalog is not scanned
  again. It is smoothed with an exponential average (alpha 0.4) so core-level noise does not make
  the fans step; the failsafe reads the raw temperature.
- In Curve and Max, each cycle reads the fan mode and target; if macOS (thermalmonitord) changed
  the target, it is written again. In Auto, only the mode is read, because there is no target of
  our own to re-assert.
- Every target is **clamped** against the fan's min/max limits. Writes use a **1 % of range
  deadband** (~55 rpm on this Mac), and there is no read-back after every write: the next cycle
  already reads the target and detects drift. At **93 °C** the fans go to maximum regardless of the
  curve. If there are no temperature readings for 30 seconds, the fans return to Auto.
- The popover is built lazily and released on close; while it is closed the app does not repaint
  views or read actual RPM that nobody is going to display.
- On exit, mode 0 is written to every fan before the process terminates.
- When running as root, config and log files are handed back to the console user so the next
  unprivileged instance can save settings and request elevation reliably.

## Optimization notes

Before these changes, with two fans, every cycle read 10 fan keys (5 per fan: actual, target, mode,
min and max) and then read the target back after every write. At a 2 s interval that meant roughly
**5 fan reads per second**, with a write + read-back added almost every cycle while the curve was
active.

- **2 fan keys per cycle**: mode (`F<n>md`) and target (`F<n>Tg`). Actual RPM (`F<n>Ac`) is read
  only while the popover is open. Limits (`F<n>Mn/Mx`) are cached and refreshed about once a minute.
- **Write deadband**: a new target is written only when the curve asks for a change of ~1 % of the
  fan range (~55 rpm here), or when the SMC has drifted more than 20 rpm from our target.
- **No read-back after every write**: the next cycle reads the target and detects drift.
- **Adaptive loop**: 2 s base interval, 1.5 s when the temperature moves more than 0.5 °C, and 3 s
  after three quiet readings (0.2 °C or less). Auto runs at 3 s and Max at 2.5 s.
- **Batched SMC reads**: temperatures and fan state enter the SMC queue in one operation instead of
  two `dispatch_sync` calls per key.
- **Lazy popover**: built on first open and released when closed.
- **Coalesced curve drags**: dragging a point no longer saves JSON and reads the SMC on every mouse
  event; commits happen at most every 0.4 s while dragging.

With the popover closed and a stable curve, fan traffic drops to about **1.3 reads per second**
with two fans (4 reads every 3 s), down from ~5 per second. The last line in
`~/Library/Logs/FanLite.log` summarizes SMC reads and writes for the session (excluding discovery),
so the difference can be verified.

## Known limitations

- Root is required to write fan targets; there is no way around the SMC. FanLite asks once per
  launch and only when you are using Curve or Max.
- If the process dies abruptly (crash, `kill -9`), the fans remain in manual mode with the last
  target until another controller releases them or the Mac restarts. FanPilot avoids this with its
  daemon lease; FanLite has no daemon. On startup in Auto, FanLite releases any fan it finds in
  manual mode.
- Apple Silicon only (tested on M5 Pro; the rest of the line uses the same keys).
- The menu-bar UI is currently Spanish-only; this README is also available in Spanish.
- Not notarized: first launch requires **Open Anyway**.
- Use at your own risk. This software writes to the SMC; keep an eye on temperatures while testing
  a new curve.

## License

MIT. See [LICENSE](LICENSE).

The C AppleSMC layer (`Sources/CSMC/smc.c`, `smc.h`) is derived from **FanPilot** by
[zyvren](https://github.com/zyvren), also MIT. See [NOTICE](NOTICE) for attribution.
