import Foundation

/// 上限迁移决策（纯决策，无 IO）。
/// 关键语义：裁剪是本地操作，离线也必须执行；只有"重启引擎"依赖网络。
public enum LimitAction: String {
    case NO_CHANGE
    case META_ONLY
    case PRUNE_AND_RESTART
    case PRUNE_ONLY
    case RESTART
    case DEFER_OFFLINE
}

public struct LimitDecision: Equatable {
    public let action: LimitAction
    public let writeMeta: Bool
    public let pruneM: Bool
    public let pruneT: Bool
    public let restart: Bool
    public let nextDoneM: Bool
    public let nextDoneT: Bool
    public let reason: String
}

public enum LimitTransition {
    static func done(_ target: Int, _ count: Int64) -> Bool {
        target > 0 && count >= Int64(target)
    }

    public static func decide(
        _ prevM: Int, _ prevT: Int, _ nextM: Int, _ nextT: Int,
        _ countM: Int64, _ countT: Int64, _ running: Bool,
        _ onlineM: Bool, _ onlineT: Bool
    ) -> LimitDecision {
        // 同值分支最先判
        if prevM == nextM && prevT == nextT {
            return LimitDecision(
                action: .NO_CHANGE, writeMeta: false, pruneM: false, pruneT: false,
                restart: false,
                nextDoneM: done(nextM, countM), nextDoneT: done(nextT, countT),
                reason: "unchanged prev=\(prevM)/\(prevT) running=\(running)")
        }

        let pruneM = nextM > 0 && countM > Int64(nextM)   // 改小且当前超出
        let pruneT = nextT > 0 && countT > Int64(nextT)
        let afterM: Int64 = pruneM ? Int64(nextM) : countM
        let afterT: Int64 = pruneT ? Int64(nextT) : countT
        let moreM = nextM <= 0 || afterM < Int64(nextM)   // 0=不限 → 永远 more
        let moreT = nextT <= 0 || afterT < Int64(nextT)
        let needContinue = moreM || moreT
        let offlineNeeded = (moreM && !onlineM) || (moreT && !onlineT)

        let action: LimitAction
        if needContinue && offlineNeeded {
            action = .DEFER_OFFLINE
        } else if needContinue && (pruneM || pruneT) {
            action = .PRUNE_AND_RESTART
        } else if needContinue {
            action = .RESTART
        } else if pruneM || pruneT {
            action = .PRUNE_ONLY
        } else {
            action = .META_ONLY
        }
        let restart = action == .PRUNE_AND_RESTART || action == .RESTART
        return LimitDecision(
            action: action,
            writeMeta: true,
            pruneM: pruneM, pruneT: pruneT,
            restart: restart,
            nextDoneM: done(nextM, afterM),
            nextDoneT: done(nextT, afterT),
            reason: "m=\(prevM)->\(nextM) t=\(prevT)->\(nextT) count=\(countM)/\(countT) " +
                "prune=\(pruneM)/\(pruneT) more=\(moreM)/\(moreT) online=\(onlineM)/\(onlineT) " +
                "running=\(running) action=\(action.rawValue)")
    }
}
