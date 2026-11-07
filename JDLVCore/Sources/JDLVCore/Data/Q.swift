import Foundation

// Q 查询层（对齐 Android data/Q.kt 逐函数移植）。
//
// - SQL 全部与提取材料 docs/_extract/02_q_db.md 逐字一致（含空格、反引号 rank、
//   INDEX hint 注释、OFFSET 5000 钳制、派生窗口 20000/5000）；每个函数头部标注
//   SqlPolicy 模板 id。
// - 行取值：Row.s/i/l/d/b（Row.swift，与 Android JRow 扩展 1:1）；参数一律 SQLValue。
// - 返回值：Android Map<String, Any?> → Swift [String: Any]，键名与 Android 逐字一致；
//   Android 值为 null 的键（如 browse 的 anchor）存 NSNull()；携带嵌套结构的详情行
//   （movie/shtThread/actor 的 actor 键）基行经 jrow() 摊平为 [String: Any]（Row 的
//   SQLValue 容器装不下嵌套列表，且不可改 Row.swift）。
// - 离线本地索引路径（IdxDb/ShadowDb/Indexer）为 P5 接线点：当前本地索引恒为空，
//   行为与 Android "本地库为空" 分支完全一致（返回 nil/0/空集或抛出同文案错误），
//   每个接线点均以 TODO(P5) 标注。
// - search/searchCount/shtBrowse/shtBrowseCount/shtSemantic 的搜索委托调用集中在
//   文件末尾 extension Q（与并行移植的 JdbSearch/ShtSearch 解耦）。

/// Android RuntimeException 对位（Q 层明确抛出的业务错误）。
public struct QRuntimeError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum Q {

    // MARK: - B.0 常量

    /// ★ S2: 改 public —— core/search/JdbSearch 复用同一列清单（Android private，此处 internal）
    static let CARD_BASE = [
        "id", "number", "title", "release_date", "score",
        "duration", "magnets_count", "want_watch_count", "cover_url",
    ]
    static let CARD_OPT = ["year", "number_letter", "has_cnsub"]

    struct SortDef {
        let col: String
        let keys: [String]
        let needsDerived: Bool
        let note: String?
    }

    /// 排序白名单（movies 无 updated_at/fetch_time 类列 → "更新时间"排序用 m.id 作收录顺序代理）
    private static let SORT_COLS: [String: SortDef] = [
        "release_date": SortDef(col: "release_date", keys: ["release_date"], needsDerived: false, note: nil),
        "id": SortDef(col: "id", keys: ["id"], needsDerived: false, note: nil),
        "score": SortDef(
            col: "score", keys: ["score", "reviews_count"], needsDerived: true,
            note: "已限定最近 5000 部内按评分排序"),
        "want_watch_count": SortDef(
            col: "want_watch_count", keys: ["want_watch_count"], needsDerived: false, note: nil),
    ]

    /// 排序 UI 允许的 key（VM/页面共用同一白名单）
    public static let BROWSE_SORT_KEYS = ["release_date", "id", "score", "want_watch_count"]

    // MARK: - 内部助手

    /// Perf.mark 对位（Android core/net/Perf；Core 尚无 Perf 模块，App 接线后替换）。
    static func perfMark(_ tag: String, _ note: String) {
        // TODO(P6/App): Perf 接线（tag/note 已与 Android 逐字一致）
    }

    /// Row → [String: Any]（Android JRow 语义；null → NSNull）。
    static func jrow(_ r: Row) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in r.map { out[k] = anyOf(v) }
        return out
    }

    /// SQLValue → Any（null → NSNull）。
    static func anyOf(_ v: SQLValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(let d): return d
        case .bool(let b): return b
        }
    }

    static func anyOf(_ r: Row, _ k: String) -> Any {
        if let v = r.map[k] { return anyOf(v) }
        return NSNull()
    }

    /// Android `it[k]?.toString()`（null/缺列 → nil，mapNotNull 丢弃）。
    static func rowToString(_ r: Row, _ k: String) -> String? {
        guard let v = r.map[k], v != .null else { return nil }
        return r.s(k)
    }

    /// [String: Any] 行的 JRow.s 语义（null/缺列 → ""）。
    static func js(_ d: [String: Any], _ k: String) -> String {
        switch d[k] {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int64: return String(i)
        case let i as Int: return String(i)
        case let d2 as Double: return String(d2)
        case let dat as Data: return String(data: dat, encoding: .utf8) ?? ""
        default: return ""
        }
    }

    /// [String: Any] 行的 JRow.l 语义（Number 优先，否则字符串解析，兜底 0）。
    static func jl(_ d: [String: Any], _ k: String) -> Int64 {
        switch d[k] {
        case let b as Bool: return b ? 1 : 0
        case let i as Int64: return i
        case let i as Int: return Int64(i)
        case let d2 as Double: return Int64(d2)
        case let s as String: return Int64(s) ?? 0
        default: return 0
        }
    }

    /// [String] → [SQLValue?]（参数便捷）。
    static func strs(_ a: [String]) -> [SQLValue?] { a.map { SQLValue.string($0) as SQLValue? } }

    /// Kotlin padStart(2, '0')。
    static func padStart2(_ s: String) -> String {
        s.count >= 2 ? s : String(repeating: "0", count: 2 - s.count) + s
    }

    /// Kotlin substringAfter('.')（分隔符缺失 → 原串）。
    static func substringAfterDot(_ s: String) -> String {
        if let i = s.firstIndex(of: ".") {
            return String(s[s.index(after: i)...])
        }
        return s
    }

    // MARK: - B.1 movieCols〔公开〕
    // 本身不发查询；Db.cols("jdb","movies") → 模板 admin.columns(probe)。

    /// ★ S2: 改 public —— core/search/JdbSearch 复用同一列清单
    public static func movieCols(prefix: String = "m") async -> String {
        let have = await Db.cols("jdb", "movies")
        let cols = CARD_BASE.filter { have.contains($0) }.map { "\(prefix).\($0)" }
            + CARD_OPT.filter { have.contains($0) }.map { "\(prefix).\($0)" }
        if !cols.isEmpty { return cols.joined(separator: ", ") }
        // 列探测为空（失败/无表）→ 兜底列清单（无 duration）。
        // 保留 Android joinToString("")+dropLast(2) 的 quirk 产物（m.id, m.number, ...）。
        return String(
            ["id", "number", "title", "release_date", "score",
             "magnets_count", "want_watch_count", "cover_url"]
                .map { "\(prefix).\($0), " }.joined().dropLast(2))
    }

    // MARK: - B.4 movieCovers〔公开〕（jdb）
    // 模板 id：jdb.movie.covers(pk)。PK IN 批量取封面（影子库结果在线回填），500/批。

    public static func movieCovers(ids: [String]) async -> [String: String] {
        var clean: [String] = []
        var seen = Set<String>()
        for id in ids {
            if !id.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert(id).inserted {
                clean.append(id)
            }
        }
        var out: [String: String] = [:]
        var i = 0
        while i < clean.count {
            let chunk = Array(clean[i..<min(i + 500, clean.count)])
            let ph = chunk.map { _ in "?" }.joined(separator: ",")
            do {
                let rows = try await Db.query(
                    "jdb", "SELECT id, cover_url FROM movies WHERE id IN (\(ph))", strs(chunk))
                for r in rows {
                    let u = r.s("cover_url")
                    if !u.isEmpty { out[r.s("id")] = u }   // 仅当 cover_url 非空
                }
            } catch {
                // 单批失败跳过，不阻塞其余批次
            }
            i += 500
        }
        return out
    }

    // MARK: - B.5 movieDetailCols〔私有〕（jdb）
    // 模板 id：admin.columns(probe)。

    static func movieDetailCols() async -> String {
        let all = [
            "id", "number", "origin_title", "title", "release_date", "year",
            "duration", "score", "reviews_count", "comments_count", "want_watch_count",
            "watched_count", "magnets_count", "has_cnsub", "can_play", "maker_id",
            "maker_name", "director_id", "director_name", "publisher_id",
            "publisher_name", "series_id", "series_name", "cover_url", "thumb_url",
            "summary", "detail_fetched", "images_downloaded",
        ]
        let have = await Db.cols("jdb", "movies")
        if have.isEmpty { return all.joined(separator: ", ") }
        return all.filter { have.contains($0) }.joined(separator: ", ")
    }

    // MARK: - B.6 home〔公开〕（jdb）
    // 模板 id：jdb.home.recent2 / jdb.home.hot2 / jdb.home.top2（S12-P4 参数化版）。

    public static func home(per: Int = 24) async throws -> [String: Any] {
        let eff = (12...36).contains(per) ? per : 24
        let note = "本地缓存 · 可能过期"

        func localFallback(mark: Bool) throws -> [String: Any] {
            if mark { Db.markOffline("jdb") }
            // 本地兜底走 IdxDb 键索引（★ S12-P4 列表页不写 shadow.db）
            let r = localHomeSeg("release_date", eff)   // TODO(P5): IdxDb.moviesBy("release_date", false, eff, 0)
            let h = localHomeSeg("want", eff)           // TODO(P5): IdxDb.moviesBy("want", false, eff, 0)
            let t = localHomeSeg("score", eff)          // TODO(P5): IdxDb.moviesBy("score", false, eff, 0)
            if r.isEmpty && h.isEmpty && t.isEmpty {
                // ★ S11-P0: 影子库空 ≠ 远程不可达 —— 文案必须说真话 (铁律 22)
                throw QRuntimeError("首页三个分段查询均失败, 且本地索引为空 (下拉重试)")
            }
            return ["recent": r, "hot": h, "top": t, "derived": note]
        }

        // 分库判定只看 Db.offlineJdb（★ S11-P0 铁律 25：offlineAll 会被 sht 抖动误伤）
        if Db.offlineJdb {
            // 离线：先探活 → 通则清标记重试远程一次；仍失败 → 本地兜底
            if await Db.check("jdb") {
                Db.clearOffline("jdb")
                do {
                    if let r = try await homeRemote(eff) {
                        // TODO(P5): Indexer.upsertMoviesAsync(r 三段)
                        return r
                    }
                } catch { /* 仍失败 → 本地兜底 */ }
                return try localFallback(mark: false)
            }
            return try localFallback(mark: false)
        }

        do {
            if let r = try await homeRemote(eff) {
                // TODO(P5): Indexer.upsertMoviesAsync(r 三段)
                return r
            }
        } catch {
            perfMark("db.err", String(ErrText.of(error).prefix(80)))
            if await Db.check("jdb") {
                Db.clearOffline("jdb")
                throw error   // 通 → rethrow（UI 错误态+重试，不静默退影子）
            }
            Db.markOffline("jdb")
            return try localFallback(mark: true)
        }
        // null（三段全空且无异常 = 空库）→ 本地兜底
        return try localFallback(mark: false)
    }

    /// Android localFallback 的 IdxDb 三段读取对位（P5 前恒空 → 空库语义）。
    private static func localHomeSeg(_ key: String, _ eff: Int) -> [Row] {
        []   // TODO(P5): IdxDb.moviesBy(key, false, eff, 0)
    }

    /// homeRemote〔私有〕：三段并行；每段异常被收集不吞（★ S14-P3 B13）。
    /// 三段全空：抛第一个真实异常；确实全空无异常 → nil（空库）。
    static func homeRemote(_ per: Int) async throws -> [String: Any]? {
        func seg(_ sql: String, _ args: [SQLValue?]) async -> ([Row], Error?) {
            do { return (try await Db.query("jdb", sql, args), nil) }
            catch { return ([], error) }
        }
        // Android 三段各自调 movieCols()（Db.cols 有缓存 → 同一列清单），此处预取一次等价
        let cols = await movieCols()
        async let recent = seg(
            "SELECT \(cols) FROM movies m ORDER BY release_date DESC LIMIT ?",
            [.int(Int64(per))])
        async let hot = seg(
            "SELECT \(cols) FROM movies m ORDER BY want_watch_count DESC LIMIT ?",
            [.int(Int64(per))])
        // ★ P7: rank 是 MySQL 8 保留字, 全部反引号 (旧 SQL 1064 语法错误)
        async let top = seg(
            "SELECT \(cols), r.`rank` FROM rankings_top250 r JOIN movies m ON m.id = r.movie_id ORDER BY r.`rank` LIMIT ?",
            [.int(Int64(per))])
        let (r, e1) = await recent
        let (h, e2) = await hot
        let (t, e3) = await top
        if r.isEmpty && h.isEmpty && t.isEmpty {
            if let e = e1 ?? e2 ?? e3 { throw e }
            return nil
        }
        return ["recent": r, "hot": h, "top": t]
    }

    // MARK: - B.7 top250〔公开〕（jdb）
    // 模板 id：jdb.top250.page / jdb.top250.count(small)。OFFSET 无上限钳制。

    public static func top250(year: String? = nil, page: Int = 1, per: Int = 40) async throws -> [String: Any] {
        let w = (year?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? "" : " WHERE m.year = ?"
        let cols = await movieCols()
        let listSql = "SELECT \(cols), r.`rank` FROM rankings_top250 r JOIN movies m ON m.id = r.movie_id" +
            "\(w) ORDER BY r.`rank` LIMIT ? OFFSET ?"
        let off = (page - 1) * per
        let args: [SQLValue?] = w.isEmpty
            ? [.int(Int64(per)), .int(Int64(off))]
            : [.string(year!), .int(Int64(per)), .int(Int64(off))]
        let rows = try await Db.query("jdb", listSql, args)
        // COUNT 同步前置
        let cnt = try await Db.scalar(
            "jdb",
            "SELECT COUNT(*) c FROM rankings_top250 r JOIN movies m ON m.id = r.movie_id\(w)",
            w.isEmpty ? [] : [.string(year!)])
        return [
            "items": rows, "total": cnt, "page": page, "per": per,
            "year": year ?? "",
        ]
    }

    // MARK: - B.8 top250Years〔公开〕（jdb）
    // 模板 id：jdb.top250.years(small)。全量年份分布，无分页。

    public static func top250Years() async -> [Row] {
        do {
            return try await Db.query(
                "jdb",
                "SELECT m.year, COUNT(*) c FROM rankings_top250 r JOIN movies m ON m.id = r.movie_id " +
                    "GROUP BY m.year ORDER BY m.year DESC")
        } catch { return [] }
    }

    // MARK: - B.11 whereOf〔私有〕（jdb）
    // 返回 (WHERE 串, 参数, 派生窗口行数?)；WHERE 串带前导空格（" WHERE "）或空串。

    static func whereOf(_ f: Filters) async -> (String, [SQLValue?], Int?) {
        let have = await Db.cols("jdb", "movies")
        var clauses: [String] = []
        var params: [SQLValue?] = []
        var derivedWindow: Int? = nil

        if !f.year.isEmpty && have.contains("year") {
            if !f.month.isEmpty {
                // 年+月 → [yyyy-MM-01, 次月-01)
                guard let range = DateRange.monthRange(f.year, f.month) else {
                    return (" WHERE 1=0", [], nil)
                }
                clauses.append("m.release_date >= ? AND m.release_date < ?")
                params.append(.string(range.0))
                params.append(.string(range.1))
            } else {
                // 列存在才加
                clauses.append("m.year = ?")
                params.append(.string(f.year))
            }
        } else if !f.month.isEmpty && f.year.isEmpty {
            // 仅月（无年）→ substr 无索引 → 派生表窗口（★ S16-06 与 COUNT 同口径）
            clauses.append("substr(m.release_date, 6, 2) = ?")
            params.append(.string(padStart2(f.month)))
            derivedWindow = DerivedWindow.of(f)
        }

        if !f.maker.isEmpty {
            clauses.append("m.maker_id = ?")
            params.append(.string(f.maker))
        }
        if !f.letter.isEmpty && have.contains("number_letter") {
            // ★ S2：字头=番号前缀（idx_movies_number），不触碰无索引的 number_letter；
            // 前缀 LIKE 禁前导通配
            clauses.append("m.number LIKE ?")
            params.append(.string(f.letter.lowercased() + "%"))
        }
        if !f.seriesId.isEmpty && have.contains("series_id") {
            // 无索引列；是否包派生窗口由 browseRemote 的 lookup_scope 决定
            clauses.append("m.series_id = ?")
            params.append(.string(f.seriesId))
        }
        if !f.directorId.isEmpty && have.contains("director_id") {
            clauses.append("m.director_id = ?")
            params.append(.string(f.directorId))
        }
        if !f.publisherId.isEmpty && have.contains("publisher_id") {
            clauses.append("m.publisher_id = ?")
            params.append(.string(f.publisherId))
        }
        // 每个非空 tag：文本先经 JdbSearch.tagId 反查；查不到直接 1=0（绝不做 tag_name 全表扫）
        for t in f.tags.components(separatedBy: ",")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty }) {
            guard let tid = JdbSearch.tagId(t: t) else {
                return (" WHERE 1=0", [], nil)
            }
            clauses.append("m.id IN (SELECT movie_id FROM movie_tags WHERE tag_id = ?)")
            params.append(.string(tid))
        }
        if f.canPlay && have.contains("can_play") {
            clauses.append("m.can_play = 1")
        }
        if f.single {
            // ★ S16-06：单体按 tag_id 过滤（tag_name IN 会全表扫 465.9 万行）
            let singleIds = [JdbSearch.tagId(t: "单体作品"), JdbSearch.tagId(t: "單體作品")]
                .compactMap { $0 }
            if singleIds.isEmpty {
                return (" WHERE 1=0", [], nil)
            }
            clauses.append(
                "m.id IN (SELECT movie_id FROM movie_tags WHERE tag_id IN (" +
                    singleIds.map { _ in "?" }.joined(separator: ",") + "))")
            params.append(contentsOf: singleIds.map { SQLValue.string($0) as SQLValue? })
        }
        if f.magnet {
            clauses.append("m.magnets_count > 0")
        }
        if f.cnsub && have.contains("has_cnsub") {
            clauses.append("m.has_cnsub = 1")
        }

        let w = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        return (w, params, derivedWindow)
    }

    // MARK: - B.12 orderOf / keysetClause〔私有〕

    /// 排序 SQL（白名单 4 键 × 正倒序；未知 col 回退 release_date）。
    static func orderOf(_ col: String, _ asc: Bool) -> String {
        let d = SORT_COLS[col] ?? SORT_COLS["release_date"]!
        let dir = asc ? "ASC" : "DESC"
        if d.col == "id" { return "m.id \(dir)" }   // 收录顺序: 单列即稳定序
        let extraKeys = d.keys.count > 1 ? ", m.\(d.keys[1]) \(dir)" : ""
        return "m.\(d.col) \(dir)\(extraKeys), m.id \(dir)"
    }

    /// keyset 子句: (c1 OP ? OR (c1 = ? AND (... AND m.id OP ?))) —— keys 与 ORDER BY 对应。
    /// 占位符序：每个键列 2 份（OP 与 =），末位 id 1 份。
    static func keysetClause(_ keys: [String], _ asc: Bool) -> String {
        let op = asc ? ">" : "<"
        func rec(_ i: Int) -> String {
            let c = "m.\(keys[i])"
            if i == keys.count - 1 {
                return "(\(c) \(op) ? OR (\(c) = ? AND m.id \(op) ?))"
            }
            return "(\(c) \(op) ? OR (\(c) = ? AND \(rec(i + 1))))"
        }
        return rec(0)
    }

    // MARK: - B.13 browse〔公开〕（jdb）
    // 模板 id（按登记顺序首个命中）：非派生 → jdb.browse.list / jdb.browse.list2；
    // 派生 → jdb.browse.derived；单体 → jdb.browse.single.tagids。
    // ★ S16-08: 深 OFFSET 防御（VM 已钳一次；这里兜底 5000 行）。

    public static func browse(
        f: Filters, page: Int, per: Int, sort: String,
        asc: Bool = false, anchor: [String]? = nil
    ) async throws -> [String: Any] {
        if Db.offlineJdb {
            guard let r = await browseLocal(
                f: f, page: page, per: per, sort: sort, asc: asc,
                note: "离线 · 本地索引结果") else {
                throw QRuntimeError("离线且本地索引为空")
            }
            return r
        }
        do {
            return try await browseRemote(
                f: f, page: page, per: per, sort: sort, asc: asc, anchor: anchor)
        } catch {
            perfMark("db.err", String(ErrText.of(error).prefix(80)))
            if await Db.check("jdb") {
                Db.clearOffline("jdb")
                throw error
            }
            Db.markOffline("jdb")
            guard let r = await browseLocal(
                f: f, page: page, per: per, sort: sort, asc: asc,
                note: "本地缓存 · 可能过期") else {
                throw error
            }
            return r
        }
    }

    /// browseRemote〔私有〕：全部分支与 SQL 组装逐字。
    static func browseRemote(
        f: Filters, page: Int, per: Int, sort: String,
        asc: Bool, anchor: [String]?
    ) async throws -> [String: Any] {
        let sd = SORT_COLS[sort] ?? SORT_COLS["release_date"]!
        let (where0, params0, monthDerived) = await whereOf(f)
        // ★ S16-06: 单体标签索引未解析到 → 空结果 + 明确文案（不在列表路径扫 tag_name）
        let singleMissing = f.single && [JdbSearch.tagId(t: "单体作品"), JdbSearch.tagId(t: "單體作品")]
            .compactMap { $0 }.isEmpty
        var cols = await movieCols()
        // ★ S11-P2: keyset 锚点列必须在 SELECT 里（score 排序的 reviews_count）
        let colSet = Set(cols.components(separatedBy: ", ").map {
            substringAfterDot($0).trimmingCharacters(in: .whitespaces)
        })
        let missing = sd.keys.filter { !colSet.contains($0) && $0 != "id" }
        if !missing.isEmpty {
            cols += ", " + missing.map { "m.\($0)" }.joined(separator: ", ")
        }
        // 派生表仅用于"无列筛选的纯排序"场景; 有 year/maker/tag 等筛选时直接 filesort 小集合
        // （注意 f.month 不在 hasColumnFilter 里 → 仅月筛选仍包派生窗口）
        let hasColumnFilter = !f.year.isEmpty || !f.maker.isEmpty ||
            !f.letter.isEmpty || !f.tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            f.magnet || f.cnsub || f.canPlay || f.single ||
            !f.seriesId.isEmpty || !f.directorId.isEmpty || !f.publisherId.isEmpty
        // ★ P8.1: 系列/导演/发行商反查 —— 无索引列, 默认走"最近 2 万部派生窗口";
        //   lookup_scope=1 (设置"全库反查") 时走全表
        let unindexedLookup = !f.seriesId.isEmpty || !f.directorId.isEmpty || !f.publisherId.isEmpty
        // TODO(P6): AppSettings.lookupScope == 1 时走全库反查；当前无设置层，
        // 与 Android runCatching 失败兜底一致（false = 派生窗口 20000 部内）
        let scopeAll = false
        let derived = unindexedLookup
            ? !scopeAll
            : (sd.needsDerived || monthDerived != nil) && !hasColumnFilter
        let note: String? = {
            if singleMissing { return "标签索引未加载，单体筛选暂不可用（请联网刷新标签）" }
            if unindexedLookup && derived { return "反查已限定最近 20000 部内 · 可在设置切全库" }
            if derived && sd.needsDerived { return sd.note }
            if derived && monthDerived != nil { return "月份筛选已限定最近 20000 部内" }
            return nil
        }()
        // keyset: (键列 OP 锚值 ... AND id OP 锚id); 否则 OFFSET 跳页 (≤5000 行)
        // 占位符序: 每个键列 2 份 (< 与 =), 末位 id 1 份
        var aparams = params0
        var w = where0
        let keyset = anchor != nil && anchor!.count == sd.keys.count + 1
        if keyset {
            let ks = keysetClause(sd.keys, asc)
            w = where0.isEmpty ? " WHERE \(ks)" : "\(where0) AND \(ks)"
            let a = anchor!
            for k in 0..<(a.count - 1) {
                aparams.append(.string(a[k]))
                aparams.append(.string(a[k]))
            }
            aparams.append(.string(a.last!))
        }
        let rawOffset = keyset ? 0 : (page - 1) * per
        // ★ S16-08: 深 OFFSET 防御（VM 已钳一次；这里兜底 5000 行）
        let offset = min(rawOffset, 5000)
        if offset != rawOffset {
            perfMark("browse.offset.clamp", "page=\(page) offset=\(rawOffset)")
        }
        // 派生窗口: 反查 (无索引列) = 20000 部; 仅月 = DerivedWindow (20000); 纯排序截断 = 5000 部
        let derivedLimit: Int
        if unindexedLookup {
            derivedLimit = 20000
        } else if let md = monthDerived {
            derivedLimit = md
        } else {
            derivedLimit = 5000
        }
        let order = orderOf(sort, asc)
        // ★ S16-06/V11: 单体 tag_id IN 子查询会被优化器改写成 tag 驱动 + filesort
        //   (超大标签实测 48s); 强制按 release_date 索引倒扫, 命中 40 行即停 (实测 7ms)。
        let browseHint = f.single ? "/*+ INDEX(m idx_release) */ " : ""
        let sql = derived
            ? "SELECT \(browseHint)\(cols) FROM (SELECT id FROM movies ORDER BY release_date DESC LIMIT \(derivedLimit)) k " +
                "JOIN movies m ON m.id = k.id\(w) ORDER BY \(order) LIMIT ? OFFSET ?"
            : "SELECT \(browseHint)\(cols) FROM movies m\(w) ORDER BY \(order) LIMIT ? OFFSET ?"
        let rows = try await Db.query("jdb", sql, aparams + [.int(Int64(per)), .int(Int64(offset))])
        // 本页末行键值 → 下一页 anchor (keyset)
        var nextAnchor: [String]? = nil
        if let last = rows.last {
            let a = sd.keys.map { last.s($0) } + [last.s("id")]
            if let lastEl = a.last, !lastEl.isEmpty { nextAnchor = a }
        }
        // TODO(P5): Indexer.upsertMoviesAsync(rows)
        return [
            "total": Int64(-1), "items": rows, "page": page,
            "anchor": nextAnchor ?? NSNull(), "derived": note ?? "", "approx": true,
            "served": "remote",
        ]
    }

    /// ★ S16-01: 离线筛选统一入口 —— 能力声明 + fail-closed DSL（browseLocal/browseCount 共用）。
    /// TODO(P5): tag 名解析失败 / shadowTagIndex 未开启 → fail-closed " WHERE 1=0" + reason；
    /// 否则 LocalFilterSql.build(f, tagIds, singleIds, IdxDb.localCaps(), DateRange.monthRange)。
    static func localFilterQuery(_ f: Filters) -> (empty: Bool, reason: String, whereSql: String) {
        (true, "本地索引未接入 (P5)", " WHERE 1=0")
    }

    /// browseLocal〔私有〕：IdxDb 键索引（★ S12-P0/P1 ShadowFts 已停用）。
    /// 整库空 → nil；lq.empty → total=0 空态；正常 → 本地真值 total，anchor nil。
    /// 本地 OFFSET 无 5000 钳制（由 IdxDb 内部决定）。
    static func browseLocal(
        f: Filters, page: Int, per: Int, sort: String,
        asc: Bool, note: String = "离线 · 本地索引结果"
    ) async -> [String: Any]? {
        // TODO(P5): IdxDb 接线 —— Android: countOfExact("idx_movies")==0 → nil；
        // lq = localFilterQuery(f)；lq.empty → ["total": 0, "items": [], "page": page,
        // "anchor": null, "approx": true, "served": "local", "derived": lq.reason]；
        // 否则 IdxDb.browseMovies(lq, sort, asc, per, (page-1)*per) + IdxDb.countMovies(lq)，
        // derived = items 空且 total==0 时 "本地索引中没有符合条件的影片" 否则 note。
        // 当前本地索引未接入（P5）→ 整库为空 → 与 Android 空索引行为一致：nil。
        return nil
    }

    // MARK: - B.14 browseCount〔公开〕（jdb）
    // ★ S2: 异步计数。仅走索引形态: 无筛选(估算) / year / maker / 字头前缀。
    // ★ S16-01: 离线走本地同口径 COUNT（与列表同一 LocalQuery），不再误报 -1。
    // 模板 id：月派生 → jdb.count.derived（先登记先命中，遮蔽 jdb.count.month.derived）；
    // 无筛选 → admin.tablerows；其它 → jdb.count.filtered。异常 → -1。

    public static func browseCount(f: Filters, sort: String) async -> Int64 {
        if Db.offlineJdb {
            // TODO(P5): IdxDb —— countOfExact("idx_movies")==0 → 0；
            // lq = localFilterQuery(f)；lq.empty → 0；否则 IdxDb.countMovies(lq)。
            // 当前本地索引未接入 → 空库 → 0（与 Android 空索引分支一致）。
            return 0
        }
        do {
            let (whereStr, params, derivedWindow) = await whereOf(f)
            if whereStr == " WHERE 1=0" { return 0 }
            if let dw = derivedWindow {
                // ★ S16-06: 仅月计数与列表同派生窗口（20000），不再全表 substr 扫描
                return try await Db.scalar(
                    "jdb",
                    "SELECT COUNT(*) FROM (SELECT id FROM movies " +
                        "ORDER BY release_date DESC LIMIT \(dw)) k " +
                        "JOIN movies m ON m.id = k.id\(whereStr)",
                    params)
            }
            if whereStr.isEmpty {
                // 无筛选: information_schema 估算 (毫秒级, "约 N 部")
                return try await Db.scalar(
                    "jdb",
                    "SELECT TABLE_ROWS FROM information_schema.tables " +
                        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'movies'")
            }
            return try await Db.scalar("jdb", "SELECT COUNT(*) FROM movies m\(whereStr)", params)
        } catch {
            return -1   // UI 只显示"已加载 N 条"
        }
    }

    // MARK: - B.16 movie〔公开〕（jdb）
    // 模板 id：主行 jdb.movie.main(pk)；tags jdb.movie.tags(idx)；actors jdb.movie.actors(idx)；
    // gender jdb.actors.ids(pk)；magnets jdb.movie.magnets(idx)；previews jdb.movie.previews(idx)。
    // 无分页、无 COUNT（详情单行）。

    public static func movie(mid: String) async throws -> [String: Any]? {
        if !Db.offlineJdb {
            do {
                if let m = try await movieRemote(mid) {
                    // TODO(P5): Indexer.upsertMovieDetailAsync(m, tags, actors, magnets)
                    return m
                }
                // 0 行（已删除/迁移）→ 本地索引直接返回（★ S16-15，不再直接 null）
                return await movieLocal(mid, note: "本地索引 · 远程无此影片")
            } catch {
                perfMark("db.err", String(ErrText.of(error).prefix(80)))
                if await Db.check("jdb") {
                    Db.clearOffline("jdb")
                    throw error
                }
                Db.markOffline("jdb")
                guard let m = await movieLocal(mid, note: "本地缓存 · 可能过期") else {
                    throw error   // ★ S15-16
                }
                return m
            }
        }
        return await movieLocal(mid, note: "离线 · 仅索引信息 (磁力/剧照需联网)")
    }

    /// movieRemote〔私有〕。
    static func movieRemote(_ mid: String) async throws -> [String: Any]? {
        let rows = try await Db.query(
            "jdb", "SELECT \(await movieDetailCols()) FROM movies WHERE id = ?",
            strs([mid]))
        if rows.isEmpty { return nil }
        var m = jrow(rows[0])
        m["tags"] = try await Db.query(
            "jdb", "SELECT tag_id, tag_name FROM movie_tags WHERE movie_id = ?", strs([mid]))
        var actors = try await Db.query(
            "jdb", "SELECT actor_id, actor_name FROM movie_actors WHERE movie_id = ?", strs([mid]))
        // ★ P5.6: PK IN 批量取 gender (≤20 人), 并进 actors 每行
        let aids = actors.map { $0.s("actor_id") }.filter { !$0.isEmpty }
        if !aids.isEmpty {
            let ph = aids.map { _ in "?" }.joined(separator: ",")
            do {
                let gRows = try await Db.query(
                    "jdb", "SELECT id, name, gender FROM actors WHERE id IN (\(ph))", strs(aids))
                var gm: [String: Int64] = [:]
                for g in gRows { gm[g.s("id")] = g.i("gender") }
                actors = actors.map { r in
                    var row = r
                    row["gender"] = SQLValue.int(gm[row.s("actor_id")] ?? 0)
                    return row
                }
            } catch {
                /* gender 缺失 → UI 不显示符号 */
            }
        }
        // ★ S10-P6 (4.3): 女演员排前面 —— 稳定分区（gender==1 男 → 沉底, 同组保持原序;
        //   Kotlin sortedWith 是稳定排序 → filter 保持原序后拼接等价）
        let female = actors.filter { $0.i("gender") != 1 }
        let male = actors.filter { $0.i("gender") == 1 }
        m["actors"] = (female + male).map { jrow($0) }
        m["magnets"] = try await Db.query(
            "jdb",
            "SELECT hash, name, size, cnsub, hd, files_count, created_at " +
                "FROM magnets WHERE movie_id = ?",
            strs([mid]))
        m["previews"] = try await Db.query(
            "jdb", "SELECT url FROM movie_images WHERE movie_id = ? AND kind='preview'",
            strs([mid])).compactMap { rowToString($0, "url") }
        return m
    }

    /// movieLocal〔私有〕：ShadowDb 打开过的全字段详情优先 → IdxDb 最小详情 → nil。
    static func movieLocal(_ mid: String, note: String) async -> [String: Any]? {
        // TODO(P5): ShadowDb.movieById(mid)（补 derived=note，若原 derived 空）→
        // IdxDb.movieById 最小详情 + tags(tag_id + tagNameOf(id) ?: "") +
        // actors(actor_id/actor_name/name) + magnets/previews = [] + derived = note。
        // 当前本地索引未接入（P5）→ 都没有 → nil。
        return nil
    }

    // MARK: - B.17 movieByNumber〔公开〕（jdb）
    // ★ P6.4: 番号直达 (资讯正文番号可点) —— idx_movies_number 精确。
    // 模板 id：jdb.movie.bynumber(idx)。

    public static func movieByNumber(number: String) async -> Row? {
        do {
            return try await Db.query(
                "jdb", "SELECT id, number FROM movies WHERE number = ? LIMIT 1",
                strs([number.trimmingCharacters(in: .whitespaces)])).first
        } catch { return nil }
    }

    // MARK: - B.18 actors〔公开〕（jdb）
    // 模板 id：jdb.actors.page（sort kind："10 万行 filesort ~1.3s (已登记临时态)"）。
    // OFFSET 无钳制；total = -1（VM 异步 actorsCount）。

    public static func actors(
        sort: String, q: String, page: Int, per: Int, gender: String
    ) async throws -> [String: Any] {
        if Db.offlineJdb {
            guard let r = await actorsLocal(
                sort: sort, q: q, page: page, per: per, gender: gender,
                note: "离线 · 本地索引结果 (可能过期)") else {
                throw QRuntimeError("离线且本地女优索引为空")
            }
            return r
        }
        do {
            // 在线列清单
            let base = ["id", "name", "avatar_url", "videos_count"]
            let have = await Db.cols("jdb", "actors")
            let eff: Set<String> = have.isEmpty
                ? Set(base).union(["gender", "merged_into"]) : have
            let primary = base.filter { eff.contains($0) }
            let primaryList = primary.isEmpty ? ["id", "name"] : primary
            let listCols = (primaryList + ["name_zht", "popularity", "avg_score_all", "avg_score_solo"]
                .filter { eff.contains($0) }).joined(separator: ", ")
            // WHERE 片段
            var clauses: [String] = []
            var params: [SQLValue?] = []
            if eff.contains("merged_into") {
                clauses.append("(merged_into IS NULL OR merged_into = '')")
            }
            if !q.isEmpty {
                let p = "\(q.lowercased())%"
                if ["name", "aliases", "other_name"].allSatisfy({ eff.contains($0) }) {
                    clauses.append("(name LIKE ? OR aliases LIKE ? OR other_name LIKE ?)")
                    params.append(contentsOf: [.string(p), .string(p), .string(p)])
                } else {
                    clauses.append("name LIKE ?")
                    params.append(.string(p))
                }
            }
            if eff.contains("gender") {
                switch gender {
                case "m": clauses.append("gender = 1")
                case "f": clauses.append("gender <> 1")
                default: break
                }
            }
            let whereStr = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sorts = actorSorts(eff)
            let order = sorts[sort] ?? sorts["videos"] ?? "videos_count DESC"
            let rows = try await Db.query(
                "jdb",
                "SELECT \(listCols) FROM actors \(whereStr) ORDER BY \(order) " +
                    "LIMIT ? OFFSET ?",
                params + [.int(Int64(per)), .int(Int64((page - 1) * per))])
            // TODO(P5): Indexer.upsertActorsAsync(rows)
            // （返回 map 无 "served" 键——与 browse/search 不一致，照抄）
            return ["total": Int64(-1), "page": page, "items": rows, "approx": true]
        } catch {
            perfMark("db.err", String(ErrText.of(error).prefix(80)))
            if await Db.check("jdb") {
                Db.clearOffline("jdb")
                throw error
            }
            Db.markOffline("jdb")
            guard let r = await actorsLocal(
                sort: sort, q: q, page: page, per: per, gender: gender,
                note: "本地索引 · 可能过期") else {
                throw error
            }
            return r
        }
    }

    /// actorSorts〔私有〕：方向内嵌在映射里（无 asc 参数）；NULL/0 值沉底。
    static func actorSorts(_ have: Set<String>) -> [String: String] {
        let all: [(String, String)] = [
            ("videos", "videos_count DESC"), ("popularity", "popularity DESC"),
            ("name", "name ASC"),
            ("debut", "(debut IS NULL OR debut=''), debut ASC"),
            ("avg_all", "(avg_score_all IS NULL OR avg_score_all=0), avg_score_all DESC"),
            ("avg_solo", "(avg_score_solo IS NULL OR avg_score_solo=0), avg_score_solo DESC"),
        ]
        var out: [String: String] = [:]
        for (k, v) in all {
            if k == "videos" || k == "name" || have.contains(actorSortKey(v)) {
                out[k] = v
            }
        }
        return out
    }

    /// v.substringBefore(" ").trim('(',')').split(",")[0].trim() 对位。
    private static func actorSortKey(_ v: String) -> String {
        let before = v.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? v
        let trimmed = before.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let first = trimmed.components(separatedBy: ",").first ?? ""
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// actorsLocal〔私有〕：IdxDb 本地女优索引。
    static func actorsLocal(
        sort: String, q: String, page: Int, per: Int, gender: String, note: String
    ) async -> [String: Any]? {
        // TODO(P5): IdxDb —— countActors()==0 → nil；
        // total = IdxDb.countActorsFiltered(q, gender)（本地真值）；
        // items = IdxDb.actors(q, gender, sort, page, per)；
        // 返回 ["total": total, "page": page, "items": items, "approx": true, "derived": note]。
        // 当前本地索引未接入（P5）→ nil。
        return nil
    }

    // MARK: - B.19 actorsCount〔公开〕（jdb）
    // ★ S2: 女优异步计数 (失败 -1); ★ S13-P4: 离线走本地索引真值。
    // 模板 id：jdb.actors.count(count kind，异步合法)。

    public static func actorsCount(q: String, gender: String) async -> Int64 {
        if Db.offlineJdb {
            // TODO(P5): IdxDb.countActorsFiltered(q, gender)
            return 0   // 当前本地索引未接入 → 空库 → 0
        }
        do {
            let have = await Db.cols("jdb", "actors")
            // 注意与 actors 的 eff 兜底不同：无 gender/merged_into 时这些筛选被静默省略
            let eff: Set<String> = have.isEmpty ? ["id", "name"] : have
            var clauses: [String] = []
            var params: [SQLValue?] = []
            if eff.contains("merged_into") {
                clauses.append("(merged_into IS NULL OR merged_into = '')")
            }
            if !q.isEmpty {
                let p = "\(q.lowercased())%"
                if ["name", "aliases", "other_name"].allSatisfy({ eff.contains($0) }) {
                    clauses.append("(name LIKE ? OR aliases LIKE ? OR other_name LIKE ?)")
                    params.append(contentsOf: [.string(p), .string(p), .string(p)])
                } else {
                    clauses.append("name LIKE ?")
                    params.append(.string(p))
                }
            }
            if eff.contains("gender") {
                switch gender {
                case "m": clauses.append("gender = 1")
                case "f": clauses.append("gender <> 1")
                default: break
                }
            }
            let whereStr = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            return try await Db.scalar("jdb", "SELECT COUNT(*) FROM actors \(whereStr)", params)
        } catch {
            return -1
        }
    }

    // MARK: - B.20 actor〔公开〕（jdb）
    // 模板 id：主行 jdb.actor.main(pk)；count jdb.actor.count / jdb.actor.count.tagged(idx)；
    // items jdb.actor.movies.sort(idx)。
    // COUNT 同步、与 items 同口径（S15-07）—— total 是真值，非 -1。OFFSET 无钳制。

    public static func actor(
        aid: String, page: Int, per: Int,
        sort: String = "release_date", asc: Bool = false,
        tagId: String = ""
    ) async throws -> [String: Any]? {
        if Db.offlineJdb {
            return await actorLocal(
                aid: aid, page: page, per: per, sort: sort, asc: asc, tagId: tagId,
                note: "离线 · 本地索引结果 (可能过期)")
        }
        do {
            let rows = try await Db.query("jdb", "SELECT * FROM actors WHERE id = ?", strs([aid]))
            if rows.isEmpty { return nil }
            let a = rows[0]
            let merged = a.s("merged_into")
            let mainId = merged.isEmpty ? aid : merged
            // ★ S15-07: count 与 items 同口径（tagId 非空时 JOIN movie_tags）
            let count = try await Db.scalar(
                "jdb",
                ActorTagSql.remoteCount(tagged: !tagId.isEmpty),
                ActorTagSql.remoteParams(mainId, tagId).map { SQLValue.string($0) as SQLValue? })
            var w = " WHERE ma.actor_id = ?"
            var params: [SQLValue?] = [.string(mainId)]
            if !tagId.isEmpty {
                w += " AND m.id IN (SELECT movie_id FROM movie_tags WHERE tag_id = ?)"
                params.append(.string(tagId))
            }
            params.append(.int(Int64(per)))
            params.append(.int(Int64((page - 1) * per)))
            let cols = await movieCols()
            let items = try await Db.query(
                "jdb",
                "SELECT \(cols) FROM movies m " +
                    "JOIN movie_actors ma ON ma.movie_id = m.id\(w) " +
                    "ORDER BY \(orderOf(sort, asc)) LIMIT ? OFFSET ?",
                params)
            return ["actor": jrow(a), "total": count, "items": items, "page": page]
        } catch {
            perfMark("db.err", String(ErrText.of(error).prefix(80)))
            if await Db.check("jdb") {
                Db.clearOffline("jdb")
                throw error
            }
            Db.markOffline("jdb")
            return await actorLocal(
                aid: aid, page: page, per: per, sort: sort, asc: asc, tagId: tagId,
                note: "本地索引 · 可能过期")
        }
    }

    /// actorLocal〔私有〕：IdxDb.actorById；主号行缺失退回合并号行（★ S16-14）。
    static func actorLocal(
        aid: String, page: Int, per: Int, sort: String, asc: Bool, tagId: String, note: String
    ) async -> [String: Any]? {
        // TODO(P5): IdxDb —— actorById(aid)；mainId = merged_into 非空 ? merged_into : aid；
        // 主号行缺失退回合并号行；count = IdxDb.actorMovieCount(mainId, tagId)；
        // items = IdxDb.actorMovies(mainId, page, per, sort, asc, tagId)；
        // actor 行补 derived=note；返回 ["actor": a, "total": count, "items": items,
        // "page": page, "derived": note]。当前未接入（P5）→ nil。
        return nil
    }

    // MARK: - B.21 actorTags〔公开〕（jdb）
    // 模板 id：jdb.actor.main；聚合 → jdb.actor.tags.page(idx)。
    // 参数序 (mainId, limit, offset)；失败 → 空列表（UI 隐藏"标签"入口）。

    public static func actorTags(aid: String, offset: Int = 0, limit: Int = 60) async -> [Row] {
        if Db.offlineJdb {
            // TODO(P5): IdxDb.actorTags(mainId, offset, limit)，每行 name 置 tagNameOf(id) ?? "#\(id)"
            return []
        }
        do {
            let first = try await Db.query("jdb", "SELECT * FROM actors WHERE id = ?", strs([aid]))
            let merged = first.first?.s("merged_into") ?? ""
            let mainId = merged.isEmpty ? aid : merged
            return try await Db.query(
                "jdb",
                "SELECT tag_id id, MAX(tag_name) name, COUNT(*) c FROM movie_tags " +
                    "WHERE movie_id IN (SELECT movie_id FROM movie_actors WHERE actor_id = ?) " +
                    "GROUP BY tag_id " + ActorTagSql.REMOTE_TAG_ORDER + " LIMIT ? OFFSET ?",
                [.string(mainId), .int(Int64(limit)), .int(Int64(offset))])
        } catch { return [] }
    }

    // MARK: - B.22 actorTagCount〔公开〕（jdb）
    // ★ S14-P8: 女优标签总数 (COUNT(DISTINCT tag_id)); 离线走 IdxDb.actorTagCount。
    // 模板 id：jdb.actor.main；计数 → jdb.actor.tags.count(idx)。

    public static func actorTagCount(aid: String) async -> Int64 {
        if Db.offlineJdb {
            // TODO(P5): IdxDb.actorTagCount(mainId)（merged_into 同样先解析）
            return 0
        }
        do {
            let first = try await Db.query("jdb", "SELECT * FROM actors WHERE id = ?", strs([aid]))
            let merged = first.first?.s("merged_into") ?? ""
            let mainId = merged.isEmpty ? aid : merged
            return try await Db.scalar(
                "jdb",
                "SELECT COUNT(DISTINCT tag_id) c FROM movie_tags " +
                    "WHERE movie_id IN (SELECT movie_id FROM movie_actors WHERE actor_id = ?)",
                strs([mainId]))
        } catch { return 0 }
    }

    // MARK: - B.23 shtCategories〔公开〕（sht）
    // 模板 id：subs → sht.cat.subs；cats → sht.cat.cats；types → sht.cat.types；
    // total → admin.tablerows。无分页；subs/types 无显式 ORDER BY（mains 在 Kotlin 侧排序）。

    public static func shtCategories() async throws -> [String: Any] {
        let tt = await Db.tableOf("sht", "threads")
        let win = 80000   // ★ P3.9：20000 → 80000 帖
        // R3 问题 9：main 用 COALESCE(NULLIF(TRIM(board),''), cat_name) 归一化
        // （与 ShtSearch.list/count/shtExport 同口径）；board_name 仍副版、type 仍分类。
        let subs = try await Db.query(
            "sht",
            "SELECT COALESCE(NULLIF(TRIM(board), ''), cat_name) main, board_name name, COUNT(*) c FROM " +
                "(SELECT board, board_name, cat_name FROM \(tt) ORDER BY tid DESC LIMIT \(win)) k " +
                "WHERE board_name IS NOT NULL " +
                "GROUP BY main, board_name")
        let cats = try await Db.query(
            "sht",
            "SELECT cat_name name, COUNT(*) c FROM " +
                "(SELECT cat_name FROM \(tt) ORDER BY tid DESC LIMIT \(win)) k " +
                "WHERE cat_name IS NOT NULL GROUP BY cat_name ORDER BY c DESC")
        let types = try await Db.query(
            "sht",
            "SELECT board_name sub, `type` name, COUNT(*) c FROM " +
                "(SELECT board_name, `type` FROM \(tt) ORDER BY tid DESC LIMIT \(win)) k " +
                "WHERE `type` IS NOT NULL AND `type` != '' GROUP BY board_name, `type`")
        let total: Int64
        do {
            total = try await Db.scalar(
                "sht",
                "SELECT TABLE_ROWS FROM information_schema.tables " +
                    "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?",
                strs([tt]))
        } catch {
            total = -1
        }
        // mains：subs 按 main 聚和后按 c 降序（Kotlin sortedByDescending 稳定 →
        // 并列保持首现顺序）
        var acc: [(name: String, c: Int64)] = []
        var firstIdx: [String: Int] = [:]
        for r in subs {
            let k = r.s("main")
            if let p = firstIdx[k] {
                acc[p].c += r.i("c")
            } else {
                firstIdx[k] = acc.count
                acc.append((k, r.i("c")))
            }
        }
        let mains: [[String: Any]] = acc.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.c != rhs.element.c { return lhs.element.c > rhs.element.c }
                return lhs.offset < rhs.offset
            }
            .map { ["name": $0.element.name, "c": $0.element.c] }
        return [
            "categories": cats, "mains": mains, "subs": subs, "types": types,
            "total": total, "approx": true, "ts": nowMs(),
        ]
    }

    // MARK: - B.24 shtListCols〔私有〕（sht）
    // ★ S12-P5：last_checked 必须在 SELECT（sort=updated 时 keyset 锚点列）。

    static func shtListCols(_ tt: String) async -> String {
        let want = [
            "tid", "title", "cat_name", "board", "board_name", "type",
            "post_date", "last_checked", "magnet_count", "article_words", "paywalled", "author",
        ]
        let have = await Db.cols("sht", tt)
        let cols = want.filter { have.contains($0) }
        if cols.isEmpty { return "tid, title, post_date" }
        return cols.joined(separator: ", ")
    }

    // MARK: - B.28 shtThread〔公开〕（sht）
    // 模板 id：main sht.detail.main(pk)；magnets sht.detail.magnets；ed2k sht.detail.ed2k；
    // images sht.detail.images；videos sht.detail.videos。
    // 注意：离线只走 ShadowDb，没有 IdxDb 最小详情兜底（与 movie 的双层兜底不同）。
    // 无分页、无 COUNT。

    public static func shtThread(tid: String) async throws -> [String: Any]? {
        if !Db.offlineSht {
            do {
                guard let t = try await shtThreadRemote(tid) else { return nil }
                // TODO(P5): Indexer.upsertThreadDetailAsync(t, magnets)
                return t
            } catch {
                perfMark("sht.err", String(ErrText.of(error).prefix(80)))
                if await Db.check("sht") {
                    Db.clearOffline("sht")
                    throw error
                }
                Db.markOffline("sht")
                guard let t = await shtThreadLocal(tid, note: "本地缓存 · 可能过期") else {
                    throw error
                }
                return t
            }
        }
        // 正文 blocks/图片不入影子库，离线为空——标题+磁力可用
        return await shtThreadLocal(tid, note: "")
    }

    /// shtThreadRemote〔私有〕：$tt/$tm/$te/$ti/$tv 为 Db.tableOf 结果插值。
    static func shtThreadRemote(_ tid: String) async throws -> [String: Any]? {
        let tt = await Db.tableOf("sht", "threads")
        let rows = try await Db.query("sht", "SELECT * FROM \(tt) WHERE tid = ?", strs([tid]))
        if rows.isEmpty { return nil }
        var t = jrow(rows[0])
        let tm = await Db.tableOf("sht", "magnets")
        let te = await Db.tableOf("sht", "thread_ed2k")
        let ti = await Db.tableOf("sht", "thread_images")
        let tv = await Db.tableOf("sht", "thread_videos")
        let mags = try await Db.query(
            "sht", "SELECT hash, name, size, first_seen, link FROM \(tm) WHERE tid = ?",
            strs([tid])).map { r -> [String: Any] in
                var m = jrow(r)
                if js(m, "link").isEmpty {
                    m["link"] = "magnet:?xt=urn:btih:" + js(m, "hash")
                }
                return m
            }
        t["magnets"] = mags
        t["ed2k"] = try await Db.query(
            "sht", "SELECT url, name, size, first_seen FROM \(te) WHERE tid = ?", strs([tid]))
        t["images"] = try await Db.query(
            "sht", "SELECT url FROM \(ti) WHERE tid = ?", strs([tid]))
            .compactMap { rowToString($0, "url") }
        t["videos"] = try await Db.query(
            "sht", "SELECT url FROM \(tv) WHERE tid = ?", strs([tid]))
            .compactMap { rowToString($0, "url") }
        // 正文 blocks：article.trimStart().startsWith("[") 时按 JSONArray 解析；
        // 字符串键 t/i/b/c/al（有键且非 null 才放，optString），整型键 sz（optInt）。
        // 解析失败静默。
        let article = js(t, "article")
        if article.drop(while: { $0.isWhitespace }).first == "[" {
            do {
                if let arr = try JSONSerialization.jsonObject(with: Data(article.utf8))
                    as? [[String: Any]] {
                    var blocks: [[String: Any]] = []
                    for b in arr {
                        var blk: [String: Any] = [:]
                        for k in ["t", "i", "b", "c", "al"] {
                            if let v = b[k], !(v is NSNull) { blk[k] = "\(v)" }
                        }
                        blk["sz"] = (b["sz"] as? NSNumber)?.intValue
                            ?? (b["sz"] as? Int) ?? 0   // optInt 默认 0
                        blocks.append(blk)
                    }
                    t["blocks"] = blocks
                }
            } catch { /* 解析失败静默 */ }
        }
        t["words"] = jl(t, "article_words")
        return t
    }

    /// ShadowDb.threadById 对位（P5 接线；shtThread 离线只走影子库）。
    private static func shtThreadLocal(_ tid: String, note: String) async -> [String: Any]? {
        // TODO(P5): ShadowDb.threadById(tid)（错误路径补 derived="本地缓存 · 可能过期"）。
        // 当前未接入（P5）→ nil。
        return nil
    }

    // MARK: - B.29 shtExport〔公开〕（sht，流式）
    // 模板 id：sht.export.page / sht.export.magnets / sht.export.ed2k / sht.export.videos。
    // 镜像 db.sht_export；q 支持标题搜索, maxThreads 限定范围防止全库遍历卡死。
    // 分页语义：服务端 OFFSET 分批（2000/批），offset 累进，maxThreads（默认 800）封顶；
    // 提前 break：空批 或 rows.size < limit。子表批量每 500 tid 一批。

    public static func shtExport(
        main: String, cat: String, type: String, dFrom: String, dTo: String,
        q: String = "", maxThreads: Int = 800,
        onRows: ([Row]) async -> Void
    ) async throws {
        let tt = await Db.tableOf("sht", "threads")
        let tm = await Db.tableOf("sht", "magnets")
        let te = await Db.tableOf("sht", "thread_ed2k")
        let tv = await Db.tableOf("sht", "thread_videos")
        var ws: [String] = ["1=1"]
        var params: [SQLValue?] = []
        if !main.isEmpty {
            // R3 问题 9：与 ShtSearch.list/count 同口径（COALESCE 主版归一化）。
            ws.append("COALESCE(NULLIF(TRIM(t.board), ''), t.cat_name) = ?")
            params.append(.string(main))
        }
        if !cat.isEmpty {
            ws.append("t.board_name = ?")
            params.append(.string(cat))
        }
        if !type.isEmpty {
            ws.append("t.`type` = ?")
            params.append(.string(type))
        }
        // ★ S2: 标题词走 MATCH (≥2 字); 单字无法 FTS, 忽略 (不做 10s 级全表 LIKE)
        for w in ShtSearch.words(q: q) where w.count >= 2 {
            ws.append("MATCH(t.title) AGAINST (? IN NATURAL LANGUAGE MODE)")
            params.append(.string(w))
        }
        if !dFrom.isEmpty {
            ws.append("t.post_date >= ?")
            params.append(.string(dFrom))
        }
        if !dTo.isEmpty {
            ws.append("t.post_date <= ?")
            params.append(.string(dTo))
        }
        let w = ws.joined(separator: " AND ")
        let threadBatch = 2000
        var offset = 0
        while offset < maxThreads {
            let limit = min(threadBatch, maxThreads - offset)
            let rows = try await Db.query(
                "sht",
                "SELECT t.tid, t.title, t.post_date, t.board_name FROM \(tt) t " +
                    "WHERE \(w) ORDER BY t.post_date DESC LIMIT ? OFFSET ?",
                params + [.int(Int64(limit)), .int(Int64(offset))])
            if rows.isEmpty { break }
            offset += limit
            // 子表批量（每 500 tid 一批）+ 输出行组装
            var out: [Row] = []
            var byTid: [String: Row] = [:]
            for r in rows { byTid[r.s("tid")] = r }
            var i = 0
            let tids = rows.map { $0.s("tid") }
            while i < tids.count {
                let chunk = Array(tids[i..<min(i + 500, tids.count)])
                let ph = chunk.map { _ in "?" }.joined(separator: ",")
                let magRows = try await Db.query(
                    "sht", "SELECT tid, hash, size FROM \(tm) WHERE tid IN (\(ph))", strs(chunk))
                let ed2kRows = try await Db.query(
                    "sht", "SELECT tid, url, size FROM \(te) WHERE tid IN (\(ph))", strs(chunk))
                let vidRows = try await Db.query(
                    "sht", "SELECT tid, url FROM \(tv) WHERE tid IN (\(ph))", strs(chunk))
                let magByTid = Dictionary(grouping: magRows) { $0.s("tid") }
                let ed2kByTid = Dictionary(grouping: ed2kRows) { $0.s("tid") }
                let vidByTid = Dictionary(grouping: vidRows) { $0.s("tid") }
                for tid0 in chunk {
                    guard let th = byTid[tid0] else { continue }
                    let tidV = SQLValue.string(tid0)
                    let titleV = th.map["title"] ?? .null
                    let dateV = th.map["post_date"] ?? .null
                    for m in magByTid[tid0] ?? [] {
                        out.append(Row([
                            "tid": tidV, "title": titleV, "date": dateV,
                            "kind": .string("磁力"),
                            "link": .string("magnet:?xt=urn:btih:" + m.s("hash")),
                            "size": m.map["size"] ?? .null,
                        ]))
                    }
                    for e in ed2kByTid[tid0] ?? [] {
                        out.append(Row([
                            "tid": tidV, "title": titleV, "date": dateV,
                            "kind": .string("ED2K"),
                            "link": e.map["url"] ?? .null,
                            "size": e.map["size"] ?? .null,
                        ]))
                    }
                    for v in vidByTid[tid0] ?? [] {
                        out.append(Row([
                            "tid": tidV, "title": titleV, "date": dateV,
                            "kind": .string("视频"),
                            "link": v.map["url"] ?? .null,
                            "size": .null,
                        ]))
                    }
                }
                i += 500
            }
            await onRows(out)
            if rows.count < limit { break }
        }
    }

    // MARK: - B.30 articles〔公开〕（jdb）
    // 模板 id：jdb.articles.count / jdb.articles.page(small)。
    // 关键词是 %kw% 双侧通配 —— 全文件唯一的前导通配 LIKE（articles 是 362 行小表才被准入）。
    // OFFSET 无钳制；COUNT 同步真值；排序固定 released_at DESC。

    public static func articles(
        page: Int, per: Int, categoryId: Int? = nil, q: String = ""
    ) async throws -> [String: Any] {
        let have = await Db.cols("jdb", "articles")
        if have.isEmpty {
            throw QRuntimeError("远程库没有 articles 表 (需先跑资讯抓取)")
        }
        var ws: [String] = []
        var args: [SQLValue?] = []
        if let cid = categoryId {
            ws.append("category_id = ?")
            args.append(.int(Int64(cid)))
        }
        let kw = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if !kw.isEmpty {
            ws.append("(title LIKE ? OR content_text LIKE ?)")
            args.append(.string("%\(kw)%"))
            args.append(.string("%\(kw)%"))
        }
        let w = ws.isEmpty ? "" : " WHERE " + ws.joined(separator: " AND ")
        // COUNT 同步
        let cnt = try await Db.query("jdb", "SELECT COUNT(*) c FROM articles\(w)", args).first
        let total = cnt?.l("c") ?? 0
        let cols = [
            "id", "title", "category_id", "category_name", "author_name",
            "cover_url", "cover_path", "released_at", "word_count",
        ].filter { have.contains($0) }.joined(separator: ", ")
        // ★ 修复 NA-24：LIMIT/OFFSET 参数化
        let off = (max(1, page) - 1) * per
        let items = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM articles\(w) ORDER BY released_at DESC LIMIT ? OFFSET ?",
            args + [.int(Int64(per)), .int(Int64(off))])
        return ["items": items, "total": total, "page": page, "per": per]
    }

    // MARK: - B.31 article〔公开〕（jdb）
    // 模板 id：jdb.article.main(pk)。含 content_html 原版排版正文。

    public static func article(aid: String) async throws -> Row? {
        let have = await Db.cols("jdb", "articles")
        if have.isEmpty { return nil }
        let cols = [
            "id", "title", "category_id", "category_name", "author_name",
            "origin_name", "origin_url", "cover_url", "cover_path", "released_at",
            "content_html", "word_count",
        ].filter { have.contains($0) }.joined(separator: ", ")
        return try await Db.query(
            "jdb", "SELECT \(cols) FROM articles WHERE id = ?", strs([aid])).first
    }

    // MARK: - B.32 articleMovies〔公开〕（jdb）
    // 模板 id：jdb.article.movies(small)。排序固定 am.position。

    public static func articleMovies(aid: String) async -> [Row] {
        do {
            return try await Db.query(
                "jdb",
                "SELECT am.movie_id, am.number, am.title, am.score, am.release_date, " +
                    "am.thumb_url FROM article_movies am WHERE am.article_id = ? ORDER BY am.position",
                strs([aid]))
        } catch { return [] }
    }

    // MARK: - B.33 articleCategories〔公开〕（jdb）
    // ★ S11-P9 (真机 db.err 取证): category_name 不在 GROUP BY 会被 ONLY_FULL_GROUP_BY
    //   拒绝 (1055) → 资讯分类下拉永远为空。补齐分组列。
    // 模板 id：jdb.article.cats(small)。

    public static func articleCategories() async -> [Row] {
        do {
            return try await Db.query(
                "jdb",
                "SELECT category_id, category_name, COUNT(*) n FROM articles " +
                    "WHERE category_id IS NOT NULL GROUP BY category_id, category_name ORDER BY n DESC")
        } catch { return [] }
    }

    // MARK: - B.34 hotReviewKeys〔公开〕（jdb）
    // 模板 id：jdb.hotreview.keys(small)。
    // 空列表表示库里还没有这个时间段的数据。

    public static func hotReviewKeys(period: String) async -> [String] {
        do {
            return try await Db.query(
                "jdb",
                "SELECT period_key FROM hot_reviews WHERE period = ? " +
                    "GROUP BY period_key ORDER BY period_key DESC",
                strs([period])).map { $0.s("period_key") }
        } catch { return [] }
    }

    // MARK: - B.35 movieArticles〔公开〕（jdb）
    // ★ 影片 → 相关资讯（详情页展示用；反向走同一张 article_movies 关联表）。
    // 模板 id：jdb.article.ofmovie(small)。

    public static func movieArticles(mid: String) async -> [Row] {
        do {
            return try await Db.query(
                "jdb",
                "SELECT a.id, a.title, a.cover_url, a.cover_path, a.released_at, " +
                    "a.category_name FROM article_movies am JOIN articles a ON a.id = am.article_id " +
                    "WHERE am.movie_id = ? ORDER BY a.released_at DESC",
                strs([mid]))
        } catch { return [] }
    }

    // MARK: - B.36 hotReviews〔公开〕（jdb）
    // ★ P7 (2026-10-31): ① rank 加反引号 (MySQL 8 保留字, 旧 SQL 1064 全页不可用);
    //   ② keys 为空**不再抛异常** —— 返回 hasData=false 空态。
    // 模板 id：jdb.hotreview.count / jdb.hotreview.page(small)。
    // OFFSET 无钳制；排序固定 `rank`（升序，榜单名次序）；COUNT 同步真值。

    public static func hotReviews(
        period: String, periodKey: String? = nil, page: Int = 1, per: Int = 24
    ) async throws -> [String: Any] {
        let keys = await hotReviewKeys(period: period)
        if keys.isEmpty {
            return [
                "items": [Row](), "total": Int64(0), "page": page, "per": per,
                "keys": [String](), "key": "", "period": period, "hasData": false,
            ]
        }
        let key = periodKey.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        } ?? keys.first!
        // COUNT 同步
        let cnt = try await Db.query(
            "jdb",
            "SELECT COUNT(*) c FROM hot_reviews WHERE period = ? AND period_key = ?",
            strs([period, key])).first
        let total = cnt?.l("c") ?? 0
        // ★ NA-24 参数化；rank 反引号
        let off = (max(1, page) - 1) * per
        let items = try await Db.query(
            "jdb",
            "SELECT rid, `rank`, movie_id, number, movie_title, " +
                "movie_score, movie_thumb_url, user_name, score, likes_count, content, created_at " +
                "FROM hot_reviews WHERE period = ? AND period_key = ? ORDER BY `rank` " +
                "LIMIT ? OFFSET ?",
            [.string(period), .string(key), .int(Int64(per)), .int(Int64(off))])
        return [
            "items": items, "total": total, "page": page, "per": per,
            "keys": keys, "key": key, "period": period, "hasData": true,
        ]
    }
}

// MARK: - 搜索委托（JdbSearch / ShtSearch；集中在文件末尾，避免与并行移植文件冲突）
//
// 采用的委托签名（与 docs/_extract/03_search_math.md §1/§2 的 Kotlin 签名逐参对应，
// 保留 Kotlin 命名参数标签）：
//   JdbSearch.search(q:scope:page:per:mode:) async throws -> JdbSearch.Page
//       Page { items: [Row]; page: Int; approx: Bool; derived: String?; served: String }
//   JdbSearch.count(q:scope:) async throws -> Int64
//   JdbSearch.tagId(t:) -> String?（同步）
//   ShtSearch.isTid(q:) -> Bool（同步）
//   ShtSearch.words(q:) -> [String]（同步）
//   ShtSearch.list(tt:cols:main:cat:type:q:hasMagnet:page:per:anchor:sort:mode:)
//       async throws -> ShtSearch.Page
//       Page { items: [Row]; covers: [String: String]; page: Int; approx: Bool; derived: String? }
//   ShtSearch.count(tt:main:cat:type:q:hasMagnet:sort:) async -> Int64（内部 catch → -1）
extension Q {

    // MARK: B.9 search〔公开〕（jdb，委托 JdbSearch）
    // 模板族：jdb.search.number / jdb.search.fts / jdb.search.derived / jdb.search.actor.ids /
    // jdb.search.actor.movies / jdb.search.tag.movies / jdb.search.all.union /
    // jdb.search.byids / jdb.search.exact.number。
    // COUNT 口径：total = -1L（未知），VM 异步调 searchCount 补充（铁律 6）。

    public static func search(
        q: String, scope: String, page: Int, per: Int, mode: String = "fuzzy"
    ) async throws -> [String: Any] {
        if Db.offlineJdb {
            guard let r = await localSearch(
                q: q, scope: scope, page: page, per: per,
                note: "离线 · 本地索引结果") else {
                throw QRuntimeError("本地索引为空，请先在设置→离线索引预热")
            }
            return r
        }
        do {
            let p = try await JdbSearch.search(q: q, scope: scope, page: page, per: per, mode: mode)
            // TODO(P5): Indexer.upsertMoviesAsync(p.items)
            return [
                "total": Int64(-1), "items": p.items, "page": page,
                "approx": p.approx, "derived": p.derived ?? "", "served": "remote",
            ]
        } catch {
            perfMark("db.err", String(ErrText.of(error).prefix(80)))
            if await Db.check("jdb") {
                Db.clearOffline("jdb")
                throw error
            }
            Db.markOffline("jdb")
            guard let r = await localSearch(
                q: q, scope: scope, page: page, per: per,
                note: "本地缓存 · 可能过期") else {
                throw error
            }
            return r
        }
    }

    /// localSearch〔私有〕：走 IdxDb（★ S12-P0/P1 ShadowFts 已停用）。
    /// 整库为空才算不可用（★ S16-02：0 命中返回合法空态）；
    /// 本地 0 命中 → total=0；有命中但计数未做 → total=-1。
    static func localSearch(
        q: String, scope: String, page: Int, per: Int, note: String
    ) async -> [String: Any]? {
        // TODO(P5): IdxDb 接线 —— countOfExact("idx_movies")==0 && countOfExact("idx_threads")==0
        // → nil；否则 IdxDb.searchMovies... 返回 ["total": items.isEmpty ? 0 : -1, "items": items,
        // "page": page, "approx": true, "derived": note, "served": "local"]。
        // 当前本地索引未接入（P5）→ 整库为空 → nil。
        return nil
    }

    // MARK: B.10 searchCount〔公开〕（jdb，委托）
    // ★ S2: 异步计数 (与 search 同构走索引; 失败 -1 → UI 只显示"已加载 N 条")。
    // 模板族：jdb.count.number / jdb.count.fts / jdb.count.actor / jdb.count.tag /
    // jdb.count.union / jdb.count.derived。

    public static func searchCount(q: String, scope: String) async throws -> Int64 {
        try await JdbSearch.count(q: q, scope: scope)
    }

    // MARK: B.25 shtSemantic〔公开〕（sht，委托 SemanticEngine）
    // 模板族：sht.sem.cand / sht.sem.emb / sht.sem.fp（+ 详情取行用 sht.detail.*）。
    // null = 模型未导入，调用方明确提示，禁止静默降级。
    // TODO(P7/P8): SemanticEngine 接线（doc 03 §5 两段式：候选 idx_date → 向量二进制
    // PK IN 拉取 → EmbStore 4 线程并行打分）。采用签名：
    //   SemanticEngine.search(tt:listCols:main:cat:type:hasMagnet:q:page:per:cand:threshold:)
    //   async -> SemanticEngine.Result?（Result { items/covers/page/per/hits/cand/threshold/note }）
    // 返回映射（Android 逐字）：["items": r.items, "total": Int64(r.hits), "page": r.page,
    //   "per_page": r.per, "covers": r.covers, "approx": true, "derived": r.note]。
    // 当前语义模型未导入（ORT 在后续阶段）→ 与 Android SemanticEngine.search 返回 null 一致。

    public static func shtSemantic(
        main: String = "", cat: String = "", type: String = "",
        hasMagnet: Bool = false, q: String = "", page: Int = 1,
        per: Int = 20, cand: Int = 3000, threshold: Float = 0.10
    ) async -> [String: Any]? {
        return nil   // TODO(P7/P8): SemanticEngine.search(...) ?: return null
    }

    // MARK: B.26 shtBrowse〔公开〕（sht）
    // 模板族：sht.list.page(idx) / sht.list.derived（updated 排序/单字 → 最近 2 万帖窗口）/
    // sht.covers（封面 PK(tid,url) 前缀 IN）。
    // 分库判定只看 Db.offlineSht（★ S11-P0）。COUNT 口径：total = -1，VM 异步 shtBrowseCount。

    public static func shtBrowse(
        main: String = "", cat: String = "", type: String = "",
        q: String = "", hasMagnet: Bool = false, page: Int = 1,
        per: Int = 20, anchor: (String, String)? = nil,
        mode: String = "exact", sort: String = "date",
        cand: Int = 3000, threshold: Float = 0.10
    ) async throws -> [String: Any] {
        if Db.offlineSht {
            guard let r = await shtLocal(
                main: main, cat: cat, type: type, q: q, hasMagnet: hasMagnet,
                page: page, per: per, note: "离线 · 本地最近数据") else {
                throw QRuntimeError("离线且本地索引为空")
            }
            return r
        }
        do {
            return try await shtBrowseRemote(
                main: main, cat: cat, type: type, q: q, hasMagnet: hasMagnet,
                page: page, per: per, anchor: anchor, mode: mode, sort: sort,
                cand: cand, threshold: threshold)
        } catch {
            // ★ S4: 模型未导入/推理不可用 = 明确业务态，与网络失败区分，不降级不兜底
            if error is SemanticUnavailableError { throw error }
            perfMark("sht.err", String(ErrText.of(error).prefix(80)))
            if await Db.check("sht") {
                Db.clearOffline("sht")
                throw error
            }
            Db.markOffline("sht")
            guard let r = await shtLocal(
                main: main, cat: cat, type: type, q: q, hasMagnet: hasMagnet,
                page: page, per: per, note: "本地缓存 · 可能过期") else {
                throw error
            }
            return r
        }
    }

    /// shtBrowseRemote〔私有〕。
    static func shtBrowseRemote(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool,
        page: Int, per: Int, anchor: (String, String)?, mode: String, sort: String,
        cand: Int, threshold: Float
    ) async throws -> [String: Any] {
        let tt = await Db.tableOf("sht", "threads")
        let qs = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTid = ShtSearch.isTid(q: qs)
        if mode == "semantic" && !qs.isEmpty && !isTid {
            // ★ S4: 模型未导入 → 明确业务态 (上层提示去设置导入), **禁止静默降级模糊**
            // （语义模式：tid 直达优先，isTid 时跳过语义）
            if let r = await shtSemantic(
                main: main, cat: cat, type: type, hasMagnet: hasMagnet,
                q: qs, page: page, per: per, cand: cand, threshold: threshold) {
                return r
            }
            throw SemanticUnavailableError(
                "语义模型未导入或加载失败 — 请到 设置 → 语义搜索模型 导入")
        }
        let cols = await shtListCols(tt)
        let p = try await ShtSearch.list(
            tt: tt, cols: cols, main: main, cat: cat, type: type, q: qs,
            hasMagnet: hasMagnet, page: page, per: per, anchor: anchor, sort: sort, mode: mode)
        // TODO(P5): Indexer.upsertThreadsAsync(p.items, p.covers)
        return [
            "total": Int64(-1), "items": p.items, "page": page,
            "covers": p.covers, "approx": true, "derived": p.derived ?? "",
        ]
    }

    /// shtLocal〔私有〕：ShtSearch.searchLocal 兜底。
    static func shtLocal(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool,
        page: Int, per: Int, note: String
    ) async -> [String: Any]? {
        // TODO(P5): items = ShtSearch.searchLocal(q, page, per, main, cat, type, hasMagnet)；
        // items 空 → nil；covers = ShtSearch.fetchCovers(tids)；
        // 返回 ["total": -1, "items": items, "page": page, "covers": covers,
        // "approx": true, "derived": note]。当前本地索引未接入（P5）→ nil。
        return nil
    }

    // MARK: B.27 shtBrowseCount〔公开〕（sht，委托）
    // ★ S2: 98t 异步计数 (FTS/派生表内; 失败 -1)。
    // 模板族：sht.count.page / sht.count.derived。

    public static func shtBrowseCount(
        main: String, cat: String, type: String,
        q: String, hasMagnet: Bool, sort: String
    ) async -> Int64 {
        let tt = await Db.tableOf("sht", "threads")
        return await ShtSearch.count(
            tt: tt, main: main, cat: cat, type: type,
            q: q.trimmingCharacters(in: .whitespacesAndNewlines),
            hasMagnet: hasMagnet, sort: sort)
    }
}
