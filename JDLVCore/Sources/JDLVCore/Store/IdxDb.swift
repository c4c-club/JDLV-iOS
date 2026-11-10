import Foundation

//
//  IdxDb —— 本地检索索引库（idx.db v3）。
//  对齐 Android app/src/main/java/com/jdlv/mobile/core/cache/IdxDb.kt
//  （提取对照: docs/_extract/06_store.md §1/§6/§9/§10, DDL/SQL/参数逐字）。
//
//  要点（全部照搬 Android）:
//  - 6 表 + 全部索引 DDL 逐字; 升级（含降级）= dropAll + onCreate 整库重建（纯缓存, 清空无损失）。
//  - WAL + synchronous=NORMAL（journal_mode 走 prepare/step, 对齐 Android rawQuery 教训）。
//  - upsert = UPDATE-then-INSERT「缺失字段保护」: 行里存在才写（null 也写 —— 远程 NULL 需落库）,
//    不存在的列不触碰, 保护详情行不把已索引行的 letter 冲成 NULL; 0 行才 INSERT OR IGNORE。
//  - countOf 1s TTL 缓存（白名单 5 张 idx_* 表）, 写操作一律 invalidate; 裁剪必须 countOfExact。
//  - 裁剪: countOfExact → boundary（删除前取 OFFSET 保留行）→ 执行 PruneSql 生成的语句
//    （TEMP _del_ids → 删主表 → 清理孤儿关系）→ PruneOutcome 三态。
//  - usageBytes = page_count×page_size + idx.db-wal 文件长度（UsageMath.total; 不计 -shm）。
//  - 读路径: 多词 AND 子串 LIKE（ESCAPE '\' 转义）; 排序白名单; limit 钳 1...500; 女优 ≤50 人。
//  - 读取侧列名归一: want AS want_watch_count / magnets AS magnets_count / letter AS number_letter
//    （UI 统一读远程口径, 对齐 ShadowDb.normMovie 原则）。
//
public final class IdxDb {

    public static let DB_NAME = "idx.db"
    public static let DB_VERSION = 3

    /// 写健康度打点（所有写入口 ok/fail; 连续失败 ≥5 回调 onFailure）
    public let stats = IdxWriteStats()

    /// internal: 测试（@testable）回填 updated_at / 检查 DDL 用
    let db: SQLite
    let directory: String

    // MARK: - init / 版本

    public init(directory: String) throws {
        self.directory = directory
        db = try SQLite(path: Self.filePath(in: directory), wal: true)
        let v = db.pragmaInt("user_version")
        if v == 0 {
            try createAll()                       // onCreate
        } else if v != Int64(Self.DB_VERSION) {
            try dropAll(); try createAll()        // onUpgrade/onDowngrade → 整库重建
        }
        db.setUserVersion(Self.DB_VERSION)
    }

    public static func filePath(in directory: String) -> String {
        directory.hasSuffix("/") ? directory + DB_NAME : directory + "/" + DB_NAME
    }

    public func close() { db.close() }

    // MARK: - DDL（逐字）

    private static let DDL: [String] = [
        // idx_movies
        "CREATE TABLE IF NOT EXISTS idx_movies(" +
            "id TEXT PRIMARY KEY, number TEXT, title TEXT, release_date TEXT, year TEXT," +
            "score REAL DEFAULT 0, want INTEGER DEFAULT 0, magnets INTEGER DEFAULT 0," +
            "letter TEXT, maker_id TEXT, series_id TEXT, director_id TEXT, publisher_id TEXT," +
            "updated_at INTEGER DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS i_m_rel ON idx_movies(release_date DESC, id DESC)",
        "CREATE INDEX IF NOT EXISTS i_m_num ON idx_movies(number)",
        "CREATE INDEX IF NOT EXISTS i_m_maker ON idx_movies(maker_id)",
        "CREATE INDEX IF NOT EXISTS i_m_series ON idx_movies(series_id)",
        "CREATE INDEX IF NOT EXISTS i_m_dir ON idx_movies(director_id)",
        "CREATE INDEX IF NOT EXISTS i_m_pub ON idx_movies(publisher_id)",
        "CREATE INDEX IF NOT EXISTS i_m_upd ON idx_movies(updated_at)",
        // idx_threads
        "CREATE TABLE IF NOT EXISTS idx_threads(" +
            "tid TEXT PRIMARY KEY, title TEXT, post_date TEXT, board TEXT, board_name TEXT," +
            "type TEXT, magnet_count INTEGER DEFAULT 0, words INTEGER DEFAULT 0," +
            "paywalled INTEGER DEFAULT 0, updated_at INTEGER DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS i_t_post ON idx_threads(post_date DESC, tid DESC)",
        "CREATE INDEX IF NOT EXISTS i_t_board ON idx_threads(board_name)",
        "CREATE INDEX IF NOT EXISTS i_t_upd ON idx_threads(updated_at)",
        // idx_actors
        "CREATE TABLE IF NOT EXISTS idx_actors(" +
            "id TEXT PRIMARY KEY, name TEXT, name_zht TEXT, avatar_url TEXT," +
            "videos_count INTEGER DEFAULT 0, gender INTEGER DEFAULT 0," +
            "popularity REAL DEFAULT 0, avg_score_all REAL DEFAULT 0, avg_score_solo REAL DEFAULT 0," +
            "debut TEXT, merged_into TEXT, updated_at INTEGER DEFAULT 0)",
        "CREATE INDEX IF NOT EXISTS i_a_vid ON idx_actors(videos_count DESC, id DESC)",
        "CREATE INDEX IF NOT EXISTS i_a_name ON idx_actors(name)",
        // idx_movie_actors
        "CREATE TABLE IF NOT EXISTS idx_movie_actors(" +
            "movie_id TEXT NOT NULL, actor_id TEXT NOT NULL," +
            "PRIMARY KEY(movie_id, actor_id))",
        "CREATE INDEX IF NOT EXISTS i_ma_actor ON idx_movie_actors(actor_id, movie_id)",
        // idx_movie_tags（WITHOUT ROWID 省体积; tag_name 不入库, 名称走 assets/tags_index.json）
        "CREATE TABLE IF NOT EXISTS idx_movie_tags(" +
            "movie_id TEXT NOT NULL, tag_id TEXT NOT NULL," +
            "PRIMARY KEY(movie_id, tag_id)) WITHOUT ROWID",
        "CREATE INDEX IF NOT EXISTS i_mt_tag ON idx_movie_tags(tag_id, movie_id)",
        // idx_meta
        "CREATE TABLE IF NOT EXISTS idx_meta(k TEXT PRIMARY KEY, v TEXT)",
    ]

    private static let ALL_TABLES = [
        "idx_movies", "idx_threads", "idx_actors",
        "idx_movie_actors", "idx_movie_tags", "idx_meta",
    ]

    private func createAll() throws {
        for sql in Self.DDL { try db.exec(sql) }
    }

    private func dropAll() throws {
        for t in Self.ALL_TABLES { try db.exec("DROP TABLE IF EXISTS \(t)") }
    }

    // MARK: - 写入（★ S13-P1: 缺失字段保护 UPDATE-then-INSERT）

    /// 行里存在才写（null 也写 —— 远程 NULL 需落库）; 不存在的列不触碰。
    /// 数值列做 Android 同款强转（Number→数值, 否则字符串解析, 兜底 0）; 其余列 toString（null → NULL）。
    private func putIf(_ cv: inout [(String, SQLValue)], _ r: Row, _ col: String, _ keys: String...) {
        for k in keys {
            guard let v = r[k] else { continue }   // 不存在的列不触碰
            let value: SQLValue
            switch col {
            case "score", "popularity", "avg_score_all", "avg_score_solo":
                value = .double(Self.toDouble(v))
            case "want", "magnets", "magnet_count", "words", "paywalled", "gender", "videos_count":
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

    /// Android cv.put(col, v?.toString()) 语义（null 已在 putIf 拦截, 这里必为有值）
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

    /// movieCv 列→键映射（逐字）。
    private func movieCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("id") ? "" : r.s("id")
        putIf(&cv, r, "number", "number")
        putIf(&cv, r, "title", "title")
        putIf(&cv, r, "release_date", "release_date")
        putIf(&cv, r, "year", "year")
        putIf(&cv, r, "score", "score")
        putIf(&cv, r, "want", "want_watch_count", "want")
        putIf(&cv, r, "magnets", "magnets_count", "magnets")
        putIf(&cv, r, "letter", "number_letter", "letter")
        putIf(&cv, r, "maker_id", "maker_id")
        putIf(&cv, r, "series_id", "series_id")
        putIf(&cv, r, "director_id", "director_id")
        putIf(&cv, r, "publisher_id", "publisher_id")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    private func threadCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("tid") ? "" : r.s("tid")
        putIf(&cv, r, "title", "title")
        putIf(&cv, r, "post_date", "post_date")
        putIf(&cv, r, "board", "board")
        putIf(&cv, r, "board_name", "board_name")
        putIf(&cv, r, "type", "type")
        putIf(&cv, r, "magnet_count", "magnet_count")
        putIf(&cv, r, "words", "article_words", "words")
        putIf(&cv, r, "paywalled", "paywalled")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    private func actorCv(_ r: Row, _ now: Int64) -> (cv: [(String, SQLValue)], id: String) {
        var cv: [(String, SQLValue)] = []
        let id = r.isNull("id") ? "" : r.s("id")
        putIf(&cv, r, "name", "name")
        putIf(&cv, r, "name_zht", "name_zht")
        putIf(&cv, r, "avatar_url", "avatar_url")
        putIf(&cv, r, "videos_count", "videos_count")
        putIf(&cv, r, "gender", "gender")
        putIf(&cv, r, "popularity", "popularity")
        putIf(&cv, r, "avg_score_all", "avg_score_all")
        putIf(&cv, r, "avg_score_solo", "avg_score_solo")
        putIf(&cv, r, "debut", "debut")
        putIf(&cv, r, "merged_into", "merged_into")
        cv.append(("updated_at", .int(now)))
        return (cv, id)
    }

    /// UPDATE-then-INSERT: 先 UPDATE 只修行里存在的列; 0 行才 INSERT OR IGNORE（缺失列落默认值）。
    private func upsert(
        table: String, pk: String, rows: [Row],
        cvOf: (Row, Int64) -> ([(String, SQLValue)], String), op: String
    ) {
        let now = Self.nowMs()
        do {
            try db.transaction {
                for r in rows {
                    let (cv, id) = cvOf(r, now)
                    if id.isEmpty { continue }
                    let setClause = cv.map { "\($0.0) = ?" }.joined(separator: ", ")
                    var params: [SQLValue?] = cv.map { $0.1 }
                    params.append(.string(id))
                    let upd = try db.run("UPDATE \(table) SET \(setClause) WHERE \(pk) = ?", params)
                    if upd == 0 {
                        let cols = cv.map { $0.0 }.joined(separator: ", ")
                        let ph = Array(repeating: "?", count: cv.count + 1).joined(separator: ", ")
                        var insertParams: [SQLValue?] = [.string(id)]
                        insertParams.append(contentsOf: cv.map { $0.1 })
                        try db.run(
                            "INSERT OR IGNORE INTO \(table)(\(pk), \(cols)) VALUES(\(ph))",
                            insertParams)
                    }
                }
            }
            stats.ok()
        } catch {
            _ = stats.fail(op: op, error: error)
        }
        invalidateCountCache()
    }

    /// 批量 upsert 影片（供预热/被动落盘; 整个列表一次事务）。
    public func upsertMovies(_ rows: [Row]) {
        upsert(table: "idx_movies", pk: "id", rows: rows,
               cvOf: movieCv, op: "idx.upsertMovies")
    }

    public func upsertThreads(_ rows: [Row]) {
        upsert(table: "idx_threads", pk: "tid", rows: rows,
               cvOf: threadCv, op: "idx.upsertThreads")
    }

    public func upsertActors(_ rows: [Row]) {
        upsert(table: "idx_actors", pk: "id", rows: rows,
               cvOf: actorCv, op: "idx.upsertActors")
    }

    // MARK: 关系表

    /// INSERT OR IGNORE INTO idx_movie_actors（批量预热; 增量, 不删）。
    public func upsertLinks(_ pairs: [(movieId: String, actorId: String)]) {
        do {
            try db.transaction {
                for p in pairs {
                    if p.movieId.isEmpty || p.actorId.isEmpty { continue }
                    try db.run(
                        "INSERT OR IGNORE INTO idx_movie_actors(movie_id, actor_id) VALUES(?, ?)",
                        [.string(p.movieId), .string(p.actorId)])
                }
            }
            stats.ok()
        } catch {
            _ = stats.fail(op: "idx.upsertLinks", error: error)
        }
        invalidateCountCache()
    }

    /// INSERT OR IGNORE INTO idx_movie_tags（批量预热; 增量, 不删）。
    public func upsertTags(_ pairs: [(movieId: String, tagId: String)]) {
        do {
            try db.transaction {
                for p in pairs {
                    if p.movieId.isEmpty || p.tagId.isEmpty { continue }
                    try db.run(
                        "INSERT OR IGNORE INTO idx_movie_tags(movie_id, tag_id) VALUES(?, ?)",
                        [.string(p.movieId), .string(p.tagId)])
                }
            }
            stats.ok()
        } catch {
            _ = stats.fail(op: "idx.upsertTags", error: error)
        }
        invalidateCountCache()
    }

    /// ★ S15-10: 详情链路的关系「替换」语义（先删该片旧关系再批量插入）。
    /// 只在详情查询成功时由 Indexer 调用; 批量预热仍用 upsert（增量, 不删）。
    public func replaceMovieActors(movieId: String, actorIds: [String]) {
        replaceRelations(table: "idx_movie_actors", col: "actor_id",
                         movieId: movieId, ids: actorIds, op: "idx.replaceMovieActors")
    }

    public func replaceMovieTags(movieId: String, tagIds: [String]) {
        replaceRelations(table: "idx_movie_tags", col: "tag_id",
                         movieId: movieId, ids: tagIds, op: "idx.replaceMovieTags")
    }

    private func replaceRelations(table: String, col: String, movieId: String, ids: [String], op: String) {
        guard !movieId.isEmpty else { return }
        do {
            try db.transaction {
                try db.run("DELETE FROM \(table) WHERE movie_id = ?", [.string(movieId)])
                for id in ids where !id.isEmpty {
                    try db.run("INSERT OR IGNORE INTO \(table)(movie_id, \(col)) VALUES(?, ?)",
                               [.string(movieId), .string(id)])
                }
            }
            stats.ok()
        } catch {
            _ = stats.fail(op: op, error: error)
        }
        invalidateCountCache()
    }

    // MARK: - countOf TTL 缓存（★ S15-17）

    private var countCache: [String: (ts: Int64, v: Int64)] = [:]
    private let countLock = NSLock()

    public func invalidateCountCache() {
        countLock.lock(); defer { countLock.unlock() }
        countCache.removeAll()
    }

    private static let COUNT_TABLES: Set<String> = [
        "idx_movies", "idx_threads", "idx_actors", "idx_movie_actors", "idx_movie_tags",
    ]

    /// 1s TTL 缓存的表行数（仅认 5 张 idx_* 表, 其余 0）; 写操作一律 invalidate。
    public func countOf(table: String) throws -> Int64 {
        guard Self.COUNT_TABLES.contains(table) else { return 0 }
        let now = Self.nowMs()
        countLock.lock()
        if let (ts, v) = countCache[table], now - ts <= 1_000 {
            countLock.unlock()
            return v
        }
        countLock.unlock()
        let v = try countOfExact(table: table)
        countLock.lock()
        countCache[table] = (now, v)
        countLock.unlock()
        return v
    }

    /// 绕过 TTL 的精确 COUNT（裁剪/容量判断用 —— 缓存偏大会多删）。
    public func countOfExact(table: String) throws -> Int64 {
        guard Self.COUNT_TABLES.contains(table) else { return 0 }
        guard let v = try db.scalar("SELECT COUNT(*) FROM \(table)") else { return 0 }
        switch v {
        case .int(let x): return x
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    /// 女优总数（= countOf("idx_actors"), IdxSearchable 口径）
    public func countActors() throws -> Int64 {
        try countOf(table: "idx_actors")
    }

    /// 女优有效数（未被合并; 预热进度显示用; 不走缓存）。
    public func countActorsActive() throws -> Int64 {
        guard let v = try db.scalar(
            "SELECT COUNT(*) FROM idx_actors WHERE merged_into IS NULL OR merged_into = ''") else { return 0 }
        if case .int(let x) = v { return x }
        return 0
    }

    // MARK: - 裁剪（PruneSql + PruneOutcome, ★ S16-05/09）

    /// 裁剪 idx_movies 到 limit 行。失败（Failed）时事务已回滚, 调用方必须保持 done=0 并退避重试;
    /// Success 的 boundary 为保留窗口最旧行（游标必须重置到这里）; Noop 的 boundary 仅作只读参考。
    @discardableResult
    public func pruneMovies(limit: Int64) -> PruneOutcome {
        guard limit > 0 else { return .failed("limit<=0") }
        do {
            let c = try countOfExact(table: "idx_movies")
            if c <= limit {
                let b = try movieBoundary(offset: 0)   // 保留窗口最旧行 = 第 1 行
                return .noop(boundaryDate: b.0, boundaryId: b.1)
            }
            let offset = c - limit
            let b = try movieBoundary(offset: offset)  // boundary 在删除前取
            try db.transaction {
                for (sql, params) in PruneSql.movieStatements(offset) {
                    try db.run(sql, params)
                }
            }
            invalidateCountCache()
            stats.ok()
            return .success(deleted: offset, boundaryDate: b.0, boundaryId: b.1)
        } catch {
            invalidateCountCache()
            _ = stats.fail(op: "idx.pruneMovies", error: error)
            return .failed("\(error)")
        }
    }

    /// 裁剪 idx_threads 到 limit 行（同构; boundary 为 tid）。
    @discardableResult
    public func pruneThreads(limit: Int64) -> PruneOutcome {
        guard limit > 0 else { return .failed("limit<=0") }
        do {
            let c = try countOfExact(table: "idx_threads")
            if c <= limit {
                let b = try threadBoundary(offset: 0)
                return .noop(boundaryDate: nil, boundaryId: b)
            }
            let offset = c - limit
            let b = try threadBoundary(offset: offset)
            try db.transaction {
                for (sql, params) in PruneSql.threadStatements(offset) {
                    try db.run(sql, params)
                }
            }
            invalidateCountCache()
            stats.ok()
            return .success(deleted: offset, boundaryDate: nil, boundaryId: b)
        } catch {
            invalidateCountCache()
            _ = stats.fail(op: "idx.pruneThreads", error: error)
            return .failed("\(error)")
        }
    }

    /// PruneSql.MOVIE_BOUNDARY: OFFSET offset 处的第一条保留行（release_date, id）。
    private func movieBoundary(offset: Int64) throws -> (String?, String?) {
        let rows = try db.query(PruneSql.MOVIE_BOUNDARY, [SQLValue?.some(.string(String(offset)))])
        guard let r = rows.first else { return (nil, nil) }
        return (r.isNull("release_date") ? nil : r.s("release_date"),
                r.isNull("id") ? nil : r.s("id"))
    }

    /// PruneSql.THREAD_BOUNDARY: OFFSET offset 处的第一条保留 tid。
    private func threadBoundary(offset: Int64) throws -> String? {
        let rows = try db.query(PruneSql.THREAD_BOUNDARY, [SQLValue?.some(.string(String(offset)))])
        guard let r = rows.first else { return nil }
        return r.isNull("tid") ? nil : r.s("tid")
    }

    // MARK: - usageBytes（★ S16-12: 不漏算 idx.db-wal）

    /// fast=true 只读 page_count×page_size + WAL 文件长度（毫秒级, 预热循环可安全调用）;
    /// fast=false 才 wal_checkpoint(TRUNCATE) 后再统计。usageBytes = UsageMath.total(main, wal), 不计 -shm。
    public func usageBytes(fast: Bool = true) -> Int64 {
        if !fast { db.walCheckpointTruncate() }
        let pages = db.pragmaInt("page_count")
        let size = db.pragmaInt("page_size")
        let wal = storeFileSize(Self.filePath(in: directory) + "-wal")
        return UsageMath.total(pages * size, wal)
    }

    // MARK: - idx_meta / cursor

    public func metaGet(_ k: String) -> String? {
        guard let v = try? db.scalar("SELECT v FROM idx_meta WHERE k = ?", [.string(k)]) else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }

    public func metaPut(_ k: String, _ v: String) {
        try? db.run("INSERT OR REPLACE INTO idx_meta(k, v) VALUES(?, ?)", [.string(k), .string(v)])
    }

    public func metaGetLong(_ k: String, _ def: Int64 = 0) -> Int64 {
        guard let s = metaGet(k) else { return def }
        return Int64(s) ?? def
    }

    public func metaPutLong(_ k: String, _ v: Int64) {
        metaPut(k, String(v))
    }

    /// 清空预热 cursor（重建索引时）; 不动 movies_n/threads_n 等统计键。
    public func clearCursor() {
        let keys = ["m_phase", "m_date", "m_id", "m_done", "m_target", "m_head_ts",
                    "t_tid", "t_done", "t_target", "a_id", "a_done", "a_target", "links_done"]
        let ph = keys.map { _ in "?" }.joined(separator: ",")
        try? db.run("DELETE FROM idx_meta WHERE k IN (\(ph))", keys.map { SQLValue?.some(.string($0)) })
    }

    /// 清空全部 6 张表（重建索引用）。
    public func clearAll() {
        do {
            try db.transaction {
                for t in Self.ALL_TABLES { try db.run("DELETE FROM \(t)") }
            }
            stats.ok()
        } catch {
            _ = stats.fail(op: "idx.clearAll", error: error)
        }
        invalidateCountCache()
    }

    // MARK: - 孤儿

    /// 孤儿自检（只读统计; 对齐 Android orphanReport 三段 SQL 逐字）。
    public func orphanReport() -> (tagsOrphans: Int64, actorOrphans: Int64, moviesNoRelation: Int64) {
        func scalar64(_ sql: String) -> Int64 {
            guard let v = try? db.scalar(sql) else { return 0 }
            if case .int(let x) = v { return x }
            return 0
        }
        let tags = scalar64(
            "SELECT COUNT(*) FROM idx_movie_tags mt LEFT JOIN idx_movies m ON m.id = mt.movie_id WHERE m.id IS NULL")
        let actors = scalar64(
            "SELECT COUNT(*) FROM idx_movie_actors ma LEFT JOIN idx_movies m ON m.id = ma.movie_id WHERE m.id IS NULL")
        let noRel = scalar64(
            "SELECT COUNT(*) FROM idx_movies m WHERE NOT EXISTS (SELECT 1 FROM idx_movie_tags mt WHERE mt.movie_id = m.id) AND NOT EXISTS (SELECT 1 FROM idx_movie_actors ma WHERE ma.movie_id = m.id)")
        return (tags, actors, noRel)
    }

    /// 清孤儿关系（防御性 API; Android 只在 prune 的 TEMP 表路径顺带清理, 不提供独立入口 —— 刻意补充, 见报告）。
    public func clearOrphans() {
        do {
            try db.transaction {
                try db.run("DELETE FROM idx_movie_tags WHERE movie_id NOT IN (SELECT id FROM idx_movies)")
                try db.run("DELETE FROM idx_movie_actors WHERE movie_id NOT IN (SELECT id FROM idx_movies)")
            }
            stats.ok()
        } catch {
            _ = stats.fail(op: "idx.clearOrphans", error: error)
        }
        invalidateCountCache()
    }

    // MARK: - 检索（IdxSearchable 实现; SQL/口径对齐 docs/_extract/03_search_math.md §1.6）

    /// 影片列清单（读取侧列名归一: UI 统一读远程口径 —— want/magnets/letter 改名输出）
    private static let MOVIE_COLS =
        "id, number, title, release_date, year, score, " +
        "want AS want_watch_count, magnets AS magnets_count, letter AS number_letter, " +
        "maker_id, series_id, director_id, publisher_id, updated_at"

    /// 关键词 → 逻辑词列表（去空格/全角空格, 最多 8 个; 与 JdbSearch.words 同口径）
    static func words(_ q: String) -> [String] {
        let parts = q
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(parts.prefix(8))
    }

    /// LIKE 特殊字符转义（% _ \）, SQL 端配 ESCAPE '\'（与 LocalFilterSql.escLike 同序, 顺序不可换）。
    static func escLike(_ w: String) -> String {
        w.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// 本地索引是否就绪: countOf("idx_movies") >= 10000（≥1 万行才启用本地优先）。
    public func localReady() -> Bool {
        let n = (try? countOf(table: "idx_movies")) ?? 0
        return n >= 10_000
    }

    /// 影片检索: 多词 AND 子串; scope ∈ {title, number, all}（letter 同 number）。
    /// 本地 LIKE 子串检索无 5000 截断（精确全量）; limit 钳 1...500, offset ≥ 0。
    public func searchMovies(q: String, scope: String, per: Int, offset: Int) throws -> [Row] {
        let ws = Self.words(q)
        guard !ws.isEmpty else { return [] }
        let perC = min(max(per, 1), 500)
        let off = max(offset, 0)
        var params: [SQLValue?] = []
        let whereClause: String
        let orderBy: String
        switch scope {
        case "number", "letter":
            // 番号/字头: number 子串（i_m_num 前缀形态优化由 SQLite 决定; 本地全表 LIKE 可承受）
            whereClause = ws.map { _ in "number LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            ws.forEach { params.append(.string("%\(Self.escLike($0))%")) }
            orderBy = "ORDER BY number ASC, id ASC"
        case "all":
            whereClause = ws.map { _ in "(title LIKE ? ESCAPE '\\' OR number LIKE ? ESCAPE '\\')" }
                .joined(separator: " AND ")
            ws.forEach {
                params.append(.string("%\(Self.escLike($0))%"))
                params.append(.string("%\(Self.escLike($0))%"))
            }
            orderBy = "ORDER BY release_date DESC, id DESC"
        case "title":
            whereClause = ws.map { _ in "title LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            ws.forEach { params.append(.string("%\(Self.escLike($0))%")) }
            orderBy = "ORDER BY release_date DESC, id DESC"
        default:
            return []
        }
        params.append(.int(Int64(perC)))
        params.append(.int(Int64(off)))
        return try db.query(
            "SELECT \(Self.MOVIE_COLS) FROM idx_movies WHERE \(whereClause) \(orderBy) LIMIT ? OFFSET ?",
            params)
    }

    /// R4 P8：首页三段本地兜底（Android IdxDb.moviesBy 对位；任务 06 §17.7.2）。
    /// sort ∈ {release_date, want_watch_count, rank}（远程 Q.home 三段排序键同形；
    /// 本地无排名表 → rank 按 idx_movies.score 近似）；limit 钳 1...500；offset ≥ 0。
    public func moviesBy(sort: String, asc: Bool, limit: Int, offset: Int) throws -> [Row] {
        let perC = min(max(limit, 1), 500)
        let off = max(offset, 0)
        let dir = asc ? "ASC" : "DESC"
        let orderBy: String
        switch sort {
        case "release_date":
            orderBy = "ORDER BY release_date \(dir), id \(dir)"
        case "want_watch_count", "want":
            orderBy = "ORDER BY want \(dir), id \(dir)"
        case "rank", "score":
            orderBy = "ORDER BY score \(dir), id \(dir)"
        default:
            return []
        }
        return try db.query(
            "SELECT \(Self.MOVIE_COLS) FROM idx_movies \(orderBy) LIMIT ? OFFSET ?",
            [.int(Int64(perC)), .int(Int64(off))])
    }

    /// 检索计数（与 searchMovies 同口径）。
    public func countMovies(q: String, scope: String) throws -> Int64 {
        let ws = Self.words(q)
        guard !ws.isEmpty else { return 0 }
        var params: [SQLValue?] = []
        let whereClause: String
        switch scope {
        case "number", "letter":
            whereClause = ws.map { _ in "number LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            ws.forEach { params.append(.string("%\(Self.escLike($0))%")) }
        case "all":
            whereClause = ws.map { _ in "(title LIKE ? ESCAPE '\\' OR number LIKE ? ESCAPE '\\')" }
                .joined(separator: " AND ")
            ws.forEach {
                params.append(.string("%\(Self.escLike($0))%"))
                params.append(.string("%\(Self.escLike($0))%"))
            }
        case "title":
            whereClause = ws.map { _ in "title LIKE ? ESCAPE '\\'" }.joined(separator: " AND ")
            ws.forEach { params.append(.string("%\(Self.escLike($0))%")) }
        default:
            return 0
        }
        let v = try db.scalar("SELECT COUNT(*) FROM idx_movies WHERE \(whereClause)", params)
        if case .int(let x)? = v { return x }
        return 0
    }

    /// 匹配女优 id 子集: 名称/name_zht 子串, ≤50 人, 未被合并（merged_into IS NULL OR ''）。
    private func actorIdsFor(_ q: String) throws -> [String] {
        let p = "%\(Self.escLike(q.trimmingCharacters(in: .whitespacesAndNewlines)))%"
        let rows = try db.query(
            "SELECT id FROM idx_actors WHERE (name LIKE ? ESCAPE '\\' OR name_zht LIKE ? ESCAPE '\\') " +
            "AND (merged_into IS NULL OR merged_into = '') LIMIT 50",
            [.string(p), .string(p)])
        return rows.compactMap { r in r.isNull("id") ? nil : r.s("id") }
    }

    /// scope=actor 检索: 女优名子串 → 关系 → 影片按时间排序分页（子集, ≤50 人）。
    public func searchActorMovies(q: String, page: Int, per: Int) throws -> [Row] {
        let ids = try actorIdsFor(q)
        guard !ids.isEmpty else { return [] }
        let perC = min(max(per, 1), 500)
        let off = max((page - 1) * perC, 0)
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        var params: [SQLValue?] = ids.map { SQLValue?.some(.string($0)) }
        params.append(.int(Int64(perC)))
        params.append(.int(Int64(off)))
        return try db.query(
            "SELECT \(Self.MOVIE_COLS) FROM idx_movies WHERE id IN " +
            "(SELECT movie_id FROM idx_movie_actors WHERE actor_id IN (\(ph))) " +
            "ORDER BY release_date DESC, id DESC LIMIT ? OFFSET ?", params)
    }

    /// scope=actor 计数（COUNT 必须从 idx_movies 侧 JOIN, 关系表孤儿不计入; DISTINCT 防多命中女优重复计数）。
    public func countActorMovies(q: String) throws -> Int64 {
        let ids = try actorIdsFor(q)
        guard !ids.isEmpty else { return 0 }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let v = try db.scalar(
            "SELECT COUNT(DISTINCT m.id) FROM idx_movies m " +
            "JOIN idx_movie_actors ma ON ma.movie_id = m.id WHERE ma.actor_id IN (\(ph))",
            ids.map { SQLValue?.some(.string($0)) })
        if case .int(let x)? = v { return x }
        return 0
    }

    /// 按标签分页取影片（i_mt_tag 索引; tag_id 由调用方经 JdbSearch.tagId 反查）。
    public func searchMoviesByTag(tagId: String, limit: Int, offset: Int) throws -> [Row] {
        let lim = min(max(limit, 1), 500)
        let off = max(offset, 0)
        return try db.query(
            "SELECT \(Self.MOVIE_COLS) FROM idx_movies WHERE id IN " +
            "(SELECT movie_id FROM idx_movie_tags WHERE tag_id = ?) " +
            "ORDER BY release_date DESC, id DESC LIMIT ? OFFSET ?",
            [.string(tagId), .int(Int64(lim)), .int(Int64(off))])
    }

    /// 标签计数（IdxCountSql.TAG_COUNT 逐字: JOIN idx_movies, 孤儿关系不计入）。
    public func countMoviesByTag(tagId: String) throws -> Int64 {
        let v = try db.scalar(IdxCountSql.TAG_COUNT, [tagId])
        if case .int(let x)? = v { return x }
        return 0
    }

    /// tid 直达单行（idx_threads 全字段行）。
    public func threadById(tid: String) throws -> Row? {
        try db.query("SELECT * FROM idx_threads WHERE tid = ?", [.string(tid)]).first
    }

    /// 帖子检索: 多词 AND 子串; board/board_name/type/磁力过滤在 SQL 内完成。
    public func searchThreads(q: String, board: String, boardName: String, type: String,
                              hasMagnet: Bool, limit: Int, offset: Int) throws -> [Row] {
        var clauses: [String] = []
        var params: [SQLValue?] = []
        for w in Self.words(q) {
            clauses.append("title LIKE ? ESCAPE '\\'")
            params.append(.string("%\(Self.escLike(w))%"))
        }
        if !board.isEmpty { clauses.append("board = ?"); params.append(.string(board)) }
        if !boardName.isEmpty { clauses.append("board_name = ?"); params.append(.string(boardName)) }
        if !type.isEmpty { clauses.append("type = ?"); params.append(.string(type)) }
        if hasMagnet { clauses.append("magnet_count > 0") }
        let lim = min(max(limit, 1), 500)
        let off = max(offset, 0)
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        params.append(.int(Int64(lim)))
        params.append(.int(Int64(off)))
        return try db.query(
            "SELECT * FROM idx_threads \(whereClause) " +
            "ORDER BY post_date DESC, tid DESC LIMIT ? OFFSET ?", params)
    }

    /// 帖子按排序键取页: sort ∈ {post_date, tid}（白名单外回退 post_date）; asc 生效。
    public func threadsBy(sort: String, asc: Bool, limit: Int, offset: Int) throws -> [Row] {
        let col = (sort == "tid") ? "tid" : "post_date"
        let dir = asc ? "ASC" : "DESC"
        let lim = min(max(limit, 1), 500)
        let off = max(offset, 0)
        return try db.query(
            "SELECT * FROM idx_threads ORDER BY \(col) \(dir), tid \(dir) LIMIT ? OFFSET ?",
            [.int(Int64(lim)), .int(Int64(off))])
    }

    // MARK: - 工具

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

// MARK: - IdxSearchable 注入（JdbSearch.idx; nil 或 localReady()==false → 全走远程）

extension IdxDb: IdxSearchable {}
