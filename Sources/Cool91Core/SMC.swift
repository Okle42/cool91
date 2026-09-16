import Foundation
import CSMC

/// Swift 端 SMC 封裝：負責型別解碼與感測器掃描
public enum SMC {
    public struct Value {
        public let key: String
        public let type: String
        public let size: Int
        public let raw: [UInt8]

        /// 依 SMC 資料型別解碼為 Double（無法解碼回傳 nil）
        public var double: Double? {
            switch type {
            case "flt ":
                guard size == 4 else { return nil }
                return Double(raw.withUnsafeBytes { $0.load(as: Float32.self) })
            case "ui8 ": return Double(raw[0])
            case "ui16": return Double(UInt16(raw[0]) << 8 | UInt16(raw[1]))
            case "ui32": return Double(UInt32(raw[0]) << 24 | UInt32(raw[1]) << 16 | UInt32(raw[2]) << 8 | UInt32(raw[3]))
            case "si8 ": return Double(Int8(bitPattern: raw[0]))
            case "si16": return Double(Int16(bitPattern: UInt16(raw[0]) << 8 | UInt16(raw[1])))
            case "sp78": return Double(Int16(bitPattern: UInt16(raw[0]) << 8 | UInt16(raw[1]))) / 256.0
            case "fpe2": return Double(UInt16(raw[0]) << 8 | UInt16(raw[1])) / 4.0
            case "flag": return Double(raw[0])
            default: return nil
            }
        }
    }

    public static func open() throws {
        let kr = smc_open()
        if kr != 0 { throw Cool91Error.smc("smc_open 失敗 kr=\(kr)") }
    }

    public static func close() { smc_close() }

    public static func read(_ key: String) -> Value? {
        var type: UInt32 = 0, size: UInt32 = 0
        var bytes = [UInt8](repeating: 0, count: 32)
        let kr = key.withCString { smc_read($0, &type, &size, &bytes) }
        guard kr == 0 else { return nil }
        let t = String(bytes: [UInt8(type >> 24 & 0xff), UInt8(type >> 16 & 0xff), UInt8(type >> 8 & 0xff), UInt8(type & 0xff)], encoding: .ascii) ?? "????"
        return Value(key: key, type: t, size: Int(size), raw: Array(bytes.prefix(Int(size))))
    }

    public static func readDouble(_ key: String) -> Double? { read(key)?.double }

    public static func write(_ key: String, bytes: [UInt8]) throws {
        let kr = key.withCString { smc_write($0, UInt32(bytes.count), bytes) }
        if kr != 0 { throw Cool91Error.smc("寫入 \(key) 失敗 (\(kr))；寫 SMC 需要 sudo") }
    }

    public static func writeFloat(_ key: String, _ v: Float32) throws {
        var f = v
        let b = withUnsafeBytes(of: &f) { Array($0) }
        try write(key, bytes: b)
    }

    public static func writeUInt8(_ key: String, _ v: UInt8) throws { try write(key, bytes: [v]) }

    /// 列出所有 key 名稱
    public static func allKeys() -> [String] {
        let n = smc_key_count()
        guard n > 0 else { return [] }
        var out: [String] = []
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<n {
            if smc_key_at_index(UInt32(i), &buf) == 0 { out.append(String(cString: buf)) }
        }
        return out
    }

    /// 溫度讀值是否合理（SMC 偶爾回 0 / 1 / 負數這種假值）
    public static func plausibleTemp(_ t: Double) -> Bool { t > 10 && t < 125 }

    /// 掃描看起來像溫度的感測器：T 開頭、flt/sp78 型別、值在合理範圍
    public static func scanTemperatureKeys() -> [(String, Double)] {
        allKeys().filter { $0.hasPrefix("T") }.compactMap { k in
            guard let v = read(k), v.type == "flt " || v.type == "sp78", let d = v.double, plausibleTemp(d) else { return nil }
            return (k, d)
        }
    }

    // MARK: 風扇

    public static var fanCount: Int { Int(readDouble("FNum") ?? 0) }

    public struct Fan {
        public let index: Int
        public let actual: Double
        public let min: Double
        public let max: Double
        public let target: Double
        public let manual: Bool
    }

    public static func fan(_ i: Int) -> Fan? {
        guard let a = readDouble("F\(i)Ac") else { return nil }
        return Fan(index: i,
                   actual: a,
                   min: readDouble("F\(i)Mn") ?? 0,
                   max: readDouble("F\(i)Mx") ?? 0,
                   target: readDouble("F\(i)Tg") ?? 0,
                   manual: (readDouble("F\(i)Md") ?? 0) != 0)
    }

    public static func fans() -> [Fan] { (0..<fanCount).compactMap(fan) }

    /// 手動設定目標轉速（需 root）
    public static func setFan(_ i: Int, rpm: Double) throws {
        try writeUInt8("F\(i)Md", 1)
        try writeFloat("F\(i)Tg", Float32(rpm))
    }

    /// 交還 SMC 自動控制（需 root）
    public static func setFanAuto(_ i: Int) throws {
        try writeUInt8("F\(i)Md", 0)
    }
}

public enum Cool91Error: Error, CustomStringConvertible {
    case smc(String)
    case usage(String)
    public var description: String {
        switch self {
        case .smc(let s), .usage(let s): return s
        }
    }
}
