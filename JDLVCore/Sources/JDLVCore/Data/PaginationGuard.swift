import Foundation

public struct PageDecision: Equatable {
    public let page: Int
    public let clamped: Bool
    public let reason: String

    public init(page: Int, clamped: Bool, reason: String) {
        self.page = page
        self.clamped = clamped
        self.reason = reason
    }
}

/// 跳页钳制（纯函数）。
/// - 总页数 = ceil(total/per)（total>0）与 hardOffset/per 取更小者；
///   即使 total 很大，OFFSET 也不得超过 hardOffset（默认 5000 行）；
/// - total <= 0（未知）：按 hardOffset/per 钳深翻页上限；
/// - requested < 1 → 1。
public enum PaginationGuard {
    public static func clamp(
        requested: Int, total: Int64, per: Int, hardOffset: Int = 5000
    ) -> PageDecision {
        let p = per <= 0 ? 1 : per
        let req = max(1, requested)
        let offsetCap = max(1, hardOffset / p)
        let maxPage: Int
        let reason: String
        if total > 0 {
            let totalCap = max(1, Int(min(Int64(Int.max), (total + Int64(p) - 1) / Int64(p))))
            maxPage = min(totalCap, offsetCap)
            reason = "深翻页上限约 \(maxPage) 页（OFFSET≤\(hardOffset)）"
        } else {
            maxPage = offsetCap
            reason = "总数未知，深翻页上限约 \(maxPage) 页"
        }
        let page = min(max(req, 1), maxPage)
        return PageDecision(
            page: page,
            clamped: page != requested,
            reason: page != requested ? reason : "")
    }
}
