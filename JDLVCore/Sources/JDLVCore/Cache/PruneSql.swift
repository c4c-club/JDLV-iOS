import Foundation

/// 裁剪结果三态：Success（游标必须重置到 boundary）/ Noop（count<=limit，不重置游标）/
/// Failed（事务已回滚，done 必须保持 0 并退避重试）。
public enum PruneOutcome: Equatable {
    case success(deleted: Int64, boundaryDate: String?, boundaryId: String?)
    case noop(boundaryDate: String?, boundaryId: String?)
    case failed(String)

    public var boundaryDate: String? {
        switch self {
        case .success(_, let d, _): return d
        case .noop(let d, _): return d
        case .failed: return nil
        }
    }

    public var boundaryId: String? {
        switch self {
        case .success(_, _, let i): return i
        case .noop(_, let i): return i
        case .failed: return nil
        }
    }
}

/// 索引裁剪 SQL 生成器（生产 IdxDb 只执行此处生成的语句）。
/// 淘汰序 = 数据扫描序：movies `(release_date ASC, id ASC)`（最旧先删），threads `tid ASC`。
/// 明确不带 updated_at（写入时间不代表数据新旧）。
public enum PruneSql {
    public static let MOVIE_EVICT_ORDER = "release_date ASC, id ASC"
    public static let THREAD_EVICT_ORDER = "tid ASC"

    public static let MOVIE_BOUNDARY =
        "SELECT release_date, id FROM idx_movies ORDER BY \(MOVIE_EVICT_ORDER) LIMIT 1 OFFSET ?"
    public static let THREAD_BOUNDARY =
        "SELECT tid FROM idx_threads ORDER BY \(THREAD_EVICT_ORDER) LIMIT 1 OFFSET ?"

    public static func movieStatements(_ offset: Int64) -> [(String, [String])] {
        [
            ("DROP TABLE IF EXISTS temp._del_ids", []),
            ("CREATE TEMP TABLE _del_ids(id TEXT PRIMARY KEY)", []),
            ("INSERT INTO _del_ids(id) SELECT id FROM idx_movies " +
                "ORDER BY \(MOVIE_EVICT_ORDER) LIMIT ?", [String(offset)]),
            ("DELETE FROM idx_movies WHERE id IN (SELECT id FROM _del_ids)", []),
            ("DELETE FROM idx_movie_tags WHERE movie_id IN (SELECT id FROM _del_ids)", []),
            ("DELETE FROM idx_movie_actors WHERE movie_id IN (SELECT id FROM _del_ids)", []),
            ("DROP TABLE IF EXISTS temp._del_ids", []),
        ]
    }

    public static func threadStatements(_ offset: Int64) -> [(String, [String])] {
        [
            ("DROP TABLE IF EXISTS temp._del_ids", []),
            ("CREATE TEMP TABLE _del_ids(id TEXT PRIMARY KEY)", []),
            ("INSERT INTO _del_ids(id) SELECT tid FROM idx_threads " +
                "ORDER BY \(THREAD_EVICT_ORDER) LIMIT ?", [String(offset)]),
            ("DELETE FROM idx_threads WHERE tid IN (SELECT id FROM _del_ids)", []),
            ("DROP TABLE IF EXISTS temp._del_ids", []),
        ]
    }
}
