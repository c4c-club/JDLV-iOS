import Foundation

//
//  ShadowDb —— 详情缓存 + 离线详情（shadow.db v6）。
//  对齐 Android app/src/main/java/com/jdlv/mobile/core/cache/ShadowDb.kt
//  （提取对照: docs/_extract/06_store.md §2, DDL/算法/参数逐字）。
//
//  要点:
//  - v6: FTS 写入停用（ShadowFts 已停用）→ iOS v6 只建 7 张数据表, 不建 FTS 虚表;
//    升级 DROP 名单仍含 movies_fts/threads_fts/fts_map（IF EXISTS, 兼容旧库升级路径）。
//  - WAL + synchronous=NORMAL（onConfigure 与 IdxDb 相同）。
//  - upsert = 全字段 CONFLICT_REPLACE（删+插, 无缺失字段保护 —— 与 IdxDb 双语义刻意不同）。
//  - LRU: movies_shadow / threads_shadow 各 ≤5000 行, 超限按 updated_at ASC 淘汰（精确回到 limit）;
//    被裁行的 magnets_local 不随之删除（无级联, 对齐 Android）。
//  - recent_queries 上限 12（ts DESC 保留）。
//  - usageBytes: 先 wal_checkpoint(TRUNCATE) 再 page_count×page_size（不含 WAL 文件长度/不记 -shm,
//    与 IdxDb 口径不同 —— 原样保留差异）。
//  - clear(): 清 5 张数据表; 不含 recent_queries / kv。
//  - 读取侧列名归一 normMovie: cover_url ← cover / want_watch_count ← want / magnets_count ← magnets。
//  - threadById 返回全字段行; magnets / ed2k / images / videos / blocks 以 JSON 字符串承载
//    （Swift Row 无列表值类型 —— 刻意差异, 见报告）。
//
public final class ShadowDb {

    public static let DB_NAME = "shadow.db"
    public static let DB_VERSION = 6

    /// internal: 测试（@testable）回填 updated_at 用
    let db: SQLite
    let directory: String

    public init(directory: String) throws {
        self.directory = directory
        db = try SQLite(path: Self.filePath(in: directory), wal: true)
        let v = db.pragmaInt("user_version")
        if v == 0 {
            try createAll()                       // onCreate
        } else if v != Int64(Self.DB_VERSION) {
            try dropAll(); try createAll()        // onUpgrade → 整库重建
        }
        db.setUserVersion(Self.DB_VERSION)
    }

    public static func filePath(in directory: String) -> String {
        directory.hasSuffix("/") ? directory + DB_NAME : directory + "/" + DB_NAME
    }

    public func close() { db.close() }

    // MARK: - DDL（逐字; v6 不再创建 FTS 虚表）

    private static let DDL: [String] = [
        "CREATE TABLE IF NOT EXISTS movies_shadow(" +
            "id TEXT PRIMARY KEY, number TEXT, title TEXT, number_letter TEXT," +
            "release_date TEXT, score REAL DEFAULT 0, want INTEGER DEFAULT 0," +
            "magnets INTEGER DEFAULT 0, cover TEXT, year TEXT, maker_id TEXT, maker_name TEXT," +
            "actors_json TEXT, tags_json TEXT, updated_at INTEGER DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_ms_release ON movies_shadow(release_date DESC)",
        "CREATE INDEX IF NOT EXISTS idx_ms_number ON movies_shadow(number)",
        "CREATE INDEX IF NOT EXISTS idx_ms_letter ON movies_shadow(number_letter)",
        "CREATE INDEX IF NOT EXISTS idx_ms_score ON movies_shadow(score DESC)",
        "CREATE INDEX IF NOT EXISTS idx_ms_want ON movies_shadow(want DESC)",

        "CREATE TABLE IF NOT EXISTS threads_shadow(" +
            "tid TEXT PRIMARY KEY, title TEXT, board TEXT, board_name TEXT, type TEXT," +
            "post_date TEXT, last_checked TEXT, magnet_count INTEGER DEFAULT 0," +
            "paywalled INTEGER DEFAULT 0, words INTEGER DEFAULT 0, cover TEXT," +
            "updated_at INTEGER DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_ts_post ON threads_shadow(post_date DESC, tid DESC)",
        "CREATE INDEX IF NOT EXISTS idx_ts_board ON threads_shadow(board_name)",
        "CREATE INDEX IF NOT EXISTS idx_ts_type ON threads_shadow(type)",

        "CREATE TABLE IF NOT EXISTS actors_shadow(" +
            "id TEXT PRIMARY KEY, name TEXT, name_zht TEXT, avatar_url TEXT," +
            "videos_count INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS idx_as_videos ON actors_shadow(videos_count DESC)",

        "CREATE TABLE IF NOT EXISTS articles_shadow(" +
            "id TEXT PRIMARY KEY, title TEXT, category_name TEXT, author_name TEXT," +
            "cover_url TEXT, released_at TEXT, word_count INTEGER DEFAULT 0," +
            "updated_at INTEGER DEFAULT 0)",

        "CREATE TABLE IF NOT EXISTS magnets_local(" +
            "movie_id TEXT DEFAULT '', tid TEXT DEFAULT '', hash TEXT, name TEXT," +
            "size TEXT, link TEXT)",
        "CREATE INDEX IF NOT EXISTS idx_ml_movie ON magnets_local(movie_id)",
        "CREATE INDEX IF NOT EXISTS idx_ml_tid ON magnets_local(tid)",

        "CREATE TABLE IF NOT EXISTS recent_queries(" +
            "q TEXT PRIMARY KEY, ts INTEGER DEFAULT 0)",

        "CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT)",
    ]

    /// 升级 DROP 名单（含已停用的 FTS 虚表名 —— IF EXISTS, iOS 新库本就没有, 保升级路径一致）
    private static let DROP_TABLES = [
        "movies_shadow", "threads_shadow", "actors_shadow", "articles_shadow",
        "magnets_local", "recent_queries", "kv", "fts_map", "movies_fts", "threads_fts",
    ]

    private static let COUNT_TABLES = [
        "movies_shadow", "threads_shadow", "actors_shadow", "articles_shadow",
        "magnets_local", "recent_queries", "kv",
    ]

    private func createAll() throws {
        for sql in Self.DDL { try db.exec(sql) }
    }

    private func dropAll() throws {
        for t in Self.DROP_TABLES { try db.exec("DROP TABLE IF EXISTS \(t)") }
    }

    // MARK: - 写入（全字段 CONFLICT_REPLACE, 无缺失字段保护）

    /// 行里存在才写（首个命中的键）; 数值列强转; null 也写。与 IdxDb.putIf 同构,
    /// 差别只在调用方是 INSERT OR REPLACE（整行替换）。
    private func putCol(_ cv: inout [(String, SQLValue)], _ r: Row, _ col: String, _ keys: String...) {
        for k in keys {
            guard let v = r[k] else { continue }
            let value: SQLValue
            switch col {
            case "score":
                value = .double(Self.toDouble(v))
            case "want", "magnets", "magnet_count", "words", "paywalled", "videos_count", "word_count":
                value = .int(Self.toLong(v))
            default:
                value = (v == .null) ? .null : .string(Self.toString(v))
            }
            cv.append((col, value))
            return
        }
    }

    private static func toDouble(_ v: SQLValue) -> Double {
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s) ?? 0.0
        default: return 0.0
        }
    }

    private static func toLong(_ v: SQLValue) -> Int64 {
        switch v {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    private static func toString(_ v: SQLValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .data(let d): return String(data: d, encoding: .utf8) ?? ""
        case .null: return ""
        }
    }

    private func insertReplace(table: String, pk: String, cv: [(String, SQLValue)], id: String) throws {
        let cols = ([pk] + cv.map { $0.0 }).joined(separator: ", ")
        let ph = Array(repeating: "?", count: cv.count + 1).joined(separator: ", ")
        var params: [SQLValue?] = [.string(id)]
        params.append(contentsOf: cv.map { $0.1 })
        try db.run("INSERT OR REPLACE INTO \(table)(\(cols)) VALUES(\(ph))", params)
    }

    private func movieCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("id") ? "" : r.s("id")
        putCol(&cv, r, "number", "number")
        putCol(&cv, r, "title", "title")
        putCol(&cv, r, "number_letter", "number_letter")
        putCol(&cv, r, "release_date", "release_date")
        putCol(&cv, r, "score", "score")
        putCol(&cv, r, "want", "want_watch_count", "want")
        putCol(&cv, r, "magnets", "magnets_count", "magnets")
        putCol(&cv, r, "cover", "cover_url", "cover")
        putCol(&cv, r, "year", "year")
        putCol(&cv, r, "maker_id", "maker_id")
        putCol(&cv, r, "maker_name", "maker_name")
        putCol(&cv, r, "actors_json", "actors_json")
        putCol(&cv, r, "tags_json", "tags_json")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    private func threadCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("tid") ? "" : r.s("tid")
        putCol(&cv, r, "title", "title")
        putCol(&cv, r, "board", "board")
        putCol(&cv, r, "board_name", "board_name")
        putCol(&cv, r, "type", "type")
        putCol(&cv, r, "post_date", "post_date")
        putCol(&cv, r, "last_checked", "last_checked")
        putCol(&cv, r, "magnet_count", "magnet_count")
        putCol(&cv, r, "paywalled", "paywalled")
        putCol(&cv, r, "words", "article_words", "words")
        putCol(&cv, r, "cover", "cover_url", "cover")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    private func actorCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("id") ? "" : r.s("id")
        putCol(&cv, r, "name", "name")
        putCol(&cv, r, "name_zht", "name_zht")
        putCol(&cv, r, "avatar_url", "avatar_url")
        putCol(&cv, r, "videos_count", "videos_count")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    private func articleCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("id") ? "" : r.s("id")
        putCol(&cv, r, "title", "title")
        putCol(&cv, r, "category_name", "category_name")
        putCol(&cv, r, "author_name", "author_name")
        putCol(&cv, r, "cover_url", "cover_url")
        putCol(&cv, r, "released_at", "released_at")
        putCol(&cv, r, "word_count", "word_count")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    private func replaceAll(table: String, pk: String, rows: [Row],
                            cvOf: (Row, Int64) -> ([(String, SQLValue)], String)) throws {
        let now = storeNowMs()
        try db.transaction {
            for r in rows {
                let (cv, id) = cvOf(r, now)
                if id.isEmpty { continue }
                try insertReplace(table: table, pk: pk, cv: cv, id: id)
            }
        }
    }

    public func upsertMovies(_ rows: [Row]) throws {
        try replaceAll(table: "movies_shadow", pk: "id", rows: rows, cvOf: movieCv)
    }

    public func upsertThreads(_ rows: [Row]) throws {
        try replaceAll(table: "threads_shadow", pk: "tid", rows: rows, cvOf: threadCv)
    }

    public func upsertActors(_ rows: [Row]) throws {
        try replaceAll(table: "actors_shadow", pk: "id", rows: rows, cvOf: actorCv)
    }

    public func upsertArticles(_ rows: [Row]) throws {
        try replaceAll(table: "articles_shadow", pk: "id", rows: rows, cvOf: articleCv)
    }

    // MARK: 详情落盘（幂等; magnets_local 先删后插）

    /// upsertMovieDetail: 基础行 REPLACE + actors/tags 序列化进 actors_json/tags_json +
    /// 事务内 DELETE magnets_local WHERE movie_id=? 再逐条 INSERT（link = 远程原值兜底拼 hash）。
    /// 尾部 LRU 5000+5000（对齐 Indexer.upsertMovieDetail → ShadowDb.prune(5000, 5000)）。
    public func upsertMovieDetail(
        _ row: Row, tags: [Row], actors: [Row], magnets: [Row]
    ) throws {
        var base = row
        if !actors.isEmpty { base["actors_json"] = .string(Self.jsonOfRows(actors)) }
        if !tags.isEmpty { base["tags_json"] = .string(Self.jsonOfRows(tags)) }
        let mid = base.isNull("id") ? "" : base.s("id")
        try replaceAll(table: "movies_shadow", pk: "id", rows: [base], cvOf: movieCv)
        if !mid.isEmpty {
            try db.transaction {
                try db.run("DELETE FROM magnets_local WHERE movie_id = ?", [.string(mid)])
                for m in magnets {
                    let hash = m.s("hash")
                    let link = m.s("link").isEmpty ? "magnet:?xt=urn:btih:\(hash)" : m.s("link")
                    try db.run(
                        "INSERT INTO magnets_local(movie_id, tid, hash, name, size, link) VALUES(?, ?, ?, ?, ?, ?)",
                        [.string(mid), .string(""), .string(hash),
                         .string(m.s("name")), .string(m.s("size")), .string(link)])
                }
            }
        }
        prune()
    }

    public func upsertThreadDetail(_ row: Row, magnets: [Row]) throws {
        let tid = row.isNull("tid") ? "" : row.s("tid")
        try replaceAll(table: "threads_shadow", pk: "tid", rows: [row], cvOf: threadCv)
        if !tid.isEmpty {
            try db.transaction {
                try db.run("DELETE FROM magnets_local WHERE tid = ?", [.string(tid)])
                for m in magnets {
                    let hash = m.s("hash")
                    let link = m.s("link").isEmpty ? "magnet:?xt=urn:btih:\(hash)" : m.s("link")
                    try db.run(
                        "INSERT INTO magnets_local(movie_id, tid, hash, name, size, link) VALUES(?, ?, ?, ?, ?, ?)",
                        [.string(""), .string(tid), .string(hash),
                         .string(m.s("name")), .string(m.s("size")), .string(link)])
                }
            }
        }
        prune()
    }

    // MARK: - 读取

    /// ★ P3.5 读取侧列名归一（不迁移旧库）: 缺远程列名时用影子列名补齐（不覆盖已有值）。
    static func normMovie(_ m: inout Row) {
        if m["cover_url"] == nil || m["cover_url"] == .null { m["cover_url"] = m["cover"] }
        if m["want_watch_count"] == nil || m["want_watch_count"] == .null {
            m["want_watch_count"] = m["want"]
        }
        if m["magnets_count"] == nil || m["magnets_count"] == .null {
            m["magnets_count"] = m["magnets"]
        }
        // maker_name/year/score/number_letter 影子列名与远程一致, 原样保留
    }

    static func jsonOfRows(_ rows: [Row]) -> String {
        let arr: [[String: Any]] = rows.map { r in
            var dict: [String: Any] = [:]
            for k in r.keys {
                switch r[k] {
                case .string(let s): dict[k] = s
                case .int(let i): dict[k] = i
                case .double(let d): dict[k] = d
                case .bool(let b): dict[k] = b
                default: break
                }
            }
            return dict
        }
        guard let d = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    static func magnetsJson(_ rows: [Row]) -> String {
        let arr: [[String: String]] = rows.map { r in
            ["movie_id": r.s("movie_id"), "tid": r.s("tid"), "hash": r.s("hash"),
             "name": r.s("name"), "size": r.s("size"), "link": r.s("link")]
        }
        guard let d = try? JSONSerialization.data(withJSONObject: arr),
              let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }

    /// 单片详情（含 magnets_local 回读 + 列名归一; magnets 为 JSON 字符串）。
    public func movieById(_ id: String) throws -> Row? {
        guard var r = try db.query("SELECT * FROM movies_shadow WHERE id = ?", [.string(id)]).first else {
            return nil
        }
        Self.normMovie(&r)
        let magnets = try db.query("SELECT * FROM magnets_local WHERE movie_id = ?", [.string(id)])
        r["magnets"] = .string(Self.magnetsJson(magnets))
        return r
    }

    /// 单帖详情（全字段行 + magnets 回读 + ed2k/images/videos/blocks 补空 —— 对齐 Android threadById）。
    public func threadById(tid: String) throws -> Row? {
        guard var r = try db.query("SELECT * FROM threads_shadow WHERE tid = ?", [.string(tid)]).first else {
            return nil
        }
        let magnets = try db.query("SELECT * FROM magnets_local WHERE tid = ?", [.string(tid)])
        r["magnets"] = .string(Self.magnetsJson(magnets))
        r["ed2k"] = .string("[]")
        r["images"] = .string("[]")
        r["videos"] = .string("[]")
        r["blocks"] = .string("[]")
        return r
    }

    public func count(_ table: String) throws -> Int64 {
        guard Self.COUNT_TABLES.contains(table) else { return 0 }
        guard let v = try db.scalar("SELECT COUNT(*) FROM \(table)") else { return 0 }
        if case .int(let x) = v { return x }
        return 0
    }

    // MARK: - LRU 裁剪（逐字; Indexer 详情落盘尾部调用 prune(5000, 5000)）

    /// 超过 limit 按 updated_at 升序删（精确回到 limit）; 无关系表孤儿问题（magnets_local 无级联删除）。
    public func prune(_ moviesLimit: Int64 = 5000, _ threadsLimit: Int64 = 5000) {
        try? db.transaction {
            let mc = try count("movies_shadow")
            if mc > moviesLimit && moviesLimit > 0 {
                try db.run(
                    "DELETE FROM movies_shadow WHERE id IN " +
                    "(SELECT id FROM movies_shadow ORDER BY updated_at ASC LIMIT ?)",
                    [.int(mc - moviesLimit)])
            }
            let tc = try count("threads_shadow")
            if tc > threadsLimit && threadsLimit > 0 {
                try db.run(
                    "DELETE FROM threads_shadow WHERE tid IN " +
                    "(SELECT tid FROM threads_shadow ORDER BY updated_at ASC LIMIT ?)",
                    [.int(tc - threadsLimit)])
            }
        }
    }

    // MARK: - recent_queries（搜索历史, 上限 12）

    public func addRecentQuery(_ q: String) throws {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        try db.run("INSERT OR REPLACE INTO recent_queries(q, ts) VALUES(?, ?)",
                   [.string(t), .int(storeNowMs())])
        try db.run("DELETE FROM recent_queries WHERE q IN " +
                   "(SELECT q FROM recent_queries ORDER BY ts DESC LIMIT -1 OFFSET 12)")
    }

    public func recentQueries() throws -> [String] {
        try db.query("SELECT q FROM recent_queries ORDER BY ts DESC LIMIT 12", [])
            .compactMap { r in r.isNull("q") ? nil : r.s("q") }
    }

    // MARK: - kv

    public func kvGet(_ k: String) throws -> String? {
        guard let v = try db.scalar("SELECT v FROM kv WHERE k = ?", [.string(k)]) else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }

    public func kvSet(_ k: String, _ v: String) throws {
        try db.run("INSERT OR REPLACE INTO kv(k, v) VALUES(?, ?)", [.string(k), .string(v)])
    }

    // MARK: - 容量 / 清理

    /// 先 wal_checkpoint(TRUNCATE)（WAL 归零）再 page_count×page_size; 不加 WAL 长度、不计 -shm
    /// （与 IdxDb.usageBytes(fast=true) 的"主文件+WAL"口径不同, 原样保留）。
    public func usageBytes() -> Int64 {
        db.walCheckpointTruncate()
        return db.pragmaInt("page_count") * db.pragmaInt("page_size")
    }

    /// 清数据表; 注意: 不含 recent_queries / kv（对齐 Android）。
    /// Android 还会清 movies_fts/threads_fts —— iOS v6 无 FTS 表, 无需清理（刻意差异）。
    public func clear() throws {
        try db.transaction {
            for t in ["movies_shadow", "threads_shadow", "actors_shadow", "articles_shadow", "magnets_local"] {
                try db.run("DELETE FROM \(t)")
            }
        }
    }
}

// MARK: - ShtShadowLike 注入（ShtSearch.shadow; nil → 跳过影子路）

extension ShadowDb: ShtShadowLike {}
