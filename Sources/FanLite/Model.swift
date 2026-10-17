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

struct CurvePoint: Codable, Equatable {
    var temp: Double        // °C
    var percent: Double     // 0...100
}

struct Curve: Codable, Equatable {
    var points: [CurvePoint]

    static let fallback = Curve(points: [
        CurvePoint(temp: 45, percent: 0),
        CurvePoint(temp: 60, percent: 25),
        CurvePoint(temp: 72, percent: 45),
        CurvePoint(temp: 85, percent: 75),
        CurvePoint(temp: 95, percent: 100),
    ])

    var sorted: [CurvePoint] { points.sorted { $0.temp < $1.temp } }

    /// Interpolación lineal, plana fuera del primer y último punto.
    func percent(at temp: Double) -> Double {
        let p = sorted
        guard let first = p.first, let last = p.last else { return 0 }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }
        for i in 1..<p.count where temp <= p[i].temp {
            let a = p[i - 1], b = p[i]
            let width = b.temp - a.temp
            guard width > 0 else { return b.percent }
            return a.percent + (b.percent - a.percent) * (temp - a.temp) / width
        }
        return last.percent
    }
}

// MARK: - Ajustes

struct FanLiteSettings: Codable {
    var mode: FanMode = .auto
    var curve: Curve = .fallback
    /// Claves de temperatura descubiertas una vez y guardadas: así el arranque siguiente
    /// no tiene que recorrer las 3600 claves del SMC.
    var cpuTempKeys: [String]? = nil
    /// Cada cuánto se muestrea, en segundos.
    var interval: Double = 2.0
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
        } catch {
            log("no pude guardar los ajustes: \(error)")
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
