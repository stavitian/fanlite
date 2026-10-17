import AppKit

// MARK: - Editor de curva

/// Dibuja la curva y deja arrastrar los puntos. Eje X: 30-100 °C. Eje Y: 0-100 %.
final class CurveEditorView: NSView {
    var curve: Curve = .fallback { didSet { if curve != oldValue { needsDisplay = true } } }
    var currentTemp: Double? { didSet { needsDisplay = true } }
    /// Se llama en cada arrastre, en vivo.
    var onChange: ((Curve) -> Void)?

    private let minTemp = 30.0
    private let maxTemp = 100.0
    private let inset = NSEdgeInsets(top: 16, left: 30, bottom: 22, right: 12)
    private var dragIndex: Int?

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 220) }

    private var plot: NSRect {
        NSRect(x: inset.left,
               y: inset.bottom,
               width: max(bounds.width - inset.left - inset.right, 1),
               height: max(bounds.height - inset.top - inset.bottom, 1))
    }

    private func x(for temp: Double) -> CGFloat {
        let f = (temp - minTemp) / (maxTemp - minTemp)
        return plot.minX + CGFloat(min(max(f, 0), 1)) * plot.width
    }

    private func y(for percent: Double) -> CGFloat {
        plot.minY + CGFloat(min(max(percent / 100, 0), 1)) * plot.height
    }

    private func temp(atX x: CGFloat) -> Double {
        minTemp + Double((x - plot.minX) / plot.width) * (maxTemp - minTemp)
    }

    private func percent(atY y: CGFloat) -> Double {
        Double((y - plot.minY) / plot.height) * 100
    }

    // MARK: Dibujo

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()

        let grid = NSColor.separatorColor.withAlphaComponent(0.5)
        let axis = NSColor.tertiaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Grilla + etiquetas
        for temp in stride(from: 40.0, through: 100.0, by: 20.0) {
            let px = x(for: temp)
            grid.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: px, y: plot.minY))
            line.line(to: NSPoint(x: px, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
            "\(Int(temp))°".draw(at: NSPoint(x: px - 8, y: plot.minY - 13), withAttributes: attributes)
        }
        for pct in stride(from: 0.0, through: 100.0, by: 25.0) {
            let py = y(for: pct)
            grid.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: py))
            line.line(to: NSPoint(x: plot.maxX, y: py))
            line.lineWidth = 1
            line.stroke()
            "\(Int(pct))".draw(at: NSPoint(x: 6, y: py - 5), withAttributes: attributes)
        }

        // Temperatura actual
        if let currentTemp, currentTemp > 5 {
            let px = x(for: currentTemp)
            axis.setStroke()
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: px, y: plot.minY))
            marker.line(to: NSPoint(x: px, y: plot.maxY))
            marker.lineWidth = 1
            marker.setLineDash([3, 3], count: 2, phase: 0)
            marker.stroke()
        }

        // Curva
        let points = curve.sorted
        if points.count > 1 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX, y: y(for: points[0].percent)))
            for point in points { path.line(to: NSPoint(x: x(for: point.temp), y: y(for: point.percent))) }
            path.line(to: NSPoint(x: plot.maxX, y: y(for: points[points.count - 1].percent)))
            path.lineWidth = 2
            path.lineJoinStyle = .round
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }

        // Puntos
        for point in points {
            let center = NSPoint(x: x(for: point.temp), y: y(for: point.percent))
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            NSColor.controlBackgroundColor.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 2
            dot.stroke()
        }
    }

    // MARK: Arrastre

    private func nearestPoint(to location: NSPoint) -> Int? {
        let points = curve.sorted
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let center = NSPoint(x: x(for: point.temp), y: y(for: point.percent))
            let distance = hypot(center.x - location.x, center.y - location.y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best, best.distance <= 22 else { return nil }
        return best.index
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        dragIndex = nearestPoint(to: location)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragIndex else { return }
        var points = curve.sorted
        guard dragIndex < points.count else { return }
        let location = convert(event.locationInWindow, from: nil)

        var temp = (temp(atX: location.x)).rounded()
        let pct = (percent(atY: location.y)).rounded()
        let low = dragIndex > 0 ? points[dragIndex - 1].temp + 3 : minTemp
        let high = dragIndex < points.count - 1 ? points[dragIndex + 1].temp - 3 : maxTemp
        temp = min(max(temp, low), high)

        points[dragIndex] = CurvePoint(temp: temp, percent: min(max(pct, 0), 100))
        curve = Curve(points: points)
        onChange?(curve)
    }

    override func mouseUp(with event: NSEvent) {
        dragIndex = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

// MARK: - Panel de la barra de menú

final class PopoverView: NSView {
    let tempLabel = NSTextField(labelWithString: "— °C")
    let stateLabel = NSTextField(labelWithString: "")
    let fansLabel = NSTextField(labelWithString: "")
    let noteLabel = NSTextField(labelWithString: "")
    let modeControl: NSSegmentedControl
    let curveView = CurveEditorView()
    let quitButton = NSButton(title: "Salir", target: nil, action: nil)

    static let modes: [FanMode] = [.auto, .curve, .max]

    var onModeChange: ((FanMode) -> Void)?
    var onCurveChange: ((Curve) -> Void)?
    var onQuit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        modeControl = NSSegmentedControl(labels: PopoverView.modes.map { $0.label },
                                         trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        wantsLayer = true

        tempLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        fansLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fansLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: 10.5)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 3
        noteLabel.preferredMaxLayoutWidth = 312

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.selectedSegment = 0

        curveView.onChange = { [weak self] curve in self?.onCurveChange?(curve) }

        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small

        let header = NSStackView(views: [tempLabel, Self.spacer(), stateLabel])
        header.orientation = .horizontal
        header.spacing = 6

        let footer = NSStackView(views: [Self.spacer(), quitButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [header, fansLabel, modeControl, curveView, noteLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            curveView.heightAnchor.constraint(equalToConstant: 220),
        ])
    }

    /// Vista vacía que se estira para empujar lo que tiene al lado.
    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
        return view
    }

    @objc private func modeChanged() {
        guard modeControl.selectedSegment >= 0, modeControl.selectedSegment < Self.modes.count else { return }
        onModeChange?(Self.modes[modeControl.selectedSegment])
    }

    @objc private func quit() { onQuit?() }

    func setMode(_ mode: FanMode) {
        if let index = Self.modes.firstIndex(of: mode), modeControl.selectedSegment != index {
            modeControl.selectedSegment = index
        }
    }

    func apply(_ snapshot: Snapshot) {
        if let cpu = snapshot.cpuTemp {
            tempLabel.stringValue = String(format: "%.1f °C", cpu)
        } else {
            tempLabel.stringValue = snapshot.ready ? "— °C" : "…"
        }
        if let percent = snapshot.percent {
            stateLabel.stringValue = "\(snapshot.mode.label) · \(Int(percent)) %"
        } else {
            stateLabel.stringValue = snapshot.mode.label
        }
        fansLabel.stringValue = snapshot.fans.isEmpty
            ? "sin ventiladores"
            : snapshot.fans.map { "\($0.name): \(Int($0.actual)) rpm" }.joined(separator: "   ")
        noteLabel.stringValue = snapshot.note ?? (snapshot.privileged ? "" : "Sin permiso de administrador")
        curveView.currentTemp = snapshot.cpuTemp
        setMode(snapshot.mode)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var controller: Controller?
    private var view: PopoverView!
    private var settings = FanLiteSettings()
    private var lastStatusTitle = ""
    private var elevator: Elevator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = Store.load()
        buildMainMenu()

        if !Instance.acquire() {
            let alert = NSAlert()
            alert.messageText = "FanLite ya está abierto"
            alert.informativeText = "Buscá el ícono de FanLite en la barra de menú."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        guard let smc = try? SMC() else {
            let alert = NSAlert()
            alert.messageText = "No pude hablar con el SMC"
            alert.informativeText = "Esta Mac no expone AppleSMC, así que no hay temperaturas ni ventiladores que leer."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let controller = Controller(smc: smc, settings: settings)
        self.controller = controller

        buildStatusItem()
        guard statusItem.button != nil else {
            log("no pude crear el ícono en la barra de menú (¿sin sesión gráfica?); me cierro")
            exit(1)
        }
        buildPopover()

        controller.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        controller.start()

        // Solo para probar la UI sin manos: abre el panel apenas arranca.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openPanel() }
        }

        let root = geteuid() == 0
        log("FanLite arrancado \(root ? "(root)" : "(usuario, solo lectura)")")
        if root { Instance.writeRootMarker() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Instance.release()
    }

    // MARK: Armado de la UI

    private func buildMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Salir de FanLite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…°"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func buildPopover() {
        view = PopoverView(frame: NSRect(x: 0, y: 0, width: 344, height: 460))
        view.onModeChange = { [weak self] mode in self?.modeChanged(mode) }
        view.onCurveChange = { [weak self] curve in self?.controller?.setCurve(curve) }
        view.onQuit = { NSApp.terminate(nil) }

        popover = NSPopover()
        popover.animates = false
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 344, height: 424)
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = view
    }

    // MARK: Interacción

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Abrir panel", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func openPanel() {
        if !popover.isShown, let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func modeChanged(_ mode: FanMode) {
        guard let controller else { return }
        let privileged = geteuid() == 0
        if mode == .auto || privileged {
            controller.setMode(mode)
            return
        }
        requestPrivileges(for: mode)
    }

    /// El único momento en que la app pide la contraseña: cuando querés que mueva los ventiladores.
    private func requestPrivileges(for mode: FanMode) {
        view.setMode(controller?.current().mode ?? .auto)

        let alert = NSAlert()
        alert.messageText = "FanLite necesita permiso de administrador"
        alert.informativeText = """
        Para mover los ventiladores hay que escribir en el SMC, y eso solo lo puede hacer root.

        macOS te va a pedir la contraseña una vez por arranque. No se instala ningún helper, daemon \
        ni servicio: es el mismo proceso y, cuando lo cerrás, los ventiladores vuelven a Auto.
        """
        alert.addButton(withTitle: "Activar control")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if Instance.rootMarkerAlive() {
            let info = NSAlert()
            info.messageText = "Ya hay una instancia con permisos"
            info.informativeText = "FanLite ya está moviendo los ventiladores desde otra ventana. Cambiá el modo desde ahí, o cerrala y volvé a probar desde esta."
            info.runModal()
            return
        }

        // El modo queda guardado antes de reabrir: la instancia con privilegios arranca con él.
        settings.mode = mode
        Store.save(settings)
        Instance.release()

        let elevator = Elevator { [weak self] error in
            guard let self else { return }
            if error == nil {
                log("arrancó la instancia con privilegios")
                NSApp.terminate(nil)
            } else {
                log("elevación fallida: \(error ?? "")")
                self.settings.mode = .auto
                Store.save(self.settings)
                self.showElevationFailure(error ?? "")
            }
        }
        self.elevator = elevator
        elevator.start()
    }

    private func showElevationFailure(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "No pude abrir FanLite con permisos"
        alert.informativeText = """
        \(reason)

        Desde la Terminal funciona siempre:

            sudo "\(Bundle.main.executablePath ?? "FanLite")" --run

        O hacé doble clic en scripts/abrir-con-permisos.command.
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Muestras

    private func apply(_ snapshot: Snapshot) {
        let title: String
        if let cpu = snapshot.cpuTemp {
            title = String(format: "%.0f°", cpu)
        } else {
            title = snapshot.ready ? "—°" : "…°"
        }
        if title != lastStatusTitle {
            statusItem.button?.title = title
            lastStatusTitle = title
        }
        view.apply(snapshot)
    }
}

// MARK: - Instancia única

enum Instance {
    private static var pidURL: URL { Paths.supportDirectory.appendingPathComponent("instance.pid") }
    static var rootMarkerURL: URL { Paths.supportDirectory.appendingPathComponent("root.pid") }

    /// `kill(pid, 0)` da EPERM (no 0) cuando un proceso sin privilegios mira a uno de root:
    /// EPERM también quiere decir "existe".
    static func pidAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func acquire() -> Bool {
        if let text = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid != getpid(), pidAlive(pid) {
            return false
        }
        try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: pidURL, atomically: true, encoding: .utf8)
        return true
    }

    static func release() {
        // Solo borra el archivo si es nuestro: al reabrirse como root, el proceso con privilegios
        // ya escribió su pid y el que se va no lo puede pisar.
        if let text = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid == getpid() {
            try? FileManager.default.removeItem(at: pidURL)
        }
    }

    static func writeRootMarker() {
        try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: rootMarkerURL, atomically: true, encoding: .utf8)
    }

    /// ¿Hay una instancia con privilegios viva? Ojo: `kill(pid, 0)` devuelve EPERM (no 0) cuando
    /// un proceso sin privilegios mira a uno de root, así que EPERM también cuenta como "vivo".
    static func rootMarkerAlive() -> Bool {
        guard let text = try? String(contentsOf: rootMarkerURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return pidAlive(pid)
    }
}

// MARK: - Reabrirse con permisos

/// Reabre el mismo binario como root con `sudo -A` y un diálogo de macOS como askpass.
///
/// Es un hijo nuestro, así que hereda la sesión gráfica del usuario (la barra de menú funciona).
/// No instala nada: ni helper, ni daemon, ni LaunchAgent. `completion` llega en el main queue con
/// nil si la instancia con privilegios arrancó, o con el motivo de la falla.
final class Elevator {
    private let completion: (String?) -> Void
    private var poll: DispatchSourceTimer?
    private var task: Process?
    private let lock = NSLock()
    private var finished = false
    private var ticks = 0

    init(completion: @escaping (String?) -> Void) {
        self.completion = completion
    }

    func start() {
        try? FileManager.default.removeItem(at: Instance.rootMarkerURL)
        guard let task = Elevator.makeTask(extraArguments: ["--run"]) else {
            finish("no encuentro el binario de FanLite")
            return
        }
        task.terminationHandler = { [weak self] process in
            guard let self else { return }
            if process.terminationStatus != 0 {
                self.finish("sudo salió con código \(process.terminationStatus) (¿cancelaste el diálogo?)")
            }
        }
        do {
            try task.run()
        } catch {
            finish("no pude ejecutar sudo: \(error)")
            return
        }
        self.task = task

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.ticks += 1
            if Instance.rootMarkerAlive() {
                self.finish(nil)
            } else if self.ticks > 900 {          // 6 minutos esperando la contraseña
                self.finish("no hubo respuesta en 6 minutos")
            }
        }
        timer.resume()
        poll = timer
    }

    /// `sudo -A` con el diálogo de macOS como askpass. Es un hijo nuestro: hereda la sesión
    /// gráfica del usuario, así que la barra de menú funciona. No instala nada.
    static func makeTask(extraArguments: [String]) -> Process? {
        guard let exe = Bundle.main.executablePath ?? CommandLine.arguments.first else { return nil }
        var environment = ProcessInfo.processInfo.environment
        if let askpass = Bundle.main.resourceURL?.appendingPathComponent("askpass.sh"),
           FileManager.default.isExecutableFile(atPath: askpass.path) {
            environment["SUDO_ASKPASS"] = askpass.path
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-A", "-p", ""] + [exe] + extraArguments
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        return task
    }

    /// Variante sincrónica para los modos de consola (`--selftest`), donde el run loop de AppKit
    /// todavía no está andando y no se puede esperar un callback en el main queue.
    static func relaunchAndWait(extraArguments: [String]) -> Bool {
        try? FileManager.default.removeItem(at: Instance.rootMarkerURL)
        guard let task = makeTask(extraArguments: extraArguments) else { return false }
        do {
            try task.run()
        } catch {
            log("no pude ejecutar sudo: \(error)")
            return false
        }
        for _ in 0..<1500 {                       // hasta 10 minutos: el usuario puede tardar
            Thread.sleep(forTimeInterval: 0.4)
            if Instance.rootMarkerAlive() { return true }
            if !task.isRunning { return false }   // sudo terminó: canceló o falló
        }
        return false
    }

    private func finish(_ error: String?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        poll?.cancel()
        poll = nil
        DispatchQueue.main.async { self.completion(error) }
    }
}
