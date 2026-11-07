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
/// A10/R10：额外记录列名顺序（normRow 按 columnDefinitions 首位写入）——
/// scalar「第一行第一列」不再依赖无序字典的 keys.first。
public struct Row: Equatable {
    public private(set) var map: [String: SQLValue]
    /// 列名顺序（按结果集列定义；手工构造的 Row 为字典键序）
    public private(set) var orderedKeys: [String]

    public init(_ map: [String: SQLValue] = [:]) {
        self.map = map
        self.orderedKeys = Array(map.keys)
    }

    /// normRow 专用：带列序构造
    init(map: [String: SQLValue], orderedKeys: [String]) {
        self.map = map
        self.orderedKeys = orderedKeys
    }

    public subscript(key: String) -> SQLValue? {
        get { map[key] }
        set { map[key] = newValue }
    }

    public var keys: [String] { Array(map.keys) }

    /// 安全字符串取列（Android JRow.s 语义：value?.toString() ?: ""；Boolean → "true"/"false"）
    public func s(_ key: String) -> String {
        switch map[key] {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return v ? "true" : "false"
        case .data(let v): return String(data: v, encoding: .utf8) ?? ""
        default: return ""
        }
    }

    /// 整型取列（Number→数值，否则字符串解析，兜底 0；parse 失败归 0）
    public func i(_ key: String) -> Int64 {
        switch map[key] {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Int64(v) ?? 0
        default: return 0
        }
    }

    /// 长整型取列（与 i 同语义；Kotlin l → Long）
    public func l(_ key: String) -> Int64 {
        i(key)
    }

    /// 浮点取列（Number→数值，否则字符串解析，兜底 0.0）
    public func d(_ key: String) -> Double {
        switch map[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v) ?? 0.0
        default: return 0.0
        }
    }

    /// 布尔取列（Boolean 原样；数值判 ==1；字符串判 "1" 或忽略大小写 "true"）
    public func b(_ key: String) -> Bool {
        switch map[key] {
        case .bool(let v): return v
        case .int(let v): return v == 1
        case .string(let v): return v == "1" || v.lowercased() == "true"
        default: return false
        }
    }

    public func isNull(_ key: String) -> Bool {
        let v = map[key]
        return v == nil || v == .null
    }
}

/// 每页条数归一（Android normalizePer）：合法档位 20/40/60/80/100；
/// v>0 取最接近档位（并列取第一个较小档），v<=0 用 default。
public func normalizePer(_ v: Int, default def: Int = 40) -> Int {
    let opts = [20, 40, 60, 80, 100]
    if opts.contains(v) { return v }
    let base = v > 0 ? v : def
    return opts.min(by: { abs($0 - base) < abs($1 - base) }) ?? def
}
