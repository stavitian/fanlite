import AppKit
import Foundation

// FanLite es un solo proceso: la app de barra de menú. No hay helper, ni daemon, ni LaunchAgent.
//
//   FanLite              abre la app (solo lectura hasta que pidas control)
//   FanLite --run        igual, pero lo llama el propio binario reabierto como root
//   FanLite --dump       imprime sensores y ventiladores y sale (no escribe nada)
//   FanLite --selftest   prueba de hardware supervisada: mueve los ventiladores y los devuelve a Auto

func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "Mac" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
}

private func makeSMC() -> SMC? {
    do {
        return try SMC()
    } catch {
        log("no pude abrir el SMC: \(error)")
        return nil
    }
}

// MARK: - Lectura rápida (sin permisos, no escribe nada)

enum Dump {
    static func run() {
        guard let smc = makeSMC() else { return }
        print("modelo \(hardwareModel()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · uid \(geteuid())")
        var temps: [(String, Double)] = []
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let info = try? smc.info(key), info.cleanType == "flt", info.size == 4 else { continue }
            guard let value = (try? smc.number(key)).flatMap({ $0 }), value > 5, value < 125 else { continue }
            temps.append((key, value))
        }
        let cpu = temps.filter { $0.0.hasPrefix("Tp") || $0.0.hasPrefix("Tm") }
        let gpu = temps.filter { $0.0.hasPrefix("Tg") }
        print("temperaturas: \(temps.count) claves · CPU \(cpu.count) · GPU \(gpu.count)")
        if let hottest = temps.max(by: { $0.1 < $1.1 }) {
            print(String(format: "máxima: %@ %.1f °C", hottest.0, hottest.1))
        }
        let count = Int((try? smc.number("FNum"))?.flatMap { $0 } ?? 0)
        print("ventiladores: \(count)")
        for i in 0..<max(count, 0) {
            let mode = ((try? smc.uint8("F\(i)md")) ?? nil).map(String.init) ?? "?"
            let actual = (try? smc.number("F\(i)Ac")).flatMap { $0 }.map { String(format: "%.0f", $0) } ?? "?"
            let target = (try? smc.number("F\(i)Tg")).flatMap { $0 }.map { String(format: "%.0f", $0) } ?? "?"
            let lo = (try? smc.number("F\(i)Mn")).flatMap { $0 }.map { String(format: "%.0f", $0) } ?? "?"
            let hi = (try? smc.number("F\(i)Mx")).flatMap { $0 }.map { String(format: "%.0f", $0) } ?? "?"
            print("  ventilador \(i): modo \(mode) · real \(actual) rpm · objetivo \(target) rpm · límites \(lo)-\(hi)")
        }
    }
}

// MARK: - Autotest supervisado

enum SelfTest {
    static func run() {
        log("========== autotest FanLite ==========")
        log("modelo \(hardwareModel()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · uid \(geteuid())")

        guard geteuid() == 0 else {
            log("el autotest escribe en el SMC: hace falta root. Pidiendo permiso…")
            if Elevator.relaunchAndWait(extraArguments: ["--selftest"]) {
                log("el autotest sigue con permisos; el resultado queda acá abajo")
            } else {
                log("FALLA: no se pudo obtener permiso de administrador")
            }
            return
        }

        guard let smc = makeSMC() else {
            log("FALLA: sin acceso al SMC")
            return
        }

        // 1. Sensores de temperatura
        var temps: [String: Double] = [:]
        for key in smc.allKeys() where key.hasPrefix("T") {
            guard let info = try? smc.info(key), info.cleanType == "flt", info.size == 4 else { continue }
            guard let value = (try? smc.number(key)).flatMap({ $0 }), value > 5, value < 125 else { continue }
            temps[key] = value
        }
        let cpuKeys = temps.keys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Tm") }.sorted()
        let hottest = temps.max { $0.value < $1.value }
        log("[1/4] sensores: \(temps.count) claves de temperatura (\(cpuKeys.count) de CPU/GPU); máxima \(hottest.map { String(format: "%@ %.1f °C", $0.key, $0.value) } ?? "?")")
        guard !cpuKeys.isEmpty else {
            log("FALLA: no encontré sensores de CPU")
            return
        }

        // 2. Ventiladores
        let count = Int((try? smc.number("FNum"))?.flatMap { $0 } ?? 0)
        log("[2/4] ventiladores: \(count)")
        var fans: [Int] = []
        var initial: [Int: Double] = [:]
        var limits: [Int: (Double, Double)] = [:]
        for i in 0..<max(count, 0) {
            let mode = (try? smc.uint8("F\(i)md")) ?? nil
            let lo = (try? smc.number("F\(i)Mn"))?.flatMap { $0 } ?? 0
            let hi = (try? smc.number("F\(i)Mx"))?.flatMap { $0 } ?? 0
            let actual = (try? smc.number("F\(i)Ac"))?.flatMap { $0 } ?? 0
            let target = (try? smc.number("F\(i)Tg"))?.flatMap { $0 } ?? 0
            log("      ventilador \(i): modo \(mode.map(String.init) ?? "?") · \(Int(actual)) rpm reales · objetivo \(Int(target)) · límites \(Int(lo))-\(Int(hi))")
            guard mode != nil, hi > lo else {
                log("      ventilador \(i) no tiene clave de modo utilizable: lo salteo")
                continue
            }
            if mode == 1 {
                log("      atención: el ventilador \(i) ya estaba en manual (¿FanPilot u otro controlador andando?)")
            }
            fans.append(i)
            initial[i] = actual
            limits[i] = (lo, hi)
        }
        guard !fans.isEmpty else {
            log("FALLA: no hay ventiladores controlables (¿MacBook Air?)")
            return
        }

        // 3. Escritura
        var targets: [Int: Double] = [:]
        log("[3/4] prueba de escritura (subo los ventiladores al 40 % de su rango por 6 s)")
        var engaged = false
        defer {
            // Pase lo que pase: de vuelta a Auto.
            for i in fans {
                for attempt in 0..<3 {
                    if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
                    do {
                        try smc.write("F\(i)md", [0])
                        if ((try? smc.uint8("F\(i)md")) ?? nil) == 0 { break }
                    } catch {
                        log("      no pude devolver el ventilador \(i) a Auto: \(error)")
                    }
                }
            }
            log("[4/4] vuelta a Auto: " + fans.map { i in
                let mode = ((try? smc.uint8("F\(i)md")) ?? nil).map(String.init) ?? "?"
                return "ventilador \(i) modo \(mode)"
            }.joined(separator: ", "))
            log("========== fin del autotest ==========")
        }

        var accepted = true
        for i in fans {
            guard let (lo, hi) = limits[i] else { continue }
            let goal = (lo + 0.4 * (hi - lo)).rounded()
            targets[i] = goal
            do {
                try smc.write("F\(i)md", [1])
            } catch {
                log("      ventilador \(i): no pude pasar a manual: \(error)")
                accepted = false
                continue
            }
            guard ((try? smc.uint8("F\(i)md")) ?? nil) == 1 else {
                log("      ventilador \(i): el modo manual no quedó")
                accepted = false
                continue
            }
            if let payload = encodeRPM(goal, type: (try? smc.info("F\(i)Tg"))?.cleanType ?? "flt") {
                do {
                    try smc.write("F\(i)Tg", payload)
                } catch {
                    log("      ventilador \(i): no pude escribir el objetivo: \(error)")
                    accepted = false
                }
            }
            let back = (try? smc.number("F\(i)Tg"))?.flatMap { $0 } ?? 0
            let matches = abs(back - goal) <= 2
            if !matches { accepted = false }
            log("      ventilador \(i): objetivo \(Int(goal)) rpm, leído de vuelta \(Int(back)) rpm \(matches ? "ok" : "NO COINCIDE")")
            engaged = true
        }
        guard engaged else {
            log("FALLA: no pude poner ningún ventilador en manual")
            return
        }

        Thread.sleep(forTimeInterval: 6)
        var delta = 0.0
        for i in fans {
            let now = (try? smc.number("F\(i)Ac"))?.flatMap { $0 } ?? 0
            let goal = targets[i] ?? 0
            let start = initial[i] ?? 0
            delta += abs(now - start)
            let good = abs(now - goal) < max(150, (limits[i]?.1 ?? 0) * 0.05)
            log("      ventilador \(i): \(Int(start)) rpm → \(Int(now)) rpm (objetivo \(Int(goal))) \(good ? "CONTROLA" : "no llegó")")
        }
        if delta > 100 {
            log("RESULTADO: OK — los ventiladores siguen lo que les manda FanLite")
        } else if accepted {
            log("RESULTADO: el SMC acepta y devuelve lo que escribo, pero a los 6 s el ventilador no quedó ahí: hay otro controlador pisando los valores (¿FanPilot andando?)")
        } else {
            log("RESULTADO: FALLA — no pude escribir el objetivo en el SMC")
        }
    }
}

// MARK: - Arranque

/// Se retienen acá para que los handlers de señal sigan vivos toda la ejecución.
var signalSources: [DispatchSourceSignal] = []

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    if geteuid() == 0 { Instance.writeRootMarker() }
    SelfTest.run()
    exit(0)
}

if arguments.contains("--dump") {
    Dump.run()
    exit(0)
}

if arguments.contains("--simulate") {
    exit(Simulate.run())
}

// El proceso con privilegios deja su pid cuando la barra de menú ya está creada (AppDelegate).

// SIGTERM/SIGINT: cerrar ordenadamente para devolver los ventiladores a Auto.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGHUP, SIG_IGN)
for sig in [SIGTERM, SIGINT, SIGHUP] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
