import Foundation

//
//  LocalStore —— 本地收藏/已读（jdlv_local.db v1）。
//  对齐 Android app/src/main/java/com/jdlv/mobile/data/LocalStore.kt
//  （提取对照: docs/_extract/13_theme_prefs_models.md §C, 逐字）。
//
//  - DDL 逐字: favorites / read_history 两表, 主键 (kind, item_id), ts 为 epoch 秒 REAL。
//  - Android 无 onConfigure → 非 WAL（保持默认 rollback journal, 1:1 移植）。
//  - 收藏 toggle = 存在性判定; 已读 mark = INSERT OR REPLACE（重复标记刷新 ts）。
//  - favList 按 ts DESC（新→旧）, 行键 kind/id/title/ts（item_id 改名 id, 对齐 Android JRow）。
//  - 批量存在性 batchSet: 500 条/块 IN 查询（SQLite 变量上限 999, 分块防炸 —— Android A-1）。
//
public final class LocalStore {

    public static let DB_NAME = "jdlv_local.db"

    /// internal: 测试（@testable）可直接回填 ts / 验证 DDL
    let db: SQLite

    public init(directory: String) throws {
        db = try SQLite(path: Self.filePath(in: directory), wal: false)
        try createAll()
    }

    public static func filePath(in directory: String) -> String {
        directory.hasSuffix("/") ? directory + DB_NAME : directory + "/" + DB_NAME
    }

    public func close() { db.close() }

    // MARK: - DDL（逐字）

    private static let DDL: [String] = [
        "CREATE TABLE IF NOT EXISTS favorites(" +
            "kind TEXT, item_id TEXT, title TEXT, ts REAL," +
            "PRIMARY KEY(kind, item_id))",
        "CREATE TABLE IF NOT EXISTS read_history(" +
            "kind TEXT, item_id TEXT, title TEXT, ts REAL," +
            "PRIMARY KEY(kind, item_id))",
    ]

    private func createAll() throws {
        for sql in Self.DDL { try db.exec(sql) }
    }

    // MARK: - 收藏

    /// toggle → true=已收藏。存在则 DELETE 返回 false, 否则 INSERT（ts=now 秒）返回 true。
    @discardableResult
    public func favToggle(kind: String, itemId: String, title: String) throws -> Bool {
        try db.transaction {
            let exists = try db.scalar(
                "SELECT 1 FROM favorites WHERE kind = ? AND item_id = ?",
                [.string(kind), .string(itemId)]) != nil
            if exists {
                try db.run("DELETE FROM favorites WHERE kind = ? AND item_id = ?",
                           [.string(kind), .string(itemId)])
                return false
            }
            try db.run(
                "INSERT INTO favorites(kind, item_id, title, ts) VALUES(?, ?, ?, ?)",
                [.string(kind), .string(itemId), .string(title),
                 .double(Date().timeIntervalSince1970)])
            return true
        }
    }

    public func favIs(kind: String, itemId: String) throws -> Bool {
        try db.scalar(
            "SELECT 1 FROM favorites WHERE kind = ? AND item_id = ?",
            [.string(kind), .string(itemId)]) != nil
    }

    /// SELECT kind, item_id, title, ts FROM favorites [WHERE kind=?] ORDER BY ts DESC;
    /// 每行键 kind/id/title/ts（ts REAL 秒）。
    public func favList(kind: String? = nil) throws -> [Row] {
        let sql: String
        let params: [SQLValue?]
        if let kind, !kind.isEmpty {
            sql = "SELECT kind, item_id, title, ts FROM favorites WHERE kind = ? ORDER BY ts DESC"
            params = [.string(kind)]
        } else {
            sql = "SELECT kind, item_id, title, ts FROM favorites ORDER BY ts DESC"
            params = []
        }
        return try db.query(sql, params).map { r in
            Row([
                "kind": .string(r.s("kind")),
                "id": .string(r.s("item_id")),
                "title": .string(r.s("title")),
                "ts": r["ts"] ?? .null,
            ])
        }
    }

    // MARK: - 已读

    /// INSERT OR REPLACE（upsert, 重复标记刷新 ts）。
    public func historyMark(kind: String, itemId: String, title: String) throws {
        try db.run(
            "INSERT OR REPLACE INTO read_history(kind, item_id, title, ts) VALUES(?, ?, ?, ?)",
            [.string(kind), .string(itemId), .string(title),
             .double(Date().timeIntervalSince1970)])
    }

    public func historyIs(kind: String, itemId: String) throws -> Bool {
        try db.scalar(
            "SELECT 1 FROM read_history WHERE kind = ? AND item_id = ?",
            [.string(kind), .string(itemId)]) != nil
    }

    /// 批量: 返回 ids 中已读的子集。
    public func historySet(kind: String, ids: [String]) throws -> Set<String> {
        try batchSet(table: "read_history", kind: kind, ids: ids)
    }

    /// 批量: 返回 ids 中已收藏的子集。
    public func favSet(kind: String, ids: [String]) throws -> Set<String> {
        try batchSet(table: "favorites", kind: kind, ids: ids)
    }

    /// ★ A-1: 列表页逐条单查 → 一次 IN 查询; 每块 500 条（SQLite 变量上限 999, 分块防炸）。
    private func batchSet(table: String, kind: String, ids: [String]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var out = Set<String>()
        var start = 0
        while start < ids.count {
            let end = min(start + 500, ids.count)
            let chunk = Array(ids[start..<end])
            let ph = chunk.map { _ in "?" }.joined(separator: ",")
            var params: [SQLValue?] = [.string(kind)]
            params.append(contentsOf: chunk.map { SQLValue?.some(.string($0)) })
            let rows = try db.query(
                "SELECT item_id FROM \(table) WHERE kind = ? AND item_id IN (\(ph))", params)
            for r in rows where !r.isNull("item_id") { out.insert(r.s("item_id")) }
            start = end
        }
        return out
    }
}
