import Foundation
import CSMC

// Cliente SMC mínimo. Todo pasa por una sola cola serial: la conexión y el caché de
// key-info no se tocan nunca desde dos hilos a la vez.

struct KeyInfo {
    var size: Int
    var type: String          // 4 caracteres tal cual los devuelve el SMC ("flt ", "ui8 ")
    var attributes: UInt8

    var isWritable: Bool { attributes & 0x40 != 0 }
    var isReadable: Bool { attributes & 0x80 != 0 }
    /// Tipo sin el relleno de espacios: "flt", "ui8", "fpe2"...
    var cleanType: String { type.trimmingCharacters(in: .whitespaces) }
}

enum SMCFault: Error, CustomStringConvertible {
    case noService
    case openFailed(kern_return_t)
    case missingKey(String)
    case callFailed(String, UInt8, kern_return_t)
    case smcResult(String, UInt8, UInt8)
    case wrongSize(String, expected: Int, got: Int)
    case badType(String, String)

    var description: String {
        switch self {
        case .noService:
            return "esta Mac no expone AppleSMC"
        case .openFailed(let kr):
            return "IOServiceOpen(AppleSMC) falló: 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case .missingKey(let k):
            return "la clave \(k) no existe"
        case .callFailed(let k, let cmd, let kr):
            return "\(k) (cmd \(cmd)): IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case .smcResult(let k, let cmd, let r):
            return "\(k) (cmd \(cmd)): el SMC devolvió 0x\(String(r, radix: 16))"
        case .wrongSize(let k, let expected, let got):
            return "\(k): payload de \(got) bytes, la clave es de \(expected)"
        case .badType(let k, let t):
            return "\(k): tipo inesperado \(t)"
        }
    }

    var isMissing: Bool { if case .missingKey = self { return true }; return false }
    /// Errores que no tiene sentido reintentar.
    var isPermanent: Bool {
        switch self {
        case .wrongSize, .badType, .missingKey, .noService: return true
        default: return false
        }
    }
}

func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    var n = 0
    for b in s.utf8 where n < 4 { v = (v << 8) | UInt32(b); n += 1 }
    return n == 4 ? v : (v << (8 * UInt32(4 - n)))
}

func fourCCString(_ v: UInt32) -> String {
    let bytes: [UInt8] = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .utf8) ?? "????"
}

/// Lo que el controlador necesita del SMC. `SMC` es la implementación real; `FakeSMC`
/// (--simulate) permite probar la lógica de control sin tocar el hardware.
protocol SMCDevice: AnyObject {
    func info(_ key: String) throws -> KeyInfo
    func bytes(_ key: String) throws -> [UInt8]
    func write(_ key: String, _ value: [UInt8]) throws
    func number(_ key: String) throws -> Double?
    func numbers(_ keys: [String]) -> [String: Double]
    func uint8(_ key: String) throws -> Int?
    func allKeys() -> [String]
    /// Descarta el caché de key-info que no se vaya a volver a usar.
    func trimInfoCache(keeping keys: Set<String>)
}

extension SMCDevice {
    /// Versión genérica para los SMC que no tienen una implementación por lote.
    func numbers(_ keys: [String]) -> [String: Double] {
        var values = [String: Double](minimumCapacity: keys.count)
        for key in keys {
            do {
                if let value = try number(key), value.isFinite { values[key] = value }
            } catch {}
        }
        return values
    }

    func trimInfoCache(keeping keys: Set<String>) {}
}

/// Codifica un objetivo de RPM para el tipo real de la clave de destino.
func encodeRPM(_ rpm: Double, type: String) -> [UInt8]? {
    switch type.trimmingCharacters(in: .whitespaces) {
    case "flt":
        var f = Float(rpm)
        return withUnsafeBytes(of: &f) { Array($0) }
    case "fpe2":
        let raw = Int((rpm * 4).rounded())
        let clamped = Int16(clamping: max(0, min(raw, Int(Int16.max))))
        return [UInt8(UInt8(truncatingIfNeeded: clamped >> 8)), UInt8(UInt8(truncatingIfNeeded: clamped & 0xff))]
    default:
        return nil
    }
}

/// Contadores que llegan al kernel desde que arrancó el proceso (los lleva la capa C).
func smcCallStats() -> (reads: UInt64, writes: UInt64) {
    (fp_smc_stat_reads(), fp_smc_stat_writes())
}

final class SMC: SMCDevice {
    private var conn: fp_smc_conn_t = 0
    private let queue = DispatchQueue(label: "fanlite.smc")
    private var infoCache: [String: KeyInfo] = [:]

    init() throws {
        var c: fp_smc_conn_t = 0
        let kr = fp_smc_open(&c)
        if kr == kIOReturnNotFound { throw SMCFault.noService }
        guard kr == KERN_SUCCESS, c != 0 else { throw SMCFault.openFailed(kr) }
        conn = c
    }

    deinit {
        if conn != 0 { fp_smc_close(conn) }
    }

    // MARK: - Key info

    func info(_ key: String) throws -> KeyInfo {
        try queue.sync { try infoLocked(key) }
    }

    private func infoLocked(_ key: String) throws -> KeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData_t()
        input.key = fourCC(key)
        input.data8 = UInt8(FP_SMC_CMD_KEY_INFO)
        let out = try call(&input, key: key, write: false)
        let size = Int(out.keyInfo.dataSize)
        guard size > 0, size <= 32 else { throw SMCFault.missingKey(key) }
        let info = KeyInfo(size: size, type: fourCCString(out.keyInfo.dataType), attributes: out.keyInfo.dataAttributes)
        infoCache[key] = info
        return info
    }

    // MARK: - Read / write

    func bytes(_ key: String) throws -> [UInt8] {
        try queue.sync {
            let info = try infoLocked(key)
            return try readLocked(key, info: info)
        }
    }

    private func readLocked(_ key: String, info: KeyInfo) throws -> [UInt8] {
        var input = SMCKeyData_t()
        input.key = fourCC(key)
        input.data8 = UInt8(FP_SMC_CMD_READ)
        input.keyInfo.dataSize = UInt32(info.size)
        let out = try call(&input, key: key, write: false)
        var buf = [UInt8](repeating: 0, count: info.size)
        var o = out
        fp_smc_get_bytes(&o, &buf, info.size)
        return buf
    }

    func write(_ key: String, _ value: [UInt8]) throws {
        try queue.sync {
            let info = try infoLocked(key)
            guard value.count == info.size else {
                throw SMCFault.wrongSize(key, expected: info.size, got: value.count)
            }
            var input = SMCKeyData_t()
            input.key = fourCC(key)
            input.data8 = UInt8(FP_SMC_CMD_WRITE)
            input.keyInfo.dataSize = UInt32(info.size)
            // dataType queda en cero a propósito: así lo manda el resto del mundo.
            fp_smc_set_bytes(&input, value, value.count)
            _ = try call(&input, key: key, write: true)
        }
    }

    private func call(_ input: inout SMCKeyData_t, key: String, write: Bool) throws -> SMCKeyData_t {
        guard conn != 0 else { throw SMCFault.missingKey(key) }
        var out = SMCKeyData_t()
        let cmd = input.data8
        let kr = write ? fp_smc_call_write(conn, &input, &out) : fp_smc_call_read(conn, &input, &out)
        guard kr == KERN_SUCCESS else { throw SMCFault.callFailed(key, cmd, kr) }
        switch out.result {
        case UInt8(FP_SMC_RESULT_OK):
            return out
        case UInt8(FP_SMC_RESULT_NOT_FOUND):
            throw SMCFault.missingKey(key)
        default:
            throw SMCFault.smcResult(key, cmd, out.result)
        }
    }

    // MARK: - Números

    /// Valor numérico de una clave, o nil si la clave no existe o su tipo no es numérico.
    func number(_ key: String) throws -> Double? {
        try queue.sync { try numberLocked(key) }
    }

    /// Varias claves en una sola entrada a la cola del SMC: una vuelta de control toca
    /// temperaturas y estado de todos los ventiladores, así que hacerlo de a una suma
    /// decenas de `dispatch_sync` por segundo sin necesidad.
    func numbers(_ keys: [String]) -> [String: Double] {
        queue.sync {
            var values = [String: Double](minimumCapacity: keys.count)
            for key in keys {
                do {
                    if let value = try numberLocked(key), value.isFinite { values[key] = value }
                } catch {}
            }
            return values
        }
    }

    private func numberLocked(_ key: String) throws -> Double? {
        do {
            let info = try infoLocked(key)
            let b = try readLocked(key, info: info)
            switch info.cleanType {
            case "flt":
                guard b.count == 4 else { throw SMCFault.badType(key, "flt de \(b.count) bytes") }
                let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
                return Double(Float(bitPattern: bits))
            case "fpe2":
                guard b.count == 2 else { throw SMCFault.badType(key, "fpe2 de \(b.count) bytes") }
                return Double((Int(b[0]) << 8) | Int(b[1])) / 4.0
            case "ui8":
                return Double(b[0])
            case "ui16":
                guard b.count == 2 else { throw SMCFault.badType(key, "ui16 de \(b.count) bytes") }
                return Double((UInt16(b[0]) << 8) | UInt16(b[1]))
            case "ui32":
                guard b.count == 4 else { throw SMCFault.badType(key, "ui32 de \(b.count) bytes") }
                return Double((UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3]))
            default:
                return nil
            }
        } catch let fault as SMCFault where fault.isMissing {
            return nil
        }
    }

    func uint8(_ key: String) throws -> Int? {
        guard let v = try number(key) else { return nil }
        return Int(v)
    }

    /// El descubrimiento consulta el key-info de cientos de sensores; una vez elegidos los
    /// que se van a leer, el resto no se usa nunca más.
    func trimInfoCache(keeping keys: Set<String>) {
        queue.sync {
            infoCache = infoCache.filter { keys.contains($0.key) }
        }
    }

    // MARK: - Enumeración

    var keyCount: Int {
        (try? number("#KEY")).flatMap { $0 } .map { Int($0) } ?? 0
    }

    /// Todos los nombres de clave (3613 en esta Mac, ~1 s). Solo se usa para descubrir
    /// una vez qué sensores de temperatura existen.
    func allKeys() -> [String] {
        // El conteo se lee ANTES de tomar la cola: `keyCount` vuelve a entrar acá y un
        // dispatch_sync anidado sobre la misma cola aborta el proceso.
        let count = keyCount
        guard count > 0 else { return [] }
        return queue.sync {
            var keys: [String] = []
            keys.reserveCapacity(count)
            for i in 0..<count {
                var input = SMCKeyData_t()
                input.data8 = UInt8(FP_SMC_CMD_READ_INDEX)
                input.data32 = UInt32(i)
                if let out = try? call(&input, key: "#KEY", write: false) {
                    keys.append(fourCCString(out.key))
                }
            }
            return keys
        }
    }
}
