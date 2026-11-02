import Foundation

/// 索引上限纯逻辑。
/// 口径：落盘值 0 = 不限；旧哨兵（Int.max/2）读取时归一为 0；
/// targetOf 运行时把 0 转成长整型哨兵；万单位 1 位小数（截断）；条单位纯整数。
public enum LimitMath {
    /// 旧版"不限"哨兵阈值（≥ 此值读取时归一为 0）
    public static let UNLIMITED_MARK = Int32.max / 2

    public static let MAX_INPUT: Int64 = 5_000_000

    /// 落盘值归一：≥ UNLIMITED_MARK 的旧哨兵 → 0（=不限）
    public static func normalizeStored(_ v: Int) -> Int {
        v >= Int(UNLIMITED_MARK) ? 0 : v
    }

    /// 落盘值 → 运行时 target（0=不限 → 长整型哨兵）
    public static func targetOf(_ v: Int) -> Int64 {
        v <= 0 ? Int64.max / 2 : Int64(v)
    }

    /// 万单位解析（"24" → 240,000；"12.5" → 125,000）；非法（负/NaN/Infinity）→ nil
    public static func parseWan(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard let d = Double(t) else { return nil }
        if d < 0 || d.isNaN || d.isInfinite { return nil }
        // Kotlin toLong() 与 Swift Int64(Double) 均为向零截断
        return Int64(d * 10000)
    }

    /// 条单位解析（纯整数，≥0）；非法 → nil
    public static func parseCount(_ text: String) -> Int64? {
        guard let v = Int64(text.trimmingCharacters(in: .whitespaces)), v >= 0 else { return nil }
        return v
    }

    /// 千分位分组（固定 en_US 语义，等价 Java "%,d"）
    static func grouped(_ v: Int64) -> String {
        let s = String(v)
        var out = ""
        var count = 0
        for ch in s.reversed() {
            if count > 0 && count % 3 == 0 { out.insert(",", at: out.startIndex) }
            out.insert(ch, at: out.startIndex)
            count += 1
        }
        return out
    }

    /// 上限格式化："不限" / "24 万 (240,000)" / "12.5 万 (125,000)" / "9,999 条"
    public static func format(_ v: Int) -> String {
        if v <= 0 { return "不限" }
        if v >= 10000 {
            let whole: String
            if v % 10000 == 0 {
                whole = "\(v / 10000)"
            } else {
                whole = String(format: "%.1f", Double(v) / 10000.0)
            }
            return "\(whole) 万 (\(grouped(Int64(v))))"
        }
        return "\(grouped(Int64(v))) 条"
    }

    /// 输入合法性（0..5,000,000）
    public static func isValid(_ n: Int64?) -> Bool {
        guard let n else { return false }
        return 0...MAX_INPUT ~= n
    }
}
