import Foundation

/// 年+月筛选的日期区间（半开区间）。
/// 统一生成 `[yyyy-MM-01, nextMonth-01)`，12 月自动进年。
public enum DateRange {
    /// 返回 `[yyyy-MM-01, 下月 01)`；year 必须恰 4 位数字、month 1..12，否则 nil
    public static func monthRange(_ year: String, _ month: String) -> (String, String)? {
        let y = year.trimmingCharacters(in: .whitespaces)
        if y.count != 4 || !y.allSatisfy({ $0.isNumber }) { return nil }
        let m = Int(month.trimmingCharacters(in: .whitespaces))
        guard let m, 1...12 ~= m else { return nil }
        let yInt = Int(y)!
        let first = String(format: "%04d-%02d-01", yInt, m)
        let second: String
        if m == 12 {
            second = String(format: "%04d-01-01", yInt + 1)
        } else {
            second = String(format: "%04d-%02d-01", yInt, m + 1)
        }
        return (first, second)
    }
}
