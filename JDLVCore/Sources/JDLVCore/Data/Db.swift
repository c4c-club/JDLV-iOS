import Foundation
import MySQLNIO

// Db 门面（对齐 Android data/Db.kt）：连接与执行在 MySQLPool；本层保留
// init/query/scalar/check/reset/tables/tableOf/cols/offline 标记形状。
// 异常向上抛（不吞），由调用方（Q 各函数）决定探活/兜底。

public enum Db {
    // MARK: 配置

    /// 注入设置提供器 + 无网判定（App 层调用；settings 变更后须 Db.reset()）
    public static func configure(
        settingsProvider: @escaping () -> MySQLPoolSettings?,
        hasNetwork: (() -> Bool)?
    ) {
        MySQLPool.shared.settingsProvider = settingsProvider
        MySQLPool.shared.hasNetwork = hasNetwork
    }

    /// 全部连接作废（数据源/代理/超时变更时调用）：resetAll 已同时清离线软标记
    public static func reset() {
        MySQLPool.shared.resetAll()
        invalidateSchema()
    }

    // MARK: 离线标记（读透传）

    public static var offlineJdb: Bool { OfflineGate.isOffline("jdb") }
    public static var offlineSht: Bool { OfflineGate.isOffline("sht") }
    public static var offlineAll: Bool { OfflineGate.allOffline }

    public static func markOffline(_ which: String, ms: Int64 = 60_000) {
        OfflineGate.mark(which, ttlMs: ms)
    }

    public static func clearOffline(_ which: String? = nil) {
        OfflineGate.clear(which)
    }

    // MARK: 查询

    /// 只读查询 → [Row]；语句超时 = 设置里的查询超时（默认 8s）；执行前经 SqlPolicy.guard
    public static func query(
        _ which: String, _ sql: String, _ params: [SQLValue?] = []
    ) async throws -> [Row] {
        try await MySQLPool.shared.query(which: which, sql: sql, params: params)
    }

    /// 标量：第一行第一列；Number→Long，否则字符串解析，兜底 0L；空结果 → 0L
    public static func scalar(
        _ which: String, _ sql: String, _ params: [SQLValue?] = []
    ) async throws -> Int64 {
        let rows = try await query(which, sql, params)
        guard let first = rows.first else { return 0 }
        guard let key = first.keys.first else { return 0 }
        return first.i(key)
    }

    /// 在线探测：一次性短连接（不进池、语句超时 2s）；成功清该库离线标记
    public static func check(_ which: String) async -> Bool {
        await MySQLPool.shared.ping(which)
    }

    // MARK: Schema 探测（失败不缓存 —— NA-03）

    private static let schemaLock = NSLock()
    private static var tablesCache: [String: Set<String>] = [:]
    private static var colsCache: [String: Set<String>] = [:]

    public static func invalidateSchema() {
        schemaLock.lock()
        tablesCache.removeAll()
        colsCache.removeAll()
        schemaLock.unlock()
    }

    /// 表名集合（SELECT TABLE_NAME t FROM information_schema.tables WHERE TABLE_SCHEMA = DATABASE()）
    public static func tables(_ which: String) async -> Set<String> {
        schemaLock.lock()
        if let hit = tablesCache[which] {
            schemaLock.unlock()
            return hit
        }
        schemaLock.unlock()
        do {
            let rows = try await query(
                which,
                "SELECT TABLE_NAME t FROM information_schema.tables " +
                    "WHERE TABLE_SCHEMA = DATABASE()")
            let set = Set(rows.map { $0.s("t") })
            if !set.isEmpty {
                schemaLock.lock()
                tablesCache[which] = set
                schemaLock.unlock()
            }
            return set
        } catch {
            return []   // 失败不写缓存
        }
    }

    /// sht 库 threads → sht_threads（若存在）；jdb 库 movies 保持 movies
    public static func tableOf(_ which: String, _ base: String) async -> String {
        let candidates = ["sht_\(base)", base]
        let ts = await tables(which)
        for c in candidates where ts.contains(c) {
            return c
        }
        return base
    }

    /// 列名集合（SHOW COLUMNS FROM `$table`；表名来自 tableOf，非用户输入）
    public static func cols(_ which: String, _ table: String) async -> Set<String> {
        let key = "\(which).\(table)"
        schemaLock.lock()
        if let hit = colsCache[key] {
            schemaLock.unlock()
            return hit
        }
        schemaLock.unlock()
        do {
            let rows = try await query(which, "SHOW COLUMNS FROM `\(table)`")
            var set = Set<String>()
            for r in rows {
                if let f = r.map["Field"], case .string(let v) = f {
                    set.insert(v)
                } else if !r.s("Field").isEmpty {
                    set.insert(r.s("Field"))
                }
            }
            if !set.isEmpty {
                schemaLock.lock()
                colsCache[key] = set
                schemaLock.unlock()
            }
            return set
        } catch {
            return []   // 失败不写缓存
        }
    }
}
