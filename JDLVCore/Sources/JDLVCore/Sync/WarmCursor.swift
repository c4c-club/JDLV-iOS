import Foundation

/// movies 预热游标相位。HEAD 态从不持久化读回（读回即 TAIL 兜底）。
public enum MoviePhase: String, CaseIterable {
    case head
    case same
    case tail
    case null
    case done
}

public struct MovieCursor: Equatable {
    public let phase: MoviePhase
    public let date: String
    public let id: String

    public init(phase: MoviePhase, date: String, id: String) {
        self.phase = phase
        self.date = date
        self.id = id
    }
}

/// movies 游标状态机（纯函数）。
public enum WarmCursor {
    /// NULL 相位哨兵日期
    public static let NULL_DATE = "__NULL__"

    /// 批推进：按当前相位用批末行推进 cursor（upsert 成功后才调用）。
    /// SAME/NULL 只推进 id；其余相位（TAIL/HEAD/兜底）→ SAME(lastDate, lastId)。
    public static func advance(_ cur: MovieCursor, lastDate: String, lastId: String) -> MovieCursor {
        switch cur.phase {
        case .same, .null:
            return MovieCursor(phase: cur.phase, date: cur.date, id: lastId)
        default:
            return MovieCursor(phase: .same, date: lastDate, id: lastId)
        }
    }

    /// 空批时的相位转移；返回 nil = 状态机结束（全部完成）。
    public static func nextWhenEmpty(_ cur: MovieCursor) -> MovieCursor? {
        switch cur.phase {
        case .same:
            return MovieCursor(phase: .tail, date: cur.date, id: cur.id)
        case .tail:
            return MovieCursor(phase: .null, date: NULL_DATE, id: "")
        case .null:
            return nil
        // HEAD/其它兜底 → tail 查询
        default:
            return MovieCursor(phase: .tail, date: cur.date, id: cur.id)
        }
    }

    /// idx_meta 持久化字符串 → 相位（""/其他 → TAIL，与旧 else 分支一致）
    public static func phaseOf(_ s: String?) -> MoviePhase {
        switch s {
        case "same": return .same
        case "tail": return .tail
        case "null": return .null
        case "done": return .done
        default: return .tail
        }
    }

    /// 相位 → idx_meta 持久化字符串
    public static func phaseStr(_ p: MoviePhase) -> String {
        p.rawValue
    }
}
