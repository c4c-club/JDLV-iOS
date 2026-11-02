import Foundation

/// 值类型规范化容器（对齐 Android DbPool.norm 后的行值形态）。
/// norm 规则：BigDecimal→Double、Timestamp/Date→String、ByteArray→UTF-8 String、
/// 整型→Long（parse 失败 0）、浮点→Double（失败 0.0）、Boolean 原样、其余 toString。
public enum SQLValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case bool(Bool)
}

/// 行 = 列名 → SQLValue（对齐 Android JRow = Map<String, Any?>）。
public struct Row: Equatable {
    public private(set) var map: [String: SQLValue]

    public init(_ map: [String: SQLValue] = [:]) { self.map = map }

    public subscript(key: String) -> SQLValue? {
        get { map[key] }
        set { map[key] = newValue }
    }

    public var keys: [String] { Array(map.keys) }

    /// 安全字符串取列（Android JRow.s 语义：缺列/NULL → ""）
    public func s(_ key: String) -> String {
        switch map[key] {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "1" : "0"
        case .data(let v): return String(data: v, encoding: .utf8) ?? ""
        default: return ""
        }
    }

    /// 整型取列（parse 失败归 0）
    public func i(_ key: String) -> Int64 {
        switch map[key] {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Int64(v) ?? 0
        default: return 0
        }
    }

    public func d(_ key: String) -> Double {
        switch map[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v) ?? 0.0
        default: return 0.0
        }
    }

    public func b(_ key: String) -> Bool {
        switch map[key] {
        case .bool(let v): return v
        case .int(let v): return v != 0
        case .string(let v): return v == "1" || v.lowercased() == "true"
        default: return false
        }
    }

    public func isNull(_ key: String) -> Bool {
        let v = map[key]
        return v == nil || v == .null
    }
}
