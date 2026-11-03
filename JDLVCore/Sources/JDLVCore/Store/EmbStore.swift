import Foundation

//
//  EmbStore —— int8 向量本地表（embs.db v1）。
//  对齐 Android app/src/main/java/com/jdlv/mobile/core/cache/EmbStore.kt
//  （提取对照: docs/_extract/06_store.md §4, DDL/算法/参数逐字）。
//
//  要点:
//  - DDL 逐字: embs(tid INTEGER PRIMARY KEY, emb BLOB NOT NULL, dim INTEGER NOT NULL,
//    ver TEXT, ts INTEGER NOT NULL)。
//  - ★ 修复 Android 缺 kv 表 bug: onCreate 同时建 kv(k TEXT PRIMARY KEY, v TEXT)
//    （Android 只建 embs, 但 syncModelFp 读写 kv → 首装 "no such table: kv"）。
//  - WAL + synchronous=NORMAL（对齐 onConfigure）。
//  - maxBytes 默认 100MB（0 = 不限）; 超限按 ts ASC 淘汰到 90%（448B/条估算 = 384 向量 + 64 开销,
//    一次删除 (total-target)/448 + 1000 条）。
//  - usageBytes: 先 wal_checkpoint(TRUNCATE) 再 page_count×page_size（与 ShadowDb 同口径）。
//  - 指纹失效: syncModelFp(fp) 发现变化 → clear()（DELETE embs + DELETE kv.model_fp）并返回 true
//    （换模型后旧向量属于另一个向量空间, 混用必然全错）。
//  - 读批量 getExisting 按 900 tid/批; 写批量 putAll 单事务 REPLACE 后 prune()。
//
public struct EmbRecord: Equatable {
    public let emb: Data
    public let dim: Int32
    public let ver: String?
    public let ts: Int64

    public init(emb: Data, dim: Int32, ver: String?, ts: Int64) {
        self.emb = emb
        self.dim = dim
        self.ver = ver
        self.ts = ts
    }
}

public final class EmbStore {

    public static let DB_NAME = "embs.db"
    public static let DB_VERSION = 1

    /// DDL（逐字）
    public static let DDL_EMBS =
        "CREATE TABLE IF NOT EXISTS embs(" +
        "tid INTEGER PRIMARY KEY, emb BLOB NOT NULL, dim INTEGER NOT NULL," +
        "ver TEXT, ts INTEGER NOT NULL)"

    /// ★ 修复 Android bug: Android 的 onCreate 只建 embs, 但 syncModelFp 读写 kv → 首装必炸。
    public static let DDL_KV = "CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)"

    /// 默认 100MB（≈26 万条 × 384B）; 运行时由设置覆盖（embCacheMb MB, 0 = 不限）
    public var maxBytes: Int64 = 100 * 1024 * 1024

    /// internal: 测试（@testable）用
    let db: SQLite

    public init(directory: String) throws {
        db = try SQLite(path: Self.filePath(in: directory), wal: true)
        try db.exec(Self.DDL_EMBS)
        try db.exec(Self.DDL_KV)
        let v = db.pragmaInt("user_version")
        if v != 0 && v != Int64(Self.DB_VERSION) {
            try? db.exec("DROP TABLE IF EXISTS embs")   // onUpgrade → DROP embs + onCreate
            try db.exec(Self.DDL_EMBS)
        }
        db.setUserVersion(Self.DB_VERSION)
    }

    public static func filePath(in directory: String) -> String {
        directory.hasSuffix("/") ? directory + DB_NAME : directory + "/" + DB_NAME
    }

    public func close() { db.close() }

    // MARK: - 读

    /// 批量读（900 tid/批 WHERE tid IN (...)）。emb BLOB + dim + ver + ts 全量返回
    /// （Android 只回 Map<tid, ByteArray>, 维度校验由 Semantic 层另做 —— iOS 随行带 dim/ver 便于校验, 见报告）。
    public func getExisting(_ tids: [Int64]) throws -> [Int64: EmbRecord] {
        var out: [Int64: EmbRecord] = [:]
        var start = 0
        while start < tids.count {
            let end = min(start + 900, tids.count)
            let chunk = Array(tids[start..<end])
            let ph = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try db.query(
                "SELECT tid, emb, dim, ver, ts FROM embs WHERE tid IN (\(ph))",
                chunk.map { SQLValue?.some(.int($0)) })
            for r in rows {
                guard case .data(let emb)? = r["emb"] else { continue }
                let ver: String? = r.isNull("ver") ? nil : r.s("ver")
                out[r.i("tid")] = EmbRecord(
                    emb: emb,
                    dim: Int32(truncatingIfNeeded: r.i("dim")),
                    ver: ver,
                    ts: r.i("ts"))
            }
            start = end
        }
        return out
    }

    /// 当前向量维度（表空 → nil）。
    public func dim() throws -> Int32? {
        guard let v = try db.scalar("SELECT dim FROM embs LIMIT 1"),
              case .int(let x) = v else { return nil }
        return Int32(truncatingIfNeeded: x)
    }

    // MARK: - 指纹

    public func modelFp() throws -> String? {
        guard let v = try db.scalar("SELECT v FROM kv WHERE k = 'model_fp'") else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }

    /// 远程 model_fp 变化 → clear() 并返回 true（旧向量已清空, 调用方重新 putAll）。
    public func syncModelFp(_ fp: String) throws -> Bool {
        let old = try modelFp()
        if old == fp { return false }
        try clear()
        return true
    }

    // MARK: - 写

    /// 批量写: 单事务 CONFLICT_REPLACE 逐条插入（ver = fp, ts = now）+ kv.model_fp 落库, 写完 prune()。
    public func putAll(_ vectors: [Int64: Data], dim: Int32, fp: String?) throws {
        let now = storeNowMs()
        let ver: SQLValue = fp.map { SQLValue.string($0) } ?? .null
        try db.transaction {
            for (tid, emb) in vectors {
                try db.run(
                    "INSERT OR REPLACE INTO embs(tid, emb, dim, ver, ts) VALUES(?,?,?,?,?)",
                    [.int(tid), .data(emb), .int(Int64(dim)), ver, .int(now)])
            }
            if let fp {
                try db.run("INSERT OR REPLACE INTO kv(k, v) VALUES('model_fp', ?)", [.string(fp)])
            }
        }
        try prune()
    }

    // MARK: - 容量

    /// LRU 淘汰到 90% 预算（maxBytes <= 0 = 不限; 448B/条估算; ts ASC; 一次删 (total-target)/448+1000 条）。
    public func prune() throws {
        if maxBytes <= 0 { return }               // 0 = 不限
        let total = try usageBytes()
        if total <= maxBytes { return }
        let target = maxBytes * 9 / 10            // 90%
        let per: Int64 = 384 + 64                 // 每条估算 448 字节（384B 向量 + 64B 开销）
        let victims = (total - target) / per + 1000
        try db.run(
            "DELETE FROM embs WHERE tid IN (SELECT tid FROM embs ORDER BY ts ASC LIMIT ?)",
            [.int(victims)])
    }

    /// 先 wal_checkpoint(TRUNCATE) 再 page_count×page_size（不含 WAL 文件长度、不含 -shm）。
    public func usageBytes() throws -> Int64 {
        db.walCheckpointTruncate()
        return db.pragmaInt("page_count") * db.pragmaInt("page_size")
    }

    public func count() throws -> Int64 {
        guard let v = try db.scalar("SELECT COUNT(*) FROM embs"),
              case .int(let x) = v else { return 0 }
        return x
    }

    /// 清空: DELETE FROM embs + DELETE FROM kv WHERE k='model_fp'（对齐 Android clear() 语义）。
    public func clear() throws {
        try db.transaction {
            try db.run("DELETE FROM embs")
            try db.run("DELETE FROM kv WHERE k = 'model_fp'")
        }
    }
}
