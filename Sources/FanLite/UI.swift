import AppKit

/// Vista vacía que se estira para empujar lo que tiene al lado.
private func stretchSpacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
    view.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 1), for: .horizontal)
    return view
}

// MARK: - Editor de curva

/// Cinco filas con los porcentajes fijos de la curva y un campo editable (°C) por fila.
/// Sin gráfico ni steppers: la validación (rango, separación y vecinas) la hace `Curve` y el
/// campo solo muestra el valor ya corregido.
final class CurveRowsView: NSView, NSTextFieldDelegate {
    /// Se llama al confirmar un campo, ya con la curva validada.
    var onChange: ((Curve) -> Void)?

    private var curve: Curve = .fallback
    private var fields: [NSTextField] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        var previousRow: NSView?
        for index in Curve.percentages.indices {
            let percent = NSTextField(labelWithString: "\(Int(Curve.percentages[index])) %")
            percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            percent.textColor = .secondaryLabelColor

            let field = NSTextField(string: "")
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.controlSize = .small
            field.bezelStyle = .roundedBezel
            field.cell?.usesSingleLineMode = true
            field.tag = index
            field.delegate = self
            field.target = self
            field.action = #selector(fieldChanged(_:))
            field.toolTip = "Temperatura a la que la curva pide \(Int(Curve.percentages[index])) %"
            field.setAccessibilityLabel("Temperatura para \(Int(Curve.percentages[index])) %")
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
            fields.append(field)

            let unit = NSTextField(labelWithString: "°C")
            unit.font = .systemFont(ofSize: 11)
            unit.textColor = .secondaryLabelColor

            // Fila con constraints propios: la etiqueta queda a la izquierda y el campo a la
            // derecha, sin depender de cómo reparte el espacio un NSStackView.
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            for view in [percent, field, unit] {
                view.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(view)
            }
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                percent.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                percent.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                field.topAnchor.constraint(equalTo: row.topAnchor),
                field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                field.trailingAnchor.constraint(equalTo: unit.leadingAnchor, constant: -6),
                unit.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                unit.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            if let previousRow {
                row.topAnchor.constraint(equalTo: previousRow.bottomAnchor, constant: 6).isActive = true
            } else {
                row.topAnchor.constraint(equalTo: topAnchor).isActive = true
            }
            previousRow = row
        }

        let hint = NSTextField(labelWithString: "30–105 °C · mínimo 3 °C entre filas")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let previousRow {
            hint.topAnchor.constraint(equalTo: previousRow.bottomAnchor, constant: 6).isActive = true
        }
    }

    /// Refresca los cinco campos. No dispara `onChange`.
    func setCurve(_ curve: Curve) {
        self.curve = curve
        for (index, field) in fields.enumerated() {
            field.stringValue = Self.text(for: curve.temp(at: index))
        }
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        commit(sender)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        commit(field)
    }

    private func commit(_ field: NSTextField) {
        let index = field.tag
        guard fields.indices.contains(index) else { return }

        let typed = Self.value(from: field.stringValue)
        let value = curve.clamped(typed ?? curve.temp(at: index), at: index)
        let updated = curve.setting(value, at: index)
        field.stringValue = Self.text(for: value)
        guard updated != curve else { return }
        curve = updated
        onChange?(updated)
    }

    private static func value(from text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "°C", with: "")
            .replacingOccurrences(of: "°", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    private static func text(for temp: Double) -> String {
        String(Int(temp.rounded()))
    }
}

// MARK: - Selector de modo

/// Tres botones grandes que ocupan todo el ancho del panel. El elegido se pinta con el color de
/// resalte del sistema (o azul si el acento configurado es gris).
final class ModeSelectorView: NSView {
    static let modes: [FanMode] = [.auto, .curve, .max]

    /// Se llama al hacer clic, antes de que el controlador confirme el modo.
    var onSelect: ((FanMode) -> Void)?

    private var buttons: [NSButton] = []
    private var selected: FanMode?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for (index, mode) in Self.modes.enumerated() {
            let button = NSButton(title: mode.label, target: self, action: #selector(clicked(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.tag = index
            button.setAccessibilityLabel("Modo \(mode.label)")
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        setMode(.auto)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard buttons.indices.contains(sender.tag) else { return }
        let mode = Self.modes[sender.tag]
        setMode(mode)
        // Se avisa aunque sea el modo ya elegido: en solo lectura, volver a tocar Curva o Máx
        // es la forma de pedir permisos sin tener que cambiar de modo y volver.
        onSelect?(mode)
    }

    func setMode(_ mode: FanMode) {
        guard mode != selected else { return }
        selected = mode
        for (index, button) in buttons.enumerated() {
            let isSelected = Self.modes[index] == mode
            button.state = isSelected ? .on : .off
            button.bezelColor = isSelected ? Self.accentColor : nil
            button.attributedTitle = NSAttributedString(
                string: Self.modes[index].label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .semibold : .medium),
                    .foregroundColor: isSelected ? NSColor.white : NSColor.labelColor,
                ]
            )
        }
    }

    /// El acento del sistema; si es gris (grafito), azul para que el elegido se note.
    private static var accentColor: NSColor {
        let accent = NSColor.controlAccentColor
        if let rgb = accent.usingColorSpace(.sRGB),
           abs(rgb.redComponent - rgb.greenComponent) < 0.05,
           abs(rgb.greenComponent - rgb.blueComponent) < 0.05 {
            return .systemBlue
        }
        return accent
    }
}

// MARK: - Panel de la barra de menú

final class PanelView: NSView {
    let tempLabel = NSTextField(labelWithString: "— °C")
    let stateLabel = NSTextField(labelWithString: "")
    let fansRow = NSStackView()
    let noteLabel = NSTextField(labelWithString: "")
    let modeSelector = ModeSelectorView()
    let curveRows = CurveRowsView()
    let autoElevateCheckbox = NSButton(checkboxWithTitle: "Pedir permisos al iniciar", target: nil, action: nil)
    let quitButton = NSButton(title: "Salir", target: nil, action: nil)

    var onModeChange: ((FanMode) -> Void)?
    var onCurveChange: ((Curve) -> Void)?
    var onAutoElevateChange: ((Bool) -> Void)?
    var onQuit: (() -> Void)?
    /// El panel tiene que cambiar de alto cuando se esconden o muestran las filas.
    var onLayoutChange: (() -> Void)?

    private var fanLabels: [NSTextField] = []
    private var fansCount = -1
    private var shownMode: FanMode = .auto

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        wantsLayer = true

        tempLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .medium)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor

        fansRow.orientation = .horizontal
        fansRow.alignment = .centerY
        fansRow.spacing = 6

        modeSelector.onSelect = { [weak self] mode in
            guard let self else { return }
            // Optimista: las filas y el estado cambian al toque, sin esperar la vuelta.
            let changed = mode != self.shownMode
            self.setMode(mode)
            if changed { self.stateLabel.stringValue = mode.label }
            self.onModeChange?(mode)
        }

        noteLabel.font = .systemFont(ofSize: 10.5)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byWordWrapping
        noteLabel.maximumNumberOfLines = 3
        noteLabel.preferredMaxLayoutWidth = 312
        // Dos líneas reservadas: si el panel se abre antes de la primera muestra, la nota de
        // "solo lectura" no encuentra el panel corto y se recorta.
        noteLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 27).isActive = true

        curveRows.onChange = { [weak self] curve in self?.onCurveChange?(curve) }

        autoElevateCheckbox.font = .systemFont(ofSize: 11)
        autoElevateCheckbox.controlSize = .small
        autoElevateCheckbox.target = self
        autoElevateCheckbox.action = #selector(autoElevateChanged)
        autoElevateCheckbox.toolTip = "Pide la contraseña al abrir FanLite si la última vez usaste Curva o Máx. Si está desactivado, la pide solo al elegir un modo."

        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small

        let header = NSStackView(views: [tempLabel, stretchSpacer(), stateLabel])
        header.orientation = .horizontal
        header.spacing = 6

        let footer = NSStackView(views: [autoElevateCheckbox, stretchSpacer(), quitButton])
        footer.orientation = .horizontal
        footer.spacing = 6

        let stack = NSStackView(views: [header, fansRow, modeSelector, curveRows, noteLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Estas tres filas no se estiran solas dentro del stack: les damos el ancho del contenido.
        let contentWidth = stack.widthAnchor
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            fansRow.widthAnchor.constraint(equalTo: contentWidth, constant: -32),
            modeSelector.widthAnchor.constraint(equalTo: contentWidth, constant: -32),
            curveRows.widthAnchor.constraint(equalTo: contentWidth, constant: -32),
        ])
    }

    @objc private func autoElevateChanged() {
        onAutoElevateChange?(autoElevateCheckbox.state == .on)
    }

    @objc private func quit() { onQuit?() }

    func setMode(_ mode: FanMode) {
        modeSelector.setMode(mode)
        // En Auto y Máx no hay curva que editar: quedan solo los botones y el pie.
        let showsCurve = mode == .curve
        guard curveRows.isHidden != !showsCurve else { return }
        curveRows.isHidden = !showsCurve
        noteLabel.isHidden = !showsCurve
        onLayoutChange?()
    }

    func setAutoElevate(_ enabled: Bool) {
        let desired: NSControl.StateValue = enabled ? .on : .off
        if autoElevateCheckbox.state != desired { autoElevateCheckbox.state = desired }
    }

    func setCurve(_ curve: Curve) {
        curveRows.setCurve(curve)
    }

    /// Alto que necesita el panel con el ancho dado, con las filas visibles u ocultas.
    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        defer { widthConstraint.isActive = false }
        layoutSubtreeIfNeeded()
        return max(120, ceil(fittingSize.height))
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
        updateFans(snapshot.fans)
        noteLabel.stringValue = snapshot.note ?? (snapshot.privileged ? "" : "Sin permiso de administrador")
        shownMode = snapshot.mode
        setMode(snapshot.mode)
    }

    // MARK: Ventiladores

    private func updateFans(_ fans: [FanState]) {
        if fans.count != fansCount {
            fansCount = fans.count
            rebuildFansRow(fans)
        }
        for (index, label) in fanLabels.enumerated() where index < fans.count {
            label.stringValue = Self.fanText(fans[index])
        }
    }

    /// Un ventilador por columna, repartidos: el primero a la izquierda y el último a la derecha.
    private func rebuildFansRow(_ fans: [FanState]) {
        for view in fansRow.arrangedSubviews {
            fansRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        fanLabels.removeAll()

        guard !fans.isEmpty else {
            fansRow.addArrangedSubview(Self.fanLabel("sin ventiladores"))
            return
        }
        for (index, fan) in fans.enumerated() {
            if index > 0 { fansRow.addArrangedSubview(stretchSpacer()) }
            let label = Self.fanLabel(Self.fanText(fan))
            fanLabels.append(label)
            fansRow.addArrangedSubview(label)
        }
    }

    private static func fanText(_ fan: FanState) -> String {
        "\(fan.name): \(Int(fan.actual)) rpm"
    }

    private static func fanLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

// MARK: - Primer arranque

/// El primer arranque de la GUI nunca pide permisos: abre en solo lectura para que se puedan ver
/// temperaturas y RPM sin contraseña. El marcador vive al lado de la config (que puede ser de
/// root); a partir del segundo arranque manda la preferencia normal de "pedir permisos al iniciar".
enum FirstLaunch {
    static func consume() -> Bool {
        let marker = Paths.firstLaunchMarker
        guard !FileManager.default.fileExists(atPath: marker.path) else { return false }
        try? FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
        try? Data("1\n".utf8).write(to: marker)
        return true
    }
}

// MARK: - App

/// Panel flotante de la barra de menú. Es un NSPanel y no un NSPopover: una ventana propia,
/// sin flecha, que se cierra sola al desactivarse la app.
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel?
    private var controller: Controller?
    private var view: PanelView?
    private var settings = FanLiteSettings()
    private var latestSnapshot = Snapshot()
    private var lastStatusTitle = ""
    private var elevator: Elevator?
    private var elevating = false
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?

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

        controller.onUpdate = { [weak self] snapshot in self?.apply(snapshot) }
        controller.start()

        // Solo para probar la UI sin manos: abre el panel apenas arranca.
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.openPanel() }
        }

        // El primer arranque real es siempre en solo lectura. No se consume con --no-elevate:
        // ese flag ya es una prueba/override y no debería gastar el primer arranque.
        let firstLaunch = !CommandLine.arguments.contains("--no-elevate") && FirstLaunch.consume()

        let root = geteuid() == 0
        log("FanLite arrancado \(root ? "(root)" : "(usuario, solo lectura)")")
        if root {
            Instance.writeRootMarker()
            // Los archivos que escribe root deben seguir siendo del usuario de la consola.
            Store.adoptPathsForConsoleUser()
        } else if !CommandLine.arguments.contains("--no-elevate") {
            if firstLaunch {
                log("primer arranque: sin pedir permisos (solo lectura)")
            } else {
                autoElevateIfNeeded()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePanelObservers()
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

    /// El panel se arma recién la primera vez que se abre y se libera al cerrarlo. Es la parte
    /// más pesada de la app (vistas, capas y superficie de ventana); en reposo no hace falta.
    @discardableResult
    private func ensurePanel() -> (StatusPanel, PanelView) {
        if let panel, let view { return (panel, view) }

        let width: CGFloat = 344
        let view = PanelView(frame: NSRect(x: 0, y: 0, width: width, height: 320))
        view.onModeChange = { [weak self] mode in self?.modeChanged(mode) }
        view.onCurveChange = { [weak self] curve in self?.controller?.setCurve(curve) }
        view.onAutoElevateChange = { [weak self] enabled in self?.autoElevateChanged(enabled) }
        view.onQuit = { NSApp.terminate(nil) }
        view.onLayoutChange = { [weak self] in self?.fitPanelToContent() }
        view.setCurve(controller?.current().curve ?? .fallback)
        view.setAutoElevate(settings.wantsAutoElevation)
        // Aplicar la muestra antes de medir: la nota (que puede ocupar dos líneas) ya cuenta.
        view.apply(latestSnapshot)

        // El alto sale del contenido (y del modo): en Auto/Máx no hay filas de curva.
        let height = view.preferredHeight(forWidth: width)

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        // En apariencia oscura el material claro deja el texto blanco con poco contraste si
        // detrás hay una ventana clara. Un velo negro lo mantiene legible en cualquier fondo.
        if background.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            let tint = NSView()
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
            tint.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(tint)
            NSLayoutConstraint.activate([
                tint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                tint.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                tint.topAnchor.constraint(equalTo: background.topAnchor),
                tint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
        }

        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)

        let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.contentView = background
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        self.view = view
        self.panel = panel
        return (panel, view)
    }

    /// Ajusta el alto al contenido visible sin mover el borde superior: el panel cuelga de la barra.
    private func fitPanelToContent() {
        guard let panel, let view else { return }
        let width = panel.frame.width
        let height = view.preferredHeight(forWidth: width)
        guard abs(height - panel.frame.height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: width, height: height))
        var frame = panel.frame
        frame.size.height = height
        frame.origin.y = top - height
        if let screen = panel.screen ?? NSScreen.main {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY + 8)
        }
        panel.setFrame(frame, display: panel.isVisible)
    }

    private func closePanel(hideApp: Bool = true) {
        guard let panel, panel.isVisible else { return }
        let wasActive = NSApp.isActive
        // Confirmar el campo que se esté editando: el valor tipeado no se pierde al cerrar.
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        controller?.setUIActive(false)
        removePanelObservers()
        // Si el panel era lo único visible, devolvemos el foco a la app anterior.
        if hideApp, wasActive { NSApp.hide(nil) }
        // Se libera después del callback: anular el panel en medio de su propio cierre es pedirle
        // problemas a AppKit. Si se reabrió mientras tanto, el guard lo deja vivo.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel === panel, !panel.isVisible else { return }
            self.panel = nil
            self.view = nil
        }
    }

    /// Esc cierra el panel y la app se cierra al desactivarse, como hacía el popover.
    private func installPanelObservers() {
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                self?.closePanel()
                return nil
            }
        }
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in self?.closePanel() }
        }
    }

    private func removePanelObservers() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    /// Deja el panel debajo del ícono de la barra de menú, sin salirse de la pantalla.
    private func position(_ panel: NSPanel, below button: NSStatusBarButton) {
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        var origin = NSPoint(x: buttonRect.midX - panel.frame.width / 2,
                             y: buttonRect.minY - panel.frame.height - 5)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)
    }

    // MARK: Interacción

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel(hideApp: false)
            let menu = NSMenu()
            menu.addItem(withTitle: "Abrir panel", action: #selector(openPanel), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            if panel?.isVisible != true { NSApp.hide(nil) }
            return
        }
        if panel?.isVisible == true {
            closePanel()
        } else {
            openPanel()
        }
    }

    @objc private func openPanel() {
        guard panel?.isVisible != true, let button = statusItem.button else { return }
        let (panel, view) = ensurePanel()
        view.setCurve(controller?.current().curve ?? .fallback)
        view.setAutoElevate(settings.wantsAutoElevation)
        view.apply(latestSnapshot)
        fitPanelToContent()
        controller?.setUIActive(true)
        installPanelObservers()
        position(panel, below: button)
        NSApp.unhide(nil)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // No dejamos el primer campo enfocado: abrir el panel no debería capturar el teclado.
        panel.makeFirstResponder(nil)
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

    private func autoElevateChanged(_ enabled: Bool) {
        settings.autoElevateOnLaunch = enabled
        controller?.setAutoElevateOnLaunch(enabled)
    }

    /// Si la última vez se usó Curva o Máx, pide la contraseña al arrancar y se reabre como root.
    /// Si el usuario cancela, sigue en solo lectura y puede reintentar eligiendo un modo.
    private func autoElevateIfNeeded() {
        guard geteuid() != 0,
              settings.wantsAutoElevation,
              settings.mode != .auto,
              !elevating else { return }

        guard !Instance.rootMarkerAlive() else {
            log("hay otra instancia con permisos; arranco en solo lectura")
            return
        }
        beginElevation(mode: settings.mode, automatic: true)
    }

    private func beginElevation(mode: FanMode, automatic: Bool) {
        elevating = true
        if !automatic {
            // El modo queda guardado antes de reabrir: la instancia root arranca con él.
            settings.mode = mode
            Store.save(settings)
        }
        // La instancia root tiene que poder tomar el lock de instancia única.
        Instance.release()

        let elevator = Elevator { [weak self] error in
            guard let self else { return }
            self.elevating = false
            if error == nil {
                log("arrancó la instancia con privilegios")
                NSApp.terminate(nil)
                return
            }

            log("elevación \(automatic ? "al iniciar" : "manual") fallida: \(error ?? "")")
            // Si falló, esta instancia sigue viva y tiene que recuperar el lock.
            _ = Instance.acquire()
            if automatic {
                // No tocamos el modo guardado: el próximo arranque puede reintentar.
                self.view?.setMode(self.controller?.current().mode ?? .auto)
            } else {
                self.settings.mode = .auto
                Store.save(self.settings)
                self.showElevationFailure(error ?? "")
            }
            self.elevator = nil
        }
        self.elevator = elevator
        elevator.start()
    }

    /// Pide la contraseña cuando el usuario elige Curva o Máx en una instancia sin privilegios.
    private func requestPrivileges(for mode: FanMode) {
        guard !elevating else { return }
        view?.setMode(controller?.current().mode ?? .auto)

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

        beginElevation(mode: mode, automatic: false)
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
        latestSnapshot = snapshot
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
        // Con el panel cerrado no hay nada que repintar: el título de la barra ya se actualizó.
        if panel?.isVisible == true {
            view?.apply(snapshot)
        }
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
