import Foundation

/// 预热目标计划（纯决策，无 IO）。
/// target <= 0 = 不限（内部 0 表示）；done=true 表示"当前目标已满足"；
/// exhausted=true 表示源库已扫完；shouldPrune = 目标有限且当前行数超过目标。
public struct TargetPlan: Equatable {
    public let target: Int64
    public let total: Int64
    public let done: Bool
    public let continueScan: Bool
    public let shouldPrune: Bool
    public let resetCursorToBoundary: Bool
}

public enum TargetPlanPolicy {
    public static func plan(target: Int, total: Int64, done: Bool, exhausted: Bool) -> TargetPlan {
        let t: Int64 = target <= 0 ? 0 : Int64(target)
        let reached = t > 0 && total >= t
        let finished = done || exhausted || reached
        let prune = t > 0 && total > t
        return TargetPlan(
            target: t,
            total: total,
            done: finished,
            continueScan: !finished,
            shouldPrune: prune,
            resetCursorToBoundary: prune)
    }

    /// finishRun 续跑判定：源在线 && 未 done && (不限 或 未达目标)，且本轮确有新增行。
    public static func moreWork(
        limM: Int, limT: Int, cntM: Int64, cntT: Int64,
        doneM: Bool, doneT: Bool, onlineM: Bool, onlineT: Bool, rowsThisRun: Int64
    ) -> Bool {
        if rowsThisRun <= 0 { return false }
        let moreM = onlineM && !doneM && (limM <= 0 || cntM < Int64(limM))
        let moreT = onlineT && !doneT && (limT <= 0 || cntT < Int64(limT))
        return moreM || moreT
    }
}
