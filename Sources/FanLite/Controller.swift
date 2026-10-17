import Foundation

struct FanState {
    var index: Int
    var name: String
    var actual: Double
    var target: Double
    var mode: Int              // 0 = lo maneja macOS (auto), 1 = manual (nuestro)
    var minRPM: Double
    var maxRPM: Double
    var controllable: Bool
    var error: String?
}

struct Snapshot {
    var ready = false
    var privileged = false
    var cpuTemp: Double?
    var fans: [FanState] = []
    var mode: FanMode = .auto
    var percent: Double?
    var note: String?
}

/// El corazón de FanLite: un timer cada 2 s que lee temperaturas y ventiladores y, si el modo
/// no es Auto, escribe el objetivo en el SMC.
///
/// Todo el estado vive en una cola serial. La UI solo recibe copias (`Snapshot`) en el main.
final class Controller {

    private struct FanKeys {
        var mode: String
        var target: String
        var targetType: String
        var name: String
        var minRPM: Double
        var maxRPM: Double
    }

    /// Por encima de esto los ventiladores van al máximo, sin importar la curva.
    static let failsafeTempC: Double = 93
    /// Si el objetivo real se aleja más de esto de lo que escribimos, lo reescribimos.
    static let driftToleranceRPM: Double = 20
    /// Lecturas fallidas seguidas antes de soltar los ventiladores a Auto.
    static let tempMissLimit = 15
    /// Peso de la muestra nueva en el suavizado de temperatura (1 = sin suavizado).
    static let tempAlpha: Double = 0.4

    private let smc: SMCDevice
    private let queue = DispatchQueue(label: "fanlite.control")
    private var timer: DispatchSourceTimer?

    /// Interno a propósito: lo maneja `--simulate` desde un solo hilo.
    var settings: FanLiteSettings
    private var fans: [Int: FanKeys] = [:]
    private var tempKeys: [String] = []
    private var lastWritten: [Int: Double] = [:]
    private var owned: Set<Int> = []
    private var tempMisses = 0
    private var smoothedTemp: Double?
    private var failsafeOn = false
    private var healedStale = false
    private var ready = false

    /// Normalmente sale de geteuid(); --simulate lo fuerza para probar la lógica sin root.
    var assumePrivileged = geteuid() == 0

    private(set) var snapshot = Snapshot()
    /// Se llama en el main queue con cada muestra.
    var onUpdate: ((Snapshot) -> Void)?

    init(smc: SMCDevice, settings: FanLiteSettings) {
        self.smc = smc
        self.settings = settings
    }

    // MARK: - Ciclo de vida

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.discover()
            self.ready = true
            self.publish()
            self.schedule()
        }
    }

    /// Suelta los ventiladores y corta el timer. Bloquea hasta 4 s (se llama al salir).
    func stop() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else { done.signal(); return }
            self.timer?.cancel()
            self.timer = nil
            if geteuid() == 0 {
                let states = self.readStates()
                if !states.isEmpty {
                    log("saliendo: ventiladores a Auto")
                    self.releaseAll(states)
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }

    // MARK: - Cambios desde la UI

    func setMode(_ mode: FanMode) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.settings.mode != mode else { return }
            self.settings.mode = mode
            Store.save(self.settings)
            log("modo -> \(mode.label)")
            self.reschedule()
            self.tick()
        }
    }

    func setCurve(_ curve: Curve) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.settings.curve != curve else { return }
            self.settings.curve = curve
            Store.save(self.settings)
            if self.settings.mode == .curve { self.tick() }
        }
    }

    func current() -> (mode: FanMode, curve: Curve, ready: Bool) {
        queue.sync { (settings.mode, settings.curve, ready) }
    }

    // MARK: - Descubrimiento (una vez por corrida)

    func discover() {
        var count = 0
        if let n = (try? smc.number("FNum")).flatMap({ $0 }), n >= 1 {
            count = min(Int(n), 8)
        } else {
            count = 4   // sin FNum probamos los primeros índices y vemos cuáles existen
        }
        for i in 0..<count {
            let modeKey = "F\(i)md"
            let targetKey = "F\(i)Tg"
            guard let modeInfo = try? smc.info(modeKey), modeInfo.size == 1, modeInfo.isWritable, modeInfo.cleanType == "ui8" else { continue }
            guard let targetInfo = try? smc.info(targetKey), ["flt", "fpe2"].contains(targetInfo.cleanType) else { continue }
            guard let lo = (try? smc.number("F\(i)Mn")).flatMap({ $0 }),
                  let hi = (try? smc.number("F\(i)Mx")).flatMap({ $0 }),
                  hi > lo else { continue }
            fans[i] = FanKeys(mode: modeKey, target: targetKey, targetType: targetInfo.cleanType,
                              name: fanName(i), minRPM: lo, maxRPM: hi)
        }
        if fans.isEmpty {
            log("no encontré ventiladores controlables en esta Mac (¿MacBook Air?)")
        } else {
            log("ventiladores: " + fans.sorted { $0.key < $1.key }
                .map { "\($0.value.name) \(Int($0.value.minRPM))-\(Int($0.value.maxRPM)) rpm" }
                .joined(separator: ", "))
        }

        let cached = settings.cpuTempKeys ?? []
        let usable = cached.filter { (try? smc.info($0)) != nil }
        if usable.count >= 3 {
            tempKeys = usable
        } else {
            log("buscando sensores de temperatura (una sola vez)…")
            tempKeys = scanTempKeys()
            settings.cpuTempKeys = tempKeys
            Store.save(settings)
        }
        log("sensores para la curva (\(tempKeys.count)): \(tempKeys.joined(separator: " "))")
    }

    private func fanName(_ index: Int) -> String {
        if let info = try? smc.info("F\(index)ID"), info.cleanType == "ch8",
           let raw = try? smc.bytes("F\(index)ID") {
            let text = String(bytes: raw, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
            if let text, !text.isEmpty { return text }
        }
        return "Ventilador \(index + 1)"
    }

    /// Recorre las claves del SMC y se queda con las de núcleos de CPU y GPU (`Tp..`, `Tm..`,
    /// `Tg..`) que devuelven una temperatura razonable. De cada familia guarda hasta 6, repartidas:
    /// leer 18 claves cada 2 s cuesta ~10 ms y cubre todo el chip.
    private func scanTempKeys() -> [String] {
        var byFamily: [String: [String]] = [:]
        for key in smc.allKeys() {
            let chars = Array(key)
            guard chars.count == 4, chars[0] == "T", "pmg".contains(chars[1]) else { continue }
            guard let info = try? smc.info(key), info.cleanType == "flt", info.size == 4 else { continue }
            guard let value = (try? smc.number(key)).flatMap({ $0 }), value > 5, value < 125 else { continue }
            byFamily[String(key.prefix(2)), default: []].append(key)
        }
        var picked: [String] = []
        for family in byFamily.keys.sorted() {
            let list = (byFamily[family] ?? []).sorted()
            let want = min(6, list.count)
            if want == list.count {
                picked.append(contentsOf: list)
            } else {
                for i in 0..<want { picked.append(list[i * list.count / want]) }
            }
        }
        return picked
    }

    // MARK: - Loop

    private func schedule() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func reschedule() {
        timer?.cancel()
        timer = nil
        schedule()
    }

    private var interval: Double {
        settings.mode == .auto ? 3.0 : 2.0
    }

    private func readStates() -> [FanState] {
        var states: [FanState] = []
        for (index, keys) in fans.sorted(by: { $0.key < $1.key }) {
            var state = FanState(index: index, name: keys.name, actual: 0, target: 0, mode: 0,
                                 minRPM: keys.minRPM, maxRPM: keys.maxRPM, controllable: true, error: nil)
            do {
                state.actual = (try smc.number("F\(index)Ac")).flatMap { $0 } ?? 0
                state.target = (try smc.number(keys.target)).flatMap { $0 } ?? 0
                state.mode = (try smc.uint8(keys.mode)) ?? 0
                // Los límites se releen siempre: son el techo real del clamp, no un valor de arranque.
                if let lo = (try smc.number("F\(index)Mn")).flatMap({ $0 }), lo.isFinite, lo >= 0 { state.minRPM = lo }
                if let hi = (try smc.number("F\(index)Mx")).flatMap({ $0 }), hi.isFinite, hi > state.minRPM { state.maxRPM = hi }
            } catch {
                state.error = "\(error)"
            }
            states.append(state)
        }
        return states
    }

    func tick() {
        let privileged = assumePrivileged
        var note: String?

        // 1. Temperatura: el máximo de los sensores elegidos.
        var temps: [Double] = []
        for key in tempKeys {
            if let value = (try? smc.number(key)).flatMap({ $0 }), value.isFinite, value > 5, value < 125 {
                temps.append(value)
            }
        }
        let cpu = temps.max()
        tempMisses = temps.isEmpty ? tempMisses + 1 : 0

        // 2. Estado real de los ventiladores.
        let states = readStates()

        // 3. Primera vuelta: si quedó algo en manual de una corrida anterior, se devuelve a Auto.
        if !healedStale {
            healedStale = true
            if privileged, settings.mode == .auto {
                for state in states where state.mode != 0 {
                    log("el ventilador \(state.index) estaba en manual al arrancar (¿otro controlador?); lo devuelvo a Auto")
                }
                releaseAll(states)
            }
        }

        // 4. Política.
        var percent: Double?
        if !privileged {
            note = "Solo lectura: para mover los ventiladores hace falta permiso de administrador."
        } else if let cpu, cpu >= Self.failsafeTempC {
            if !failsafeOn {
                failsafeOn = true
                log("FAILSAFE: \(String(format: "%.1f", cpu)) °C, ventiladores al máximo")
            }
            percent = 100
            note = String(format: "Failsafe: %.1f °C → máximo", cpu)
            apply(percent: 100, states: states)
        } else {
            if failsafeOn {
                failsafeOn = false
                log("failsafe liberado: \(cpu.map { String(format: "%.1f °C", $0) } ?? "sin lecturas")")
            }
            switch settings.mode {
            case .auto:
                releaseAll(states)
            case .max:
                percent = 100
                apply(percent: 100, states: states)
            case .curve:
                if let cpu {
                    // Suavizado exponencial: la temperatura de un núcleo salta ±2 °C y sin esto el
                    // ventilador haría escalones de ~150 rpm. El failsafe mira la temperatura cruda.
                    if let previous = smoothedTemp {
                        smoothedTemp = previous + Self.tempAlpha * (cpu - previous)
                    } else {
                        smoothedTemp = cpu
                    }
                    let demanded = settings.curve.percent(at: smoothedTemp ?? cpu)
                    percent = demanded.rounded()
                    apply(percent: demanded, states: states)
                } else if tempMisses >= Self.tempMissLimit {
                    log("sin lecturas de temperatura: ventiladores a Auto")
                    releaseAll(states)
                    settings.mode = .auto
                    Store.save(settings)
                    note = "Sin lecturas: ventiladores a Auto"
                } else {
                    note = "Esperando temperatura…"
                }
            }
        }

        // 5. Publicar.
        var snap = Snapshot()
        snap.ready = ready
        snap.privileged = privileged
        snap.cpuTemp = cpu
        snap.fans = states
        snap.mode = settings.mode
        snap.percent = percent
        snap.note = note
        snapshot = snap
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }

    // MARK: - Escrituras

    /// Lleva todos los ventiladores al porcentaje pedido: modo manual si hace falta y objetivo
    /// solo si el que ya está puesto se fue más de 20 rpm de lo nuestro (eso cubre también el caso
    /// en que macOS nos pisa el objetivo).
    private func apply(percent: Double, states: [FanState]) {
        for state in states {
            guard let keys = fans[state.index] else { continue }
            if state.mode != 1, !engage(state, keys: keys) { continue }
            let wanted = (state.minRPM + percent / 100 * (state.maxRPM - state.minRPM)).rounded()
            let current = state.target
            if state.mode == 1, abs(current - wanted) <= Self.driftToleranceRPM { continue }
            setTarget(state, keys: keys, rpm: wanted)
        }
    }

    @discardableResult
    private func engage(_ state: FanState, keys: FanKeys) -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
            do {
                try smc.write(keys.mode, [1])
                if let now = (try? smc.uint8(keys.mode)) ?? nil, now == 1 {
                    owned.insert(state.index)
                    return true
                }
            } catch {
                if let fault = error as? SMCFault, fault.isPermanent {
                    log("no puedo controlar el ventilador \(state.index): \(error)")
                    return false
                }
            }
        }
        log("el ventilador \(state.index) rechazó el modo manual")
        return false
    }

    private func setTarget(_ state: FanState, keys: FanKeys, rpm: Double) {
        let clamped = min(max(rpm, state.minRPM), state.maxRPM)
        guard let payload = encodeRPM(clamped, type: keys.targetType) else {
            log("no sé codificar \(Int(clamped)) rpm como \(keys.targetType)")
            return
        }
        for attempt in 0..<3 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.1) }
            do {
                try smc.write(keys.target, payload)
                if let back = (try? smc.number(keys.target)).flatMap({ $0 }), abs(back - clamped) <= 2 {
                    if lastWritten[state.index] != clamped {
                        log("ventilador \(state.index): \(Int(clamped)) rpm (\(keys.name))")
                    }
                    lastWritten[state.index] = clamped
                    return
                }
            } catch {
                if let fault = error as? SMCFault, fault.isPermanent {
                    log("el ventilador \(state.index) no acepta el objetivo: \(error)")
                    return
                }
            }
        }
        log("el ventilador \(state.index) no tomó \(Int(clamped)) rpm")
    }

    /// Devuelve los ventiladores a macOS. Es lo único que se hace al salir y al pasar a Auto.
    private func releaseAll(_ states: [FanState]) {
        for state in states {
            guard let keys = fans[state.index] else { continue }
            guard state.mode != 0 || owned.contains(state.index) else { continue }
            for attempt in 0..<3 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
                do {
                    try smc.write(keys.mode, [0])
                    if let now = (try? smc.uint8(keys.mode)) ?? nil, now == 0 { break }
                } catch {
                    log("no pude devolver el ventilador \(state.index) a Auto: \(error)")
                }
            }
            owned.remove(state.index)
            lastWritten[state.index] = nil
        }
    }

    // MARK: - Publicación

    private func publish() {
        var snap = Snapshot()
        snap.ready = ready
        snap.privileged = assumePrivileged
        snap.cpuTemp = snapshot.cpuTemp
        snap.percent = snapshot.percent
        snap.mode = settings.mode
        snap.note = ready ? nil : "Buscando sensores…"
        snapshot = snap
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snap) }
    }
}
