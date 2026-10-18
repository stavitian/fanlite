import Foundation

// MARK: - Modos

enum FanMode: String, Codable {
    case auto
    case curve
    case max

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .curve: return "Curva"
        case .max: return "Máx"
        }
    }
}

// MARK: - Curva

/// Curva de cinco filas: cada fila pide un porcentaje fijo de ventilador y guarda la temperatura
/// a la que se alcanza. Las temperaturas se mantienen ordenadas y separadas al menos `minGap`
/// grados; la validación vive acá para que el editor solo tenga que mostrar el resultado.
struct Curve: Codable, Equatable {
    /// Porcentajes de las cinco filas, de menor a mayor.
    static let percentages: [Double] = [20, 40, 60, 80, 100]
    /// Temperaturas de la curva por defecto: 33 / 40 / 65 / 75 / 83 °C.
    static let defaultTemps: [Double] = [33, 40, 65, 75, 83]

    static let minTemp: Double = 30
    static let maxTemp: Double = 105
    static let minGap: Double = 3

    static let fallback = Curve(temps: defaultTemps)

    /// Una temperatura por fila, alineada con `percentages`.
    private(set) var temps: [Double]

    init(temps: [Double]) {
        self.temps = Self.sanitized(temps)
    }

    func temp(at index: Int) -> Double {
        temps.indices.contains(index) ? temps[index] : Self.minTemp
    }

    /// Temperatura de la fila `index` ya validada: dentro de 30–105 °C y a `minGap` de sus
    /// vecinas. Editar una fila nunca mueve a las demás; se clampea entre ellas.
    func clamped(_ value: Double, at index: Int) -> Double {
        guard temps.indices.contains(index) else { return value }
        let low = index > 0 ? temps[index - 1] + Self.minGap : Self.minTemp
        let high = index < temps.count - 1 ? temps[index + 1] - Self.minGap : Self.maxTemp
        return min(max(value.rounded(), low), high)
    }

    /// Copia de la curva con la fila `index` en `value`, ya validada.
    func setting(_ value: Double, at index: Int) -> Curve {
        guard temps.indices.contains(index) else { return self }
        var next = temps
        next[index] = clamped(value, at: index)
        return Curve(temps: next)
    }

    /// Interpolación lineal entre filas; 0 % por debajo de la primera y plana arriba de la última.
    func percent(at temp: Double) -> Double {
        guard let first = temps.first, let last = temps.last, temps.count > 1 else { return 0 }
        if temp < first { return 0 }
        if temp >= last { return Self.percentages[Self.percentages.count - 1] }
        for i in 1..<temps.count where temp <= temps[i] {
            let a = temps[i - 1], b = temps[i]
            let width = b - a
            let fa = Self.percentages[i - 1], fb = Self.percentages[i]
            guard width > 0 else { return fb }
            return fa + (fb - fa) * (temp - a) / width
        }
        return Self.percentages[Self.percentages.count - 1]
    }

    // MARK: - Validación

    /// Clampea al rango y empuja las filas para que no queden a menos de `minGap` grados.
    /// Con cinco filas sobra lugar, pero el empuje va primero hacia arriba y, si se pasa del
    /// máximo, vuelve desde el final para que todo quede dentro de 30–105 °C.
    private static func sanitized(_ values: [Double]) -> [Double] {
        guard values.count == percentages.count else { return defaultTemps }
        var temps = values.map { value in
            guard value.isFinite else { return minTemp }
            return min(max(value.rounded(), minTemp), maxTemp)
        }
        for i in 1..<temps.count {
            temps[i] = max(temps[i], temps[i - 1] + minGap)
        }
        if let last = temps.last, last > maxTemp {
            temps[temps.count - 1] = maxTemp
            for i in stride(from: temps.count - 2, through: 0, by: -1) {
                temps[i] = min(temps[i], temps[i + 1] - minGap)
            }
        }
        return temps
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case temps
        case points
    }

    /// Forma vieja de la curva (puntos libres). Solo sirve para migrar configuraciones.
    private struct LegacyPoint: Codable {
        var temp: Double
        var percent: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let temps = try? container.decode([Double].self, forKey: .temps), temps.count == Self.percentages.count {
            self.temps = Self.sanitized(temps)
        } else if let points = try? container.decode([LegacyPoint].self, forKey: .points) {
            self.temps = Self.migrated(from: points)
        } else {
            self.temps = Self.defaultTemps
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(temps, forKey: .temps)
    }

    /// Convierte una curva vieja de puntos libres a las cinco filas fijas: para cada porcentaje
    /// busca la menor temperatura a la que la curva anterior llegaba. Así se conserva la idea
    /// (a qué temperatura empieza a pedir cada tramo) aunque los porcentajes ya no se editen.
    private static func migrated(from points: [LegacyPoint]) -> [Double] {
        let sorted = points
            .filter { $0.temp.isFinite && $0.percent.isFinite }
            .sorted { $0.temp < $1.temp }
        guard let first = sorted.first, let last = sorted.last else { return defaultTemps }

        var temps: [Double] = []
        for target in percentages {
            if target <= first.percent {
                temps.append(first.temp)
                continue
            }
            if target >= last.percent {
                temps.append(last.temp)
                continue
            }
            var found: Double?
            for i in 1..<sorted.count {
                let a = sorted[i - 1], b = sorted[i]
                guard a.percent < target, target <= b.percent else { continue }
                let width = b.percent - a.percent
                let fraction = width > 0 ? (target - a.percent) / width : 1
                found = a.temp + fraction * (b.temp - a.temp)
                break
            }
            temps.append(found ?? last.temp)
        }
        return sanitized(temps)
    }
}

// MARK: - Ajustes

struct FanLiteSettings: Codable {
    var mode: FanMode = .auto
    var curve: Curve = .fallback
    /// Claves de temperatura descubiertas una vez y guardadas: así el arranque siguiente
    /// no tiene que recorrer las 3600 claves del SMC.
    var cpuTempKeys: [String]? = nil
    /// Período base de muestreo, en segundos. El controlador lo estira si la temperatura está
    /// quieta (hasta 3 s) y lo acorta si se mueve (hasta 1,5 s).
    var interval: Double = 2.0

    /// Pide la contraseña al abrir la app si la última vez se usó Curva o Máx.
    /// Opcional a propósito: las configs viejas (sin esta clave) decodifican sin migración y
    /// el valor por defecto es `true`.
    var autoElevateOnLaunch: Bool? = nil

    var wantsAutoElevation: Bool { autoElevateOnLaunch ?? true }
}

// MARK: - Rutas (funciona igual como usuario y como root)

/// El home del usuario que está en la consola (cuando corremos como root el home es /var/root,
/// y la config tiene que seguir siendo del usuario).
enum Paths {
    static var consoleHome: String {
        if geteuid() != 0 { return NSHomeDirectory() }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
        task.arguments = ["-f", "%Su", "/dev/console"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        if (try? task.run()) != nil {
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let user = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !user.isEmpty, user != "root", let home = NSHomeDirectoryForUser(user) {
                return home
            }
        }
        return NSHomeDirectory()
    }

    static var supportDirectory: URL {
        URL(fileURLWithPath: consoleHome).appendingPathComponent("Library/Application Support/FanLite")
    }

    static let defaultLog = URL(fileURLWithPath: "/dev/null")   // se reemplaza abajo
    /// --simulate redirige el log para no ensuciar el real.
    static var logOverride: URL?
    static var log: URL {
        if let logOverride { return logOverride }
        return URL(fileURLWithPath: consoleHome).appendingPathComponent("Library/Logs/FanLite.log")
    }

    static var config: URL { supportDirectory.appendingPathComponent("config.json") }
    /// Marcador del primer arranque de la GUI. Vive fuera de la config porque esta puede ser de root.
    static var firstLaunchMarker: URL { supportDirectory.appendingPathComponent("first-launch.done") }
}

enum Store {
    /// --simulate lo apaga para no tocar la config real.
    static var enabled = true

    static func load() -> FanLiteSettings {
        guard let data = try? Data(contentsOf: Paths.config),
              let settings = try? JSONDecoder().decode(FanLiteSettings.self, from: data) else {
            return FanLiteSettings()
        }
        return settings
    }

    static func save(_ settings: FanLiteSettings) {
        guard enabled else { return }
        do {
            try FileManager.default.createDirectory(at: Paths.supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: Paths.config, options: .atomic)
            adoptPathsForConsoleUser()
        } catch {
            log("no pude guardar los ajustes: \(error)")
        }
    }

    /// Cuando la app corre como root, el config y el log quedan en el home del usuario pero con
    /// dueño root. Si no se los devolvemos al usuario de la consola, la próxima instancia sin
    /// privilegios no puede guardar los ajustes (por ejemplo, el modo elegido antes de elevar).
    static func adoptPathsForConsoleUser() {
        guard geteuid() == 0 else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
              let uid = attrs[.ownerAccountID] as? NSNumber,
              let gid = attrs[.groupOwnerAccountID] as? NSNumber,
              uid.uint32Value != 0 else { return }

        let manager = FileManager.default
        var urls = [Paths.supportDirectory, Paths.config, Paths.log]
        urls.append(Paths.supportDirectory.appendingPathComponent("instance.pid"))
        urls.append(Paths.supportDirectory.appendingPathComponent("root.pid"))
        urls.append(Paths.firstLaunchMarker)
        for url in urls where manager.fileExists(atPath: url.path) {
            try? manager.setAttributes([
                .ownerAccountID: uid,
                .groupOwnerAccountID: gid,
            ], ofItemAtPath: url.path)
        }
    }
}

private let logFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Log chico a propósito: solo se escriben cambios de estado, no cada muestra.
/// Escribe de forma sincrónica: si el proceso se va a cerrar enseguida (o aborta), la línea
/// igual queda en el archivo.
func log(_ message: String) {
    let line = "\(logFormatter.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let url = Paths.log
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if handle.offsetInFile > 512 * 1024 { try? handle.truncate(atOffset: 0) }
        handle.write(Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
