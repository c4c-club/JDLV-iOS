import Foundation

/// 远程派生窗口的唯一口径。
/// 仅月（无年）无法走 release_date 索引 → 最近 20000 部内 substr；
/// 列表与 COUNT 必须用同一窗口，否则 total 与可翻页条数不一致。
public enum DerivedWindow {
    public static let ONLY_MONTH_LIMIT = 20_000

    /// 仅月（month 非空且 year 为空）→ 窗口 20000；其他组合 → nil
    public static func of(_ f: Filters) -> Int? {
        if !f.month.trimmingCharacters(in: .whitespaces).isEmpty
            && f.year.trimmingCharacters(in: .whitespaces).isEmpty {
            return ONLY_MONTH_LIMIT
        }
        return nil
    }
}
