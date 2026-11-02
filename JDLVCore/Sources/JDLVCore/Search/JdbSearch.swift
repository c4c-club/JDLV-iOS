import Foundation

// JdbSearch —— jdb 搜索路由（移植自 Android JDLV-Mobile）。
//
// Android 源文件: app/src/main/java/com/jdlv/mobile/core/search/JdbSearch.kt（429 行, S2 2026-10-30）
// 提取对照: docs/_extract/03_search_math.md §1（全分支 + SQL 逐字）/ §12（外部依赖签名）/ §13（口径速查）,
//           docs/_extract/02_q_db.md §0（JRow 助手语义）。SQL / 文案 / 常量逐字。
//
// 形态全部走已有索引, 禁止前导通配直发远程:
//  - number / letter → `number LIKE 'abp%'` 前缀 (idx_movies_number), 按 number 序
//    (字头筛选与番号搜索统一到这一条路; letter 不再触碰无索引的 number_letter 列)
//  - title / all ≥2 字词 → MATCH(m.title, m.number) AGAINST(BOOLEAN) (ftx_movies, 237ms);
//    结果为空时兜底"最近 5000 部派生表内 LIKE"(覆盖 ftx 无 ngram 分词时中文 0 命中的情况)
//  - actor → 先 actors 三列 LIKE 'x%' 前缀 (≤50 人), 再 idx_actor IN 取影片
//  - tag → 仅 tag_id 数字 (idx_tag); 文本 tag 先反查 id, 反查不到返回空
//    (绝不放任 tag_name = ? 全表扫 movie_tags 464 万行)
//  - all → 三路 UNION DISTINCT 归并 (每路 ≤400, 总 ≤1600), SQL 层去重排序
//  - COUNT 不是同步前置 (铁律 6): [search] 只取页数据; [count] 由 VM 在结果渲染后异步调用。
//
// 外部依赖契约（引用其他文件/后续阶段提供的符号, 本文件不定义实现）:
//  - Db.query / Db.scalar               —— Data/Db.swift（async throws）
//  - Q.movieCols(prefix: = "m") async   —— Data/Q.swift（B.1; 非 throws）
//  - Q.tagIdByName(_:) -> String?       —— Data/Taxonomy.swift（extension Q, B.2; 纯本地同步）
//  - IdxDb（P5 落地）→ IdxSearchable 注入 JdbSearch.idx; nil 或 localReady()==false → 全走远程
//    （等价 Android localReady()==false）; 本文件不 import/store 任何具体 IdxDb。
//  - Perf 未落地 → perfSink 注入; tag/note 文案逐字（"db.fts" / "TIMEOUT 3000ms b=…"）。
//
// 与 Data/Q.swift 末尾"搜索委托"块约定的委托签名一致（Kotlin 标签逐参对应）:
//   JdbSearch.search(q:scope:page:per:mode:) async throws -> JdbSearch.Page
//   JdbSearch.count(q:scope:) async throws -> Int64（名义 throws; 内部 catch → -1）
//   JdbSearch.tagId(t:) -> String?（同步）
//   JdbSearch.words(q:) / looksLikeNumber(q:) / normalizeNumber(q:)（同步）

/// 本地索引库注入协议 —— 对齐 Android core/cache/IdxDb 被本批文件调用的全部签名
/// （docs/_extract/03_search_math.md §12 清单; 形参名以 IdxDb.kt 原文为准）。
/// IdxDb 在 P5 才实现; 在此之前注入 nil, JdbSearch/ShtSearch 全部走远程。
/// 所有方法同步 + throws（本地 SQLite 调用; 实现自行处理队列/错误）。
public protocol IdxSearchable {
    /// 本地索引是否就绪。实现须满足 Android 语义: IdxDb.countOf("idx_movies") >= 10000
    /// 才返回 true（≥1 万行才启用本地优先, 避免小索引误导"全库"）。
    func localReady() -> Bool

    /// IdxDb.countOf(table): Long —— 1s TTL 缓存的表行数（仅认 idx_* 表名）
    func countOf(table: String) throws -> Int64

    /// IdxDb.countActors(): Long —— 女优总数（= countOf("idx_actors")）
    func countActors() throws -> Int64

    /// 影片检索: 多词 AND 子串; scope ∈ {title, number, all}（letter 同 number）
    func searchMovies(q: String, scope: String, per: Int, offset: Int) throws -> [Row]

    /// 检索计数（与 searchMovies 同口径）
    func countMovies(q: String, scope: String) throws -> Int64

    /// scope=actor 检索: 女优名子串 → 关系 → 影片按时间排序分页（子集, ≤50 人）
    func searchActorMovies(q: String, page: Int, per: Int) throws -> [Row]

    /// scope=actor 计数（与 searchActorMovies 同口径）
    func countActorMovies(q: String) throws -> Int64

    /// 按标签分页取影片（i_mt_tag 索引; tag_id 由调用方经 JdbSearch.tagId 反查）
    /// （Android 形参名 tagId/limit/offset）
    func searchMoviesByTag(tagId: String, limit: Int, offset: Int) throws -> [Row]

    /// 标签计数（与 searchMoviesByTag 同口径）
    func countMoviesByTag(tagId: String) throws -> Int64

    /// tid 直达单行（idx_threads 全字段行）
    func threadById(tid: String) throws -> Row?

    /// 帖子检索: 多词 AND 子串; board/board_name/type/磁力过滤在 SQL 内完成
    /// （Android 形参名 board/boardName; Q.shtLocal 调用传 main/cat）
    func searchThreads(q: String, board: String, boardName: String, type: String,
                       hasMagnet: Bool, limit: Int, offset: Int) throws -> [Row]

    /// 帖子按排序键取页: sort ∈ {post_date, tid}; asc 生效（Android threadsBy(sort, asc, limit, offset)）
    func threadsBy(sort: String, asc: Bool, limit: Int, offset: Int) throws -> [Row]
}

public enum JdbSearch {

    // MARK: - 常量（§1.2 逐项）

    /// 派生表窗口（最近 5000 部）; 同时是跳页 OFFSET 上限
    private static let DERIVED_LIMIT = 5000

    /// 女优 id 命中上限
    private static let ACTOR_IDS_LIMIT = 50

    /// ★ S12-P1: 远程 FTS 统一超时 (超时不再无限等, UI 提示)
    private static let FTS_TIMEOUT_MS: Int64 = 3000

    /// 超时文案原文
    private static let FTS_TIMEOUT_NOTE = "远程检索超时 (3s)"

    /// ★ S12-P1: 本地索引可搜的 scope
    /// ★ S13-P4: + actor (idx_actors 预热后离线可搜; series 仍需联网)
    /// ★ S14-P7 (L1): + tag (idx_movie_tags 预热后离线可搜)
    public static let LOCAL_SCOPES: Set<String> = [
        "title", "number", "letter", "all", "actor", "tag",
    ]

    /// ★ P5.4 (2026-10-31): 输入是否形如番号 (ABP-123 / abp123 / FC2-PPV-…)。
    /// 归一: 去 -/_ → 小写。精确模式用 `number = ? OR number LIKE 'abp-%'` 前缀形态
    /// (走 idx_movies_number, 绝不 %x%)。
    private static let NUMBER_RE = try! NSRegularExpression(
        pattern: "^[A-Za-z]{2,10}[-_]?[0-9]{2,6}$")

    /// 本地索引库注入点（P5 IdxDb; App 层启动时赋值一次; nil = 无本地索引 → 全走远程）
    public static var idx: IdxSearchable?

    /// Perf 桥（Android com.jdlv.mobile.core.net.Perf.mark(tag, note);
    /// iOS Perf 未落地, App 层注入 os.Logger 桥; nil = 静默）
    public static var perfSink: ((_ tag: String, _ note: String) -> Void)?

    // MARK: - 结果页

    /// 搜索结果页: total=-1 表示总数未知(由 count() 异步补充)
    /// ★ S14-P9 (B26/L3): served 结构化来源标注 ("local"/"remote") —— UI 不再用
    /// offlineNote 文本匹配判定来源。
    public struct Page {
        public let items: [Row]
        public let page: Int
        /// true: 总数走估算/延后
        public let approx: Bool
        /// 非空: 结果被派生表截断(如"最近 5000 部内"), UI 提示用
        public let derived: String?
        public let served: String

        public init(items: [Row], page: Int, approx: Bool,
                    derived: String? = nil, served: String = "remote") {
            self.items = items
            self.page = page
            self.approx = approx
            self.derived = derived
            self.served = served
        }
    }

    // MARK: - 关键词整形（§1.4 逐字）

    /// 关键词 → 逻辑词列表 (去空格/全角空格, 最多 8 个)
    public static func words(q: String) -> [String] {
        let parts = q
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(parts.prefix(8))
    }

    /// BOOLEAN MODE 字符串: 每词加 + 前缀 (AND 语义)。
    /// ★ S12-P1 (docs/70 F1 实测): **去掉结尾 `*`** —— ngram(2) 索引上 `+SSIS*`
    /// 前缀通配要枚举海量 term, 实测 3973ms; 去掉 `*` 的短语查询 ≈ 数百 ms
    /// (P6 真机复核, 结论见 stage-S12.md)。
    /// 防御（提取文档 §1.4 移植注意）: 全符号词剔除（Android 原样会产出孤立 "+"）,
    /// 全部被剔则 b 为空串（MATCH AGAINST('') = 0 命中 → 走回退链）。
    private static func booleanQuery(_ ws: [String]) -> String {
        ws.compactMap { w -> String? in
            let core = w.filter { $0.isLetter || ($0.isASCII && $0.isNumber) }
            return core.isEmpty ? nil : "+" + core
        }
        .joined(separator: " ")
    }

    // MARK: - 本地索引检索（★ S12-P1: 主路径; IdxDb 键表+标题原文）

    /// 本地索引是否就绪 (≥1 万行才启用本地优先, 避免小索引误导"全库")
    /// （阈值在 IdxSearchable.localReady() 实现内, 见协议注释）
    public static func localReady() -> Bool {
        idx?.localReady() ?? false
    }

    /// ★ S13-P4: 女优本地索引是否就绪 (预热后 ≥1000 才启用 scope=actor 本地路)
    public static func actorLocalReady() -> Bool {
        guard let idx else { return false }
        let n = (try? idx.countActors()) ?? 0
        return n >= 1000
    }

    /// 本地索引检索 (IdxDb 多词 AND 子串; 精确全量, 无 5000 截断)。
    /// scope ∈ {title, number, letter, all, actor, tag}; tag/series 本地无该列 → 空页 +
    /// derived 提示"需联网" (调用方应走远程)。
    /// ★ S13-P4: actor → idx_actors 子串 → idx_movie_actors → idx_movies;
    /// all → title/number + actor 两路合并 (id 去重, release_date DESC)。
    public static func searchLocalIdx(
        q: String, scope: String, page: Int, per: Int
    ) async throws -> Page {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return Page(items: [], page: page, approx: false, served: "local")
        }
        if !LOCAL_SCOPES.contains(scope) {
            return Page(items: [], page: page, approx: true,
                        derived: "标签/系列搜索需联网", served: "local")
        }
        guard let idx else {
            // 未注入本地索引库 = 等价空索引（上游 localReady() 已拦截, 防御路径）
            return Page(items: [], page: page, approx: false, served: "local")
        }
        switch scope {
        case "actor":
            if !actorLocalReady() {
                return Page(items: [], page: page, approx: true,
                            derived: "本地女优索引未就绪 (预热中/未开启), 需联网", served: "local")
            }
            let rows = try idx.searchActorMovies(q: query, page: page, per: per)
            return Page(items: rows, page: page, approx: false,
                        derived: "本地索引（女优）", served: "local")

        case "tag":
            // ★ S14-P7 (L1): 标签本地检索 —— tag 文本/数字反查 tag_id,
            //   idx_movie_tags (i_mt_tag) 分页; 不存在的标签给明确空态提示
            guard let tid = tagId(t: query) else {
                return Page(items: [], page: page, approx: true,
                            derived: "标签不存在", served: "local")
            }
            let rows = try idx.searchMoviesByTag(
                tagId: tid, limit: per, offset: (page - 1) * per)
            return Page(items: rows, page: page, approx: false,
                        derived: "本地索引（标签）", served: "local")

        case "all":
            let base = try idx.searchMovies(
                q: query, scope: "all", per: per, offset: (page - 1) * per)
            let extra = actorLocalReady()
                ? (try idx.searchActorMovies(q: query, page: page, per: per))
                : []
            if extra.isEmpty {
                return Page(items: base, page: page, approx: false,
                            derived: "本地索引", served: "local")
            }
            // (base + extra) 以 id 串去重（Kotlin seen.add 语义: 首现保留, 空 id 互相吞并同键）
            var seen = Set<String>()
            var merged: [Row] = []
            for r in base + extra {
                let key = r.isNull("id") ? "" : r.s("id")
                if seen.insert(key).inserted { merged.append(r) }
            }
            // 字符串比较降序: release_date, 后 id 兜底（compareByDescending toString 语义）
            merged.sort { a, b in
                (a.s("release_date"), a.s("id")) > (b.s("release_date"), b.s("id"))
            }
            return Page(items: Array(merged.prefix(per)), page: page, approx: true,
                        derived: "本地索引（含女优）", served: "local")

        default:
            let rows = try idx.searchMovies(
                q: query, scope: scope, per: per, offset: (page - 1) * per)
            return Page(items: rows, page: page, approx: false,
                        derived: "本地索引", served: "local")
        }
    }

    /// 本地索引计数 (异步; 失败 -1 → UI 显示"已加载 N 条");
    /// ★ S13-P4: actor/all 支持; ★ S14-P7: tag 支持。
    /// 注意: "all" 计数 = title/number 路计数 + actor 路计数（不去重相加, 原样语义）。
    public static func countLocalIdx(q: String, scope: String) async -> Int64 {
        guard let idx else { return 0 }   // 未注入 = 等价空索引口径
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch scope {
            case "actor":
                return actorLocalReady() ? (try idx.countActorMovies(q: trimmed)) : 0
            case "tag":
                guard let tid = tagId(t: trimmed) else { return 0 }
                return try idx.countMoviesByTag(tagId: tid)
            case "all":
                return (try idx.countMovies(q: trimmed, scope: "all"))
                    + (try idx.countActorMovies(q: trimmed))
            default:
                return try idx.countMovies(q: trimmed, scope: scope)
            }
        } catch {
            return -1   // 计数失败不阻塞, UI 显示"已加载 N 条"
        }
    }

    /// tag 文本 → tag_id (assets/tags_index.json 反查; 数字原样返回)
    /// 找不到 → nil (调用方返回空, 不扫 movie_tags)
    public static func tagId(t: String) -> String? {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.allSatisfy({ $0.isASCII && $0.isNumber }) { return s }
        return Q.tagIdByName(s)
    }

    // MARK: - 番号判定 / 归一（§1.5 逐字）

    public static func looksLikeNumber(q: String) -> Bool {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(s.startIndex..., in: s)
        return NUMBER_RE.firstMatch(in: s, options: [], range: range) != nil
    }

    public static func normalizeNumber(q: String) -> String {
        q.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }

    // MARK: - 搜索路由（§1.9 逐字）

    public static func search(
        q: String, scope: String, page: Int, per: Int, mode: String = "fuzzy"
    ) async throws -> Page {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return Page(items: [], page: page, approx: true)
        }
        let offset = (page - 1) * per
        if offset > DERIVED_LIMIT {
            // 跳页上限与派生表截断同量级, 更深请用连续浏览
            return Page(items: [], page: page, approx: true,
                        derived: "跳页过深 (仅支持前 \(DERIVED_LIMIT / per) 页), 请用滚动加载")
        }
        let cols = await Q.movieCols()
        let lower = query.lowercased()
        let exact = mode == "exact"
        switch scope {
        case "number":
            if exact && looksLikeNumber(q: query) {
                return try await exactNumber(cols, query, page, per, offset)
            }
            let p = lower + "%"
            let rows = try await Db.query(
                "jdb",
                "SELECT \(cols) FROM movies m WHERE m.number LIKE ? " +
                    "ORDER BY m.number, m.id LIMIT ? OFFSET ?",
                [.string(p), .int(Int64(per)), .int(Int64(offset))])
            return Page(items: rows, page: page, approx: true)

        case "letter":
            // 字头 = 番号前缀 (同一索引)
            let p = lower + "%"
            let rows = try await Db.query(
                "jdb",
                "SELECT \(cols) FROM movies m WHERE m.number LIKE ? " +
                    "ORDER BY m.number, m.id LIMIT ? OFFSET ?",
                [.string(p), .int(Int64(per)), .int(Int64(offset))])
            return Page(items: rows, page: page, approx: true)

        case "title":
            return exact
                ? try await exactTitle(cols, query, page, per, offset)
                : try await titleSearch(cols, words(q: query), page, per, offset)

        case "actor":
            return exact
                ? try await exactActor(cols, query, page, per, offset)
                : try await actorSearch(cols, query, page, per, offset)

        case "tag":
            guard let tid = tagId(t: query) else {
                return Page(items: [], page: page, approx: true)
            }
            let rows = try await Db.query(
                "jdb",
                "SELECT \(cols) FROM movies m WHERE m.id IN " +
                    "(SELECT movie_id FROM movie_tags WHERE tag_id = ?) " +
                    "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
                [.string(tid), .int(Int64(per)), .int(Int64(offset))])
            return Page(items: rows, page: page, approx: true)

        case "series":
            // ★ P5.2
            return try await seriesSearch(cols, query, page, per, offset, exact)

        default:
            return exact
                ? try await exactAll(cols, query, page, per, offset)
                : try await allSearch(cols, query, page, per, offset)
        }
    }

    // MARK: - 精确族（§1.10 逐字）

    /// ★ 精确 + 番号: `number = ? OR number LIKE '字头%'` (idx_movies_number 前缀)。
    /// 归一串作精确值 (兼容两种分隔符存储); LIKE 用"字头%"前缀形态 (abp% 同时命中
    /// abp-123 / abp123 / abp-1…), 保持前缀, 绝不 %x%。
    private static func exactNumber(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        let norm = normalizeNumber(q: q)
        let head = String(norm.prefix(while: { !($0.isASCII && $0.isNumber) }))
        let prefix = (head.isEmpty ? norm : head) + "%"
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM movies m WHERE m.number = ? OR m.number LIKE ? " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            [.string(norm), .string(prefix), .int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true, derived: "精确匹配 · 番号/前缀")
    }

    /// ★ 精确 + 标题: 派生窗口 (最近 5000 部) 内 `title LIKE '%q%'` (含 % 但窗口内)
    private static func exactTitle(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM (SELECT id FROM movies ORDER BY release_date DESC LIMIT \(DERIVED_LIMIT)) k " +
                "JOIN movies m ON m.id = k.id WHERE m.title LIKE ? " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            [.string("%\(q)%"), .int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true,
                    derived: "精确匹配 · 已限定最近 \(DERIVED_LIMIT) 部内")
    }

    /// ★ 精确 + 女优: `name = ?` 精确 (≤50 人) → idx_actor 回表
    private static func exactActor(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        let rows0 = try await Db.query(
            "jdb", "SELECT id FROM actors WHERE name = ? LIMIT \(ACTOR_IDS_LIMIT)",
            [.string(q)])
        let ids = rows0.compactMap { r -> String? in
            r.isNull("id") ? nil : r.s("id")
        }
        if ids.isEmpty {
            return Page(items: [], page: page, approx: true)
        }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM movies m WHERE m.id IN " +
                "(SELECT movie_id FROM movie_actors WHERE actor_id IN (\(ph))) " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            svals(ids) + [.int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true)
    }

    /// ★ 精确 + 综合: 番号形态走番号精确; 否则按 女优精确 → 标题精确 依次尝试
    private static func exactAll(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        if looksLikeNumber(q: q) {
            return try await exactNumber(cols, q, page, per, offset)
        }
        let byActor = try await exactActor(cols, q, page, per, offset)
        if !byActor.items.isEmpty {
            return byActor
        }
        return try await exactTitle(cols, q, page, per, offset)
    }

    // MARK: - 系列（§1.11 ★ P5.2）

    /// ★ 系列 (范围 chips): 无索引列 → 派生窗口内 series_name 匹配 (模板已登记)
    private static func seriesSearch(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int,
        _ exact: Bool
    ) async throws -> Page {
        let cond = exact ? "m.series_name = ?" : "m.series_name LIKE ?"
        let param = exact ? q : "%\(q)%"
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM (SELECT id FROM movies ORDER BY release_date DESC LIMIT \(DERIVED_LIMIT)) k " +
                "JOIN movies m ON m.id = k.id WHERE \(cond) " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            [.string(param), .int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true,
                    derived: "已限定最近 \(DERIVED_LIMIT) 部内系列匹配")
    }

    // MARK: - FTS 主路 + 派生兜底（§1.12 逐字）

    /// 标题搜索: FTS (多词 AND, ★ S12-P1 去 `*` + 3s 超时); 命中 0 且本地索引未就绪
    /// → 派生表 LIKE 兜底 (已就绪时不退 5000 窗口 —— 本地索引覆盖更全且已查过)
    private static func titleSearch(
        _ cols: String, _ ws: [String], _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        if !ws.isEmpty {
            let b = booleanQuery(ws)
            let rows = try await ftsQueryOrNull(
                "SELECT \(cols) FROM movies m WHERE MATCH(m.title, m.number) " +
                    "AGAINST (? IN BOOLEAN MODE) " +
                    "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
                [.string(b), .int(Int64(per)), .int(Int64(offset))])
            if rows == nil {
                perfSink?("db.fts", "TIMEOUT \(FTS_TIMEOUT_MS)ms b=\(b)")
                return localReady()
                    ? Page(items: [], page: page, approx: true, derived: FTS_TIMEOUT_NOTE)
                    : try await likeDerived(cols, ws, page, per, offset)
            }
            if let rows, !rows.isEmpty {
                return Page(items: rows, page: page, approx: true)
            }
        }
        return localReady()
            ? Page(items: [], page: page, approx: true, derived: "本地无结果")
            : try await likeDerived(cols, ws, page, per, offset)
    }

    /// 兜底: 最近 5000 部派生表内标题 LIKE。
    /// ★ S12-P1: **只在"本地索引未就绪 且 FTS 0 命中/超时"时使用** (本地索引覆盖
    /// 更全, 已就绪时不再退 5000 窗口); derived 明确标注窗口与原因。
    private static func likeDerived(
        _ cols: String, _ ws: [String], _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        let likes = ws.isEmpty ? [""] : ws
        let clauses = likes
            .map { _ in "(m.title LIKE ? OR m.origin_title LIKE ?)" }
            .joined(separator: " OR ")
        var params: [SQLValue?] = [SQLValue?]()
        for w in likes {
            params.append(.string("%\(w)%"))
            params.append(.string("%\(w)%"))
        }
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM (SELECT id FROM movies ORDER BY release_date DESC LIMIT \(DERIVED_LIMIT)) k " +
                "JOIN movies m ON m.id = k.id WHERE \(clauses) " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            params + [.int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true,
                    derived: "已限定最近 \(DERIVED_LIMIT) 部（本地索引未就绪）")
    }

    // MARK: - 女优（§1.13 逐字）

    /// 女优: name/aliases/other_name 前缀 → idx_actor IN (走 PK 回表)
    private static func actorSearch(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        let p = "\(q.lowercased())%"
        let rows0 = try await Db.query(
            "jdb",
            "SELECT id FROM actors WHERE name LIKE ? OR aliases LIKE ? OR other_name LIKE ? " +
                "LIMIT \(ACTOR_IDS_LIMIT)",
            [.string(p), .string(p), .string(p)])
        let ids = rows0.compactMap { r -> String? in
            r.isNull("id") ? nil : r.s("id")
        }
        if ids.isEmpty {
            return Page(items: [], page: page, approx: true)
        }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM movies m WHERE m.id IN " +
                "(SELECT movie_id FROM movie_actors WHERE actor_id IN (\(ph))) " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            svals(ids) + [.int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true)
    }

    // MARK: - 综合（§1.14 三路 UNION 逐字）

    /// 三路 UNION 文本（search.allSearch 与 count 的 else 分支共用同一构造, 避免漂移）
    private static func unionAll() -> String {
        "(SELECT m.id FROM movies m WHERE m.number LIKE ? ORDER BY m.number LIMIT 400) " +
            "UNION DISTINCT " +
            "(SELECT m.id FROM movies m WHERE MATCH(m.title, m.number) AGAINST (? IN BOOLEAN MODE) " +
            "ORDER BY m.release_date DESC LIMIT 400) " +
            "UNION DISTINCT " +
            "(SELECT m.id FROM movies m JOIN movie_actors ma ON ma.movie_id = m.id " +
            "JOIN actors a ON a.id = ma.actor_id WHERE a.name LIKE ? LIMIT 400)"
    }

    /// 综合: 三路 UNION DISTINCT 归并 (每路 ≤400), SQL 层去重 + 统一按时间排序。
    /// ★ S12-P1: UNION 含 FTS 路 → 整体 3s 超时; 0 命中且本地未就绪才退派生窗口
    private static func allSearch(
        _ cols: String, _ q: String, _ page: Int, _ per: Int, _ offset: Int
    ) async throws -> Page {
        let p = "\(q.lowercased())%"
        let b = booleanQuery(words(q: q))
        let union = unionAll()
        let ids = try await ftsQueryOrNull(
            "SELECT id FROM (\(union)) u ORDER BY id LIMIT 1600",
            [.string(p), .string(b), .string(p)])
        if ids == nil {
            perfSink?("db.fts", "TIMEOUT(all) \(FTS_TIMEOUT_MS)ms b=\(b)")
            return Page(items: [], page: page, approx: true, derived: FTS_TIMEOUT_NOTE)
        }
        if ids!.isEmpty {
            // 全路 0 命中 → 本地未就绪时派生表 LIKE 兜底 (已就绪: 本地已查过且更全)
            if localReady() {
                return Page(items: [], page: page, approx: true, derived: "本地无结果")
            }
            return try await likeDerived(cols, words(q: q), page, per, offset)
        }
        // ids 已去重; 取列 + 排序分页
        let idList = ids!.map { $0.s("id") }
        return try await pagedByIds(cols, idList, page, per, offset, nil)
    }

    /// id 集合 → 按时间排序分页 (IN 走 PK; 集合 ≤1600)
    private static func pagedByIds(
        _ cols: String, _ ids: [String], _ page: Int, _ per: Int, _ offset: Int,
        _ derived: String?
    ) async throws -> Page {
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try await Db.query(
            "jdb",
            "SELECT \(cols) FROM movies m WHERE m.id IN (\(ph)) " +
                "ORDER BY m.release_date DESC, m.id DESC LIMIT ? OFFSET ?",
            svals(ids) + [.int(Int64(per)), .int(Int64(offset))])
        return Page(items: rows, page: page, approx: true, derived: derived)
    }

    // MARK: - 异步计数（§1.15 逐字; VM 渲染结果后调用）

    /// 精确 COUNT, 与 [search] 同构 (UNION/前缀/FTS 全部走索引)。
    /// 失败 -1（计数失败不阻塞, UI 显示"已加载 N 条"）; 空查询 → 0。
    /// throws 为名义声明（对齐 Q.searchCount 委托签名; 实际全部内吞 → -1, 绝不上抛）。
    public static func count(q: String, scope: String) async throws -> Int64 {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return 0 }
        let lower = query.lowercased()
        do {
            switch scope {
            case "number", "letter":
                return try await Db.scalar(
                    "jdb",
                    "SELECT COUNT(*) FROM movies m WHERE m.number LIKE ?",
                    [.string(lower + "%")])

            case "title":
                let ws = words(q: query)
                if !ws.isEmpty {
                    let n = try await Db.scalar(
                        "jdb",
                        "SELECT COUNT(*) FROM movies m WHERE " +
                            "MATCH(m.title, m.number) AGAINST (? IN BOOLEAN MODE)",
                        [.string(booleanQuery(ws))])
                    if n > 0 { return n }
                }
                return await likeDerivedCount(ws.isEmpty ? [""] : ws)

            case "actor":
                let p = lower + "%"
                let rows0 = try await Db.query(
                    "jdb",
                    "SELECT id FROM actors WHERE name LIKE ? OR aliases LIKE ? OR other_name LIKE ? " +
                        "LIMIT \(ACTOR_IDS_LIMIT)",
                    [.string(p), .string(p), .string(p)])
                let ids = rows0.compactMap { r -> String? in
                    r.isNull("id") ? nil : r.s("id")
                }
                if ids.isEmpty { return 0 }
                let ph = ids.map { _ in "?" }.joined(separator: ",")
                return try await Db.scalar(
                    "jdb",
                    "SELECT COUNT(*) FROM movies m WHERE m.id IN " +
                        "(SELECT movie_id FROM movie_actors WHERE actor_id IN (\(ph)))",
                    svals(ids))

            case "tag":
                guard let tid = tagId(t: query) else { return 0 }
                return try await Db.scalar(
                    "jdb",
                    "SELECT COUNT(*) FROM movies m WHERE m.id IN " +
                        "(SELECT movie_id FROM movie_tags WHERE tag_id = ?)",
                    [.string(tid)])

            default:
                let p = lower + "%"
                let b = booleanQuery(words(q: query))
                let union = unionAll()
                let n = try await Db.scalar(
                    "jdb",
                    "SELECT COUNT(*) FROM (\(union)) u",
                    [.string(p), .string(b), .string(p)])
                if n > 0 { return n }
                return await likeDerivedCount(words(q: query).isEmpty ? [""] : words(q: query))
            }
        } catch {
            return -1   // 计数失败不阻塞, UI 显示"已加载 N 条"
        }
    }

    /// 派生窗口计数（与 likeDerived 同窗同构; 自吞异常 → -1）
    private static func likeDerivedCount(_ likes: [String]) async -> Int64 {
        do {
            let clauses = likes
                .map { _ in "(m.title LIKE ? OR m.origin_title LIKE ?)" }
                .joined(separator: " OR ")
            var params: [SQLValue?] = [SQLValue?]()
            for w in likes {
                params.append(.string("%\(w)%"))
                params.append(.string("%\(w)%"))
            }
            return try await Db.scalar(
                "jdb",
                "SELECT COUNT(*) FROM (SELECT id FROM movies ORDER BY release_date DESC LIMIT \(DERIVED_LIMIT)) k " +
                    "JOIN movies m ON m.id = k.id WHERE \(clauses)",
                params)
        } catch {
            return -1
        }
    }

    // MARK: - FTS 3s 超时（withTimeoutOrNull 等价）

    /// FTS 竞速结果
    private enum FtsRaceOutcome {
        case rows([Row])
        case timedOut
    }

    /// Android `kotlinx.coroutines.withTimeoutOrNull(FTS_TIMEOUT_MS) { Db.query(...) }` 等价:
    /// 查询与 3s 定时器竞速（TaskGroup; 参考 MySQLPool 的 OneShot/raceTimeout 语义）。
    /// 超时 → nil（调用方走回退链/超时文案）; 查询异常向上抛（withTimeoutOrNull 只吞超时,
    /// 不吞业务异常）; 父任务取消 → CancellationError 向上传。
    private static func ftsQueryOrNull(
        _ sql: String, _ params: [SQLValue?]
    ) async throws -> [Row]? {
        let ns = UInt64(FTS_TIMEOUT_MS) * 1_000_000
        return try await withThrowingTaskGroup(of: FtsRaceOutcome.self) { group in
            group.addTask { .rows(try await Db.query("jdb", sql, params)) }
            group.addTask {
                try await Task.sleep(nanoseconds: ns)
                return .timedOut
            }
            var winner: FtsRaceOutcome?
            var failure: Error?
            while winner == nil && failure == nil {
                do {
                    if let got = try await group.next() {
                        winner = got
                    } else {
                        break
                    }
                } catch {
                    failure = error
                }
            }
            group.cancelAll()
            _ = try? await group.waitForAll()   // 收尾: 败者/被取消方的错误丢弃
            if let failure {
                throw failure
            }
            switch winner {
            case .rows(let rows): return rows
            case .timedOut, .none: return nil
            }
        }
    }

    // MARK: - 参数小工具

    /// [String] → [SQLValue?]（IN 占位参数, 与 Android 传字符串形态一致）
    private static func svals(_ ss: [String]) -> [SQLValue?] {
        ss.map { s -> SQLValue? in .string(s) }
    }
}
