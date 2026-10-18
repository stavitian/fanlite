import Foundation

// Simulador: corre el controlador de verdad contra un SMC falso, sin tocar hardware y sin root.
// Verifica curva, clamping, failsafe, reafirmación, liberación a Auto y el corte por falta de lecturas.
//
//   FanLite --simulate

final class FakeSMC: SMCDevice {
    struct Entry {
        var type: String
        var size: Int
        var writable: Bool
        var value: Double
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var writes: [(key: String, value: Double)] = []
    /// Claves que el controlador pidió leer en cada vuelta. Sirve para comprobar que no se
    /// relean los límites ni los RPM reales cuando no hacen falta.
    private(set) var readKeys: [String] = []

    func set(_ key: String, _ value: Double, type: String = "flt ", size: Int = 4, writable: Bool = true) {
        entries[key] = Entry(type: type, size: size, writable: writable, value: value)
    }

    func value(_ key: String) -> Double? { entries[key]?.value }

    func info(_ key: String) throws -> KeyInfo {
        guard let entry = entries[key] else { throw SMCFault.missingKey(key) }
        var attributes: UInt8 = 0x80
        if entry.writable { attributes |= 0x40 }
        return KeyInfo(size: entry.size, type: entry.type, attributes: attributes)
    }

    func bytes(_ key: String) throws -> [UInt8] {
        guard let entry = entries[key] else { throw SMCFault.missingKey(key) }
        switch entry.type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            var f = Float(entry.value)
            return withUnsafeBytes(of: &f) { Array($0) }
        case "fpe2":
            let raw = Int16(clamping: Int((entry.value * 4).rounded()))
            return [UInt8(UInt8(truncatingIfNeeded: raw >> 8)), UInt8(UInt8(truncatingIfNeeded: raw & 0xff))]
        default:
            return [UInt8(UInt8(truncatingIfNeeded: Int(entry.value)))]
        }
    }

    func number(_ key: String) throws -> Double? {
        readKeys.append(key)
        return value(key)
    }

    func numbers(_ keys: [String]) -> [String: Double] {
        var values = [String: Double](minimumCapacity: keys.count)
        for key in keys {
            readKeys.append(key)
            if let value = value(key) { values[key] = value }
        }
        return values
    }

    func uint8(_ key: String) throws -> Int? { value(key).map { Int($0) } }

    func write(_ key: String, _ value: [UInt8]) throws {
        guard var entry = entries[key] else { throw SMCFault.missingKey(key) }
        guard entry.writable else { throw SMCFault.badType(key, "no escribible") }
        guard value.count == entry.size else { throw SMCFault.wrongSize(key, expected: entry.size, got: value.count) }
        switch entry.type.trimmingCharacters(in: .whitespaces) {
        case "flt":
            entry.value = Double(Float(bitPattern: UInt32(value[0]) | (UInt32(value[1]) << 8) | (UInt32(value[2]) << 16) | (UInt32(value[3]) << 24)))
        case "fpe2":
            entry.value = Double((Int(value[0]) << 8) | Int(value[1])) / 4.0
        default:
            entry.value = Double(value[0])
        }
        entries[key] = entry
        writes.append((key, entry.value))
    }

    func allKeys() -> [String] { Array(entries.keys) }

    func clearWrites() { writes.removeAll() }
    func clearReads() { readKeys.removeAll() }
}

enum Simulate {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: Bool, _ what: String) {
        checks += 1
        if !condition { failures += 1 }
        print("  \(condition ? "ok  " : "FALLA") \(what)")
    }

    private static func close(_ a: Double?, _ b: Double, _ tolerance: Double = 1) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    static func run() -> Int32 {
        Paths.logOverride = URL(fileURLWithPath: NSTemporaryDirectory() + "fanlite-sim.log")
        try? FileManager.default.removeItem(at: Paths.logOverride!)
        Store.enabled = false

        let smc = FakeSMC()
        smc.set("FNum", 2, type: "ui8 ", size: 1, writable: false)
        for i in 0..<2 {
            smc.set("F\(i)Mn", 2317, writable: false)
            smc.set("F\(i)Mx", 7826, writable: false)
            smc.set("F\(i)Ac", 0, writable: false)
            smc.set("F\(i)Tg", 0)
            smc.set("F\(i)md", 0, type: "ui8 ", size: 1)
        }
        let tempKeys = ["Tp01", "Tm01", "Tg01"]
        for key in tempKeys { smc.set(key, 45, writable: false) }

        let controller = Controller(smc: smc, settings: FanLiteSettings())
        controller.assumePrivileged = true
        controller.discover()

        let lo = 2317.0, hi = 7826.0
        func expected(_ percent: Double) -> Double { (lo + percent / 100 * (hi - lo)).rounded() }

        print("== 1. descubrimiento ==")
        check(smc.writes.isEmpty, "no escribió nada al descubrir")
        check(controller.settings.mode == .auto, "arranca en Auto")

        print("== 2. Auto con todo en Auto: no toca nada ==")
        controller.tick()
        check(smc.writes.isEmpty, "sin escrituras (\(smc.writes.count))")

        print("== 3. Auto con un ventilador en manual (sobra de una corrida anterior) ==")
        smc.set("F0md", 1, type: "ui8 ", size: 1)
        controller.tick()
        check(smc.value("F0md") == 0, "F0md volvió a 0")
        check(smc.value("F1md") == 0, "F1md sigue en 0")
        check(smc.writes.count == 1, "una sola escritura (\(smc.writes.map(\.key))")

        print("== 4. Curva a 70 °C (esperado 70 % = \(Int(expected(70)))) ==")
        smc.clearWrites()
        for key in tempKeys { smc.set(key, 70, writable: false) }
        controller.settings.mode = .curve
        controller.tick()
        check(smc.value("F0md") == 1 && smc.value("F1md") == 1, "los dos pasaron a manual")
        check(close(smc.value("F0Tg"), expected(70), 2) && close(smc.value("F1Tg"), expected(70), 2),
              "objetivos \(Int(smc.value("F0Tg") ?? 0)) / \(Int(smc.value("F1Tg") ?? 0)) rpm")

        print("== 5. Sin cambios: no vuelve a escribir ==")
        smc.clearWrites()
        controller.tick()
        check(smc.writes.isEmpty, "sin escrituras (\(smc.writes.count))")

        print("== 5b. Una vuelta estable no relee límites ni RPM reales ==")
        smc.clearReads()
        controller.tick()
        let fanReads = smc.readKeys.filter { $0.hasPrefix("F") }
        check(!fanReads.contains { $0.hasSuffix("Mn") || $0.hasSuffix("Mx") },
              "no leyó límites (\(fanReads.joined(separator: " ")))")
        check(!fanReads.contains { $0.hasSuffix("Ac") }, "no leyó RPM reales con el panel cerrado")
        check(fanReads.count == 4, "2 claves por ventilador (\(fanReads.count)): modo y objetivo")

        print("== 5c. Con el panel abierto sí lee los RPM reales ==")
        controller.uiActive = true
        smc.clearReads()
        controller.tick()
        check(smc.readKeys.filter { $0.hasSuffix("Ac") }.count == 2, "leyó F0Ac y F1Ac")
        controller.uiActive = false

        print("== 6. macOS nos pisa el objetivo -> lo reafirma ==")
        smc.set("F0Tg", 100)
        controller.tick()
        check(close(smc.value("F0Tg"), expected(70), 2), "F0Tg reafirmado en \(Int(smc.value("F0Tg") ?? 0)) rpm")

        print("== 7. Failsafe a 94 °C -> máximo ==")
        for key in tempKeys { smc.set(key, 94, writable: false) }
        controller.tick()
        check(close(smc.value("F0Tg"), hi) && close(smc.value("F1Tg"), hi), "objetivo \(Int(smc.value("F0Tg") ?? 0)) rpm = máximo")
        check(controller.snapshot.percent == 100, "el panel muestra 100 %")

        print("== 8. Baja a 60 °C (curva 56 % = \(Int(expected(56)))) ==")
        for key in tempKeys { smc.set(key, 60, writable: false) }
        // El suavizado hace que la bajada sea gradual: se le dan unas vueltas hasta que converge.
        for _ in 0..<14 { controller.tick() }
        // Tolerancia = banda muerta: no se reescribe si el objetivo está a menos de ~1 % del
        // rango (55 rpm) del ideal, así no se manda tráfico al SMC por ruido.
        check(close(smc.value("F0Tg"), expected(56), 60), "objetivo \(Int(smc.value("F0Tg") ?? 0)) rpm tras converger")

        print("== 8b. Subida lenta: la banda muerta evita escribir en cada vuelta ==")
        // En el tramo 65–75 °C la curva sube 2 % por grado. Pasos de 0,1 °C mueven el objetivo
        // menos que la banda muerta en cada vuelta, así que solo se escribe cuando la suma pasa.
        for key in tempKeys { smc.set(key, 65, writable: false) }
        for _ in 0..<14 { controller.tick() }
        smc.clearWrites()
        for step in 1...20 {
            for key in tempKeys { smc.set(key, 65 + Double(step) * 0.1, writable: false) }
            controller.tick()
        }
        let writesPerFan = smc.writes.count / 2
        check((1...3).contains(writesPerFan),
              "\(writesPerFan) escrituras por ventilador en 20 vueltas (antes era una por vuelta)")

        print("== 8c. Debajo de la primera fila (33 °C) apaga los ventiladores ==")
        for key in tempKeys { smc.set(key, 20, writable: false) }
        // El suavizado tarda en bajar: con 12 vueltas cruza el primer valor de la curva.
        for _ in 0..<12 { controller.tick() }
        check(smc.value("F0md") == 0 && smc.value("F1md") == 0, "los dos volvieron a Auto")
        check(controller.snapshot.percent == 0, "la curva pide 0 %")

        print("== 8d. Al volver a subir, la curva retoma el control ==")
        for key in tempKeys { smc.set(key, 40, writable: false) }
        for _ in 0..<4 { controller.tick() }
        check(smc.value("F0md") == 1 && smc.value("F1md") == 1, "los dos volvieron a manual")
        check((smc.value("F0Tg") ?? 0) > lo, "volvió a escribir un objetivo")

        print("== 9. Clamping: el ventilador no puede pasar de su propio máximo ==")
        smc.set("F1Mx", 3000, writable: false)
        smc.set("F1Tg", 0)
        for key in tempKeys { smc.set(key, 95, writable: false) }
        controller.tick(forceLimits: true)
        check((smc.value("F1Tg") ?? 0) <= 3000.5, "F1Tg \(Int(smc.value("F1Tg") ?? 0)) rpm ≤ 3000")
        smc.set("F1Mx", 7826, writable: false)

        print("== 10. Modo Máx ==")
        controller.settings.mode = .max
        for key in tempKeys { smc.set(key, 50, writable: false) }
        controller.tick(forceLimits: true)
        check(close(smc.value("F0Tg"), hi) && close(smc.value("F1Tg"), hi), "objetivo máximo en los dos")

        print("== 11. Volver a Auto devuelve los ventiladores ==")
        smc.clearWrites()
        controller.settings.mode = .auto
        controller.tick()
        check(smc.value("F0md") == 0 && smc.value("F1md") == 0, "modo 0 en los dos")
        check(smc.writes.count == 2, "dos escrituras de modo (\(smc.writes.count))")

        print("== 12. Sin lecturas de temperatura por 15 vueltas -> Auto ==")
        for key in tempKeys { smc.set(key, -1, writable: false) }
        controller.settings.mode = .curve
        controller.tick()
        for _ in 0..<16 { controller.tick() }
        check(controller.settings.mode == .auto, "volvió a Auto solo")
        check(smc.value("F0md") == 0 && smc.value("F1md") == 0, "ventiladores liberados")

        print("== 13. Curva: interpolación y plana fuera de rango ==")
        let curve = Curve.fallback
        check(curve.temps == [33, 40, 65, 75, 83], "defaults 33 / 40 / 65 / 75 / 83 °C")
        check(curve.percent(at: 30) == 0, "30 °C → 0 % (debajo de la primera fila)")
        check(curve.percent(at: 33) == 20, "33 °C → 20 %")
        check(curve.percent(at: 40) == 40, "40 °C → 40 %")
        check(curve.percent(at: 65) == 60, "65 °C → 60 %")
        check(curve.percent(at: 75) == 80, "75 °C → 80 %")
        check(curve.percent(at: 83) == 100, "83 °C → 100 %")
        check(abs(curve.percent(at: 78.5) - 88.75) < 0.01, "78.5 °C → 88.75 % (interpolado)")
        check(curve.percent(at: 20) == 0 && curve.percent(at: 105) == 100, "0 % abajo y 100 % arriba")

        print("== 13b. Validación de las cinco filas ==")
        let base = Curve(temps: [33, 40, 65, 75, 83])
        check(base.clamped(10, at: 0) == 30, "la primera fila no baja de 30 °C")
        check(base.clamped(200, at: 4) == 105, "la última no pasa de 105 °C")
        check(base.clamped(10, at: 2) == 43, "la fila se clampea 3 °C arriba de la anterior")
        check(base.clamped(200, at: 2) == 72, "y 3 °C abajo de la siguiente")
        check(base.setting(70, at: 2).temps == [33, 40, 70, 75, 83], "editar una fila no mueve a las demás")
        let tight = Curve(temps: [30, 33, 36, 39, 42])
        check(tight.clamped(100, at: 2) == 36, "sin lugar, queda en el único valor válido entre vecinas")
        let messy = Curve(temps: [200, 10, 100, 20, 300])
        check(messy.temps.count == 5, "siempre quedan cinco filas")
        check(messy.temps.allSatisfy { $0 >= 30 && $0 <= 105 }, "todas dentro de 30–105 °C")
        check(zip(messy.temps, messy.temps.dropFirst()).allSatisfy { $1 - $0 >= 3 },
              "todas separadas por al menos 3 °C")
        check(Curve(temps: [1, 2]).temps == Curve.defaultTemps, "una cantidad rara cae en los defaults")

        print("== 13c. Migración de una curva vieja ==")
        let oldCurve = """
        {"points":[{"temp":45,"percent":0},{"temp":60,"percent":25},{"temp":72,"percent":45},{"temp":85,"percent":75},{"temp":95,"percent":100}]}
        """
        let migrated = oldCurve.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(Curve.self, from: $0) }
        check(migrated?.temps == [57, 69, 79, 87, 95],
              "los puntos viejos caen en 57 / 69 / 79 / 87 / 95 °C")
        let encoded = try? JSONEncoder().encode(Curve.fallback)
        let roundTrip = encoded.flatMap { try? JSONDecoder().decode(Curve.self, from: $0) }
        check(roundTrip == Curve.fallback, "la curva nueva hace round-trip")

        print("== 14. Config vieja sin autoElevateOnLaunch ==")
        let legacy = """
        {"mode":"curve","interval":2,"curve":{"points":[{"temp":45,"percent":0},{"temp":95,"percent":100}]}}
        """
        let decoded = legacy.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(FanLiteSettings.self, from: $0) }
        check(decoded?.mode == .curve, "conserva el modo guardado")
        check(decoded?.wantsAutoElevation == true, "por defecto pide permisos al iniciar")
        check(decoded?.curve.temps == [55, 65, 75, 85, 95], "migra la curva vieja en vez de descartarla")

        print("")
        print(failures == 0 ? "TODO OK (\(checks) comprobaciones)" : "\(failures) FALLAS de \(checks) comprobaciones")
        if let log = try? String(contentsOf: Paths.logOverride!, encoding: .utf8) {
            let lines = log.split(separator: "\n").count
            print("(el controlador dejó \(lines) líneas en \(Paths.logOverride!.path))")
        }
        return failures == 0 ? 0 : 1
    }
}
