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

/// El corazón de FanLite: un timer adaptativo (1,5–3 s) que lee temperaturas y el estado de los
/// ventiladores y, si el modo no es Auto, escribe el objetivo en el SMC.
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
    /// Si el objetivo real se aleja más de esto de lo que pedimos, se reescribe.
    static let driftToleranceRPM: Double = 20
    /// No se manda una escritura nueva hasta que la curva pida al menos ~1 % del rango del
    /// ventilador (~55 rpm en esta Mac). Antes se escribía en cada vuelta por cambios de 5 rpm.
    static let writeDeadbandFraction: Double = 0.01
    static let minWriteDeadbandRPM: Double = 25
    /// Los límites `F<n>Mn/Mx` no cambian en la práctica: se releen cada ~1 minuto.
    static let limitsEveryCycles = 20
    /// Lecturas fallidas seguidas antes de soltar los ventiladores a Auto.
    static let tempMissLimit = 15
    /// Peso de la muestra nueva en el suavizado de temperatura (1 = sin suavizado).
    static let tempAlpha: Double = 0.4
    /// Piso y techo del lazo adaptativo. Estable → más lento; cambiando → más rápido.
    static let minInterval: Double = 1.5
    static let maxCurveInterval: Double = 3.0

    private let smc: SMCDevice
    private let queue = DispatchQueue(label: "fanlite.control")
    private var timer: DispatchSourceTimer?

    /// Interno a propósito: lo maneja `--simulate` desde un solo hilo.
    var settings: FanLiteSettings
    private var fans: [Int: FanKeys] = [:]
    private var tempKeys: [String] = []
    private var lastWritten: [Int: Double] = [:]
    private var lastActual: [Int: Double] = [:]
    private var owned: Set<Int> = []
    private var tempMisses = 0
    private var smoothedTemp: Double?
    private var failsafeOn = false
    private var healedStale = false
    private var ready = false
    private var cycles = 0
    private var quietCycles = 0
    private var lastRawTemp: Double?
    private var currentInterval: Double = 2.0
    private var statsBase: (reads: UInt64, writes: UInt64) = (0, 0)
    private var curveCommitScheduled = false
    private var stopped = false
    private let startedAt = Date()

    /// Solo se leen los RPM reales (`F<n>Ac`) cuando el panel está visible: es el único lugar
    /// donde se muestran. El control no los necesita. Interno para que `--simulate` lo pruebe.
    var uiActive = false

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
            autoreleasepool {
                self.discover()
                self.ready = true
                self.publish()
                self.currentInterval = self.baseInterval()
                self.schedule()
            }
        }
    }

    /// Suelta los ventiladores y corta el timer. Bloquea hasta 4 s (se llama al salir).
    func stop() {
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self else { done.signal(); return }
            autoreleasepool {
                self.stopped = true
                let pendingCurveSave = self.curveCommitScheduled
                self.curveCommitScheduled = false
                self.timer?.cancel()
                self.timer = nil
                // Si se cerró en medio de un arrastre, guarda la última curva.
                if pendingCurveSave { Store.save(self.settings) }
                if geteuid() == 0 {
                    let states = self.readStates()
                    if !states.isEmpty {
                        log("saliendo: ventiladores a Auto")
                        self.releaseAll(states)
                    }
                }
                let stats = smcCallStats()
                let reads = stats.reads &- self.statsBase.reads
                let writes = stats.writes &- self.statsBase.writes
                let elapsed = max(Date().timeIntervalSince(self.startedAt), 1)
                log(String(format: "SMC: %llu lecturas, %llu escrituras en %.0f s (descubrimiento aparte)",
                           reads, writes, elapsed))
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
            self.restartTimer()
            self.tick()
        }
    }

    /// El panel se abrió o se cerró. Al abrirlo se leen los RPM reales y se refresca ya.
    func setUIActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self, self.uiActive != active else { return }
            self.uiActive = active
            if active { self.tick() }
        }
    }

    /// Preferencia del panel: pedir la contraseña al arrancar si la última vez se usó Curva/Máx.
    func setAutoElevateOnLaunch(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.settings.wantsAutoElevation != enabled else { return }
            self.settings.autoElevateOnLaunch = enabled
            Store.save(self.settings)
        }
    }

    func setCurve(_ curve: Curve) {
        queue.async { [weak self] in
            guard let self, self.settings.curve != curve else { return }
            self.settings.curve = curve
            self.scheduleCurveCommit()
        }
    }

    /// El editor llama a `setCurve` en cada evento del mouse. Guardar el JSON y leer el SMC en
    /// cada uno era una ráfaga de decenas de operaciones por segundo mientras se arrastra un
    /// punto; con esto se hace como máximo un commit cada 0,4 s durante el arrastre.
    private func scheduleCurveCommit() {
        guard !curveCommitScheduled else { return }
        curveCommitScheduled = true
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.stopped else { return }
            self.curveCommitScheduled = false
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

        // El descubrimiento tocó el key-info de cientos de claves; a partir de acá solo se
        // usan estos ventiladores y estos sensores.
        var keep = Set(tempKeys)
        for (index, keys) in fans {
            keep.insert(keys.mode)
            keep.insert(keys.target)
            keep.insert("F\(index)Ac")
            keep.insert("F\(index)Mn")
            keep.insert("F\(index)Mx")
        }
        smc.trimInfoCache(keeping: keep)
        statsBase = smcCallStats()
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
    /// cubre todo el chip y son lecturas baratas comparadas con recorrer las 3600 claves.
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
        timer.schedule(deadline: .now() + min(1.0, currentInterval),
                       repeating: currentInterval,
                       leeway: leeway(for: currentInterval))
        timer.setEventHandler { [weak self] in
            autoreleasepool { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func restartTimer() {
        currentInterval = baseInterval()
        timer?.cancel()
        timer = nil
        schedule()
    }

    /// Cambia el período sin recrear la fuente. `DispatchSourceTimer` permite reprogramarse
    /// mientras está corriendo; sólo vale la pena si el cambio es perceptible.
    private func setInterval(_ newValue: Double) {
        let clamped = min(max(newValue, Self.minInterval), Self.maxCurveInterval)
        guard abs(clamped - currentInterval) >= 0.2 else { return }
        currentInterval = clamped
        timer?.schedule(deadline: .now() + clamped,
                        repeating: clamped,
                        leeway: leeway(for: clamped))
    }

    private func leeway(for interval: Double) -> DispatchTimeInterval {
        .milliseconds(Int(max(150, interval * 100)))
    }

    /// Período base según el modo. En curva se ajusta después con `nextInterval`.
    private func baseInterval() -> Double {
        let configured = min(max(settings.interval, Self.minInterval), Self.maxCurveInterval)
        switch settings.mode {
        case .auto: return max(3.0, configured)
        case .max: return max(2.5, configured)
        case .curve: return configured
        }
    }

    /// Si la temperatura está quieta, se puede tardar más; si se mueve, se reacciona antes.
    /// El failsafe siempre va rápido. Para bajar a 3 s pide tres lecturas tranquilas seguidas:
    /// así el ruido de ±0,2 °C no está cambiando el período en cada vuelta.
    private func nextInterval(for cpu: Double?, previous: Double?) -> Double {
        if failsafeOn {
            quietCycles = 0
            return Self.minInterval
        }
        let base = baseInterval()
        guard settings.mode == .curve else {
            quietCycles = 0
            return base
        }
        guard let cpu, let previous else {
            quietCycles = 0
            return base
        }
        let delta = abs(cpu - previous)
        if delta >= 0.5 {
            quietCycles = 0
            return max(Self.minInterval, base - 0.5)
        }
        if delta <= 0.2 {
            quietCycles += 1
            if quietCycles >= 3 { return min(Self.maxCurveInterval, base + 1.0) }
        } else {
            quietCycles = 0
        }
        return base
    }

    /// Lee lo mínimo por vuelta: modo y objetivo de cada ventilador. Los RPM reales solo se
    /// piden con el panel abierto y los límites cada `limitsEveryCycles` vueltas.
    private func readStates(forceLimits: Bool = false) -> [FanState] {
        let refreshLimits = forceLimits || (cycles > 0 && cycles % Self.limitsEveryCycles == 0)
        // En Auto (o en modo lectura) el objetivo no se usa para nada: alcanza con el modo
        // para saber si hay que devolver un ventilador a macOS.
        let wantsTarget = assumePrivileged && settings.mode != .auto
        var wanted: [String] = []
        wanted.reserveCapacity(fans.count * (uiActive ? 3 : 2) + (refreshLimits ? fans.count * 2 : 0))
        for (index, keys) in fans {
            wanted.append(keys.mode)
            if wantsTarget { wanted.append(keys.target) }
            if uiActive { wanted.append("F\(index)Ac") }
            if refreshLimits {
                wanted.append("F\(index)Mn")
                wanted.append("F\(index)Mx")
            }
        }
        let values = smc.numbers(wanted)

        var states: [FanState] = []
        for (index, cachedKeys) in fans.sorted(by: { $0.key < $1.key }) {
            var keys = cachedKeys
            if refreshLimits {
                if let lo = values["F\(index)Mn"], lo.isFinite, lo >= 0 { keys.minRPM = lo }
                if let hi = values["F\(index)Mx"], hi.isFinite, hi > keys.minRPM { keys.maxRPM = hi }
                fans[index] = keys
            }

            var state = FanState(index: index, name: keys.name,
                                 actual: lastActual[index] ?? 0,
                                 target: wantsTarget ? (values[keys.target] ?? 0) : 0,
                                 mode: Int(values[keys.mode] ?? 0),
                                 minRPM: keys.minRPM, maxRPM: keys.maxRPM,
                                 controllable: true, error: nil)
            if uiActive, let actual = values["F\(index)Ac"], actual.isFinite {
                state.actual = actual
                lastActual[index] = actual
            }
            if values[keys.mode] == nil || (wantsTarget && values[keys.target] == nil) {
                state.error = "sin lecturas del SMC"
            }
            states.append(state)
        }
        return states
    }

    func tick(forceLimits: Bool = false) {
        guard !stopped else { return }
        let privileged = assumePrivileged
        var note: String?

        // 1. Temperatura: el máximo de los sensores elegidos, en una sola entrada al SMC.
        var cpu: Double?
        if !tempKeys.isEmpty {
            let values = smc.numbers(tempKeys)
            var temps: [Double] = []
            temps.reserveCapacity(values.count)
            for value in values.values where value.isFinite && value > 5 && value < 125 {
                temps.append(value)
            }
            cpu = temps.max()
        }
        let previousRaw = lastRawTemp
        lastRawTemp = cpu
        tempMisses = cpu == nil ? tempMisses + 1 : 0

        // 2. Estado real de los ventiladores.
        let states = readStates(forceLimits: forceLimits)

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

        // 6. Siguiente vuelta: rápida si la temperatura se está moviendo, lenta si está quieta.
        cycles &+= 1
        setInterval(nextInterval(for: cpu, previous: previousRaw))
    }

    // MARK: - Escrituras

    /// Lleva todos los ventiladores al porcentaje pedido. Se escribe si el SMC se alejó del
    /// objetivo (macOS nos pisó) o si la curva pide un cambio mayor a la banda muerta. Así una
    /// temperatura que sube de a 0,1 °C no genera una escritura en cada vuelta.
    private func apply(percent: Double, states: [FanState]) {
        let fraction = min(max(percent / 100, 0), 1)
        for state in states {
            guard state.error == nil, let keys = fans[state.index] else { continue }
            if state.mode != 1, !engage(state, keys: keys) { continue }
            let wanted = (state.minRPM + fraction * (state.maxRPM - state.minRPM)).rounded()
            let deadband = max(Self.minWriteDeadbandRPM,
                               (state.maxRPM - state.minRPM) * Self.writeDeadbandFraction)
            let reference = lastWritten[state.index] ?? state.target
            let drifted = abs(state.target - wanted) > Self.driftToleranceRPM
            let bigEnoughStep = abs(reference - wanted) > deadband
            if !drifted && !bigEnoughStep { continue }
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
                if lastWritten[state.index] != clamped {
                    log("ventilador \(state.index): \(Int(clamped)) rpm (\(keys.name))")
                }
                lastWritten[state.index] = clamped
                return
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
