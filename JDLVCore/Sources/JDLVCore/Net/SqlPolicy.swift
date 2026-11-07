import Foundation

/// 远程 SQL 准入（对齐 Android core/net/SqlPolicy.kt）。
/// 所有发往远程 MySQL 的 SQL 必须能匹配到登记模板（首个完全匹配生效）。
/// 归一化：空白折叠 → trim → 小写；模板按小写书写；整串完全匹配。
public enum SqlPolicy {
    public static let TAG = "jdlv-sqlwarn"

    /// 未登记 SQL 拒绝执行（与 Android 一致：enforce 恒为 true，无 debug/release 分支）。
    /// R9/R7：收为私有常量 + 仅测试注入点 —— 运行期不可被随意改写（生产 SQL 准入不可绕过）。
    private static var _enforce = true

    /// 只读视图（guard_/check 使用）
    public static var enforce: Bool { _enforce }

    /// 仅测试可见注入点（Core 集成测试基建用例 / App 冒烟 fixture 准备）；
    /// Release 构建为 no-op，生产 SQL 准入恒开启。
    public static func setEnforceForTesting(_ v: Bool) {
        #if DEBUG
        _enforce = v
        #else
        _ = v
        #endif
    }

    public struct SqlPolicyViolation: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    struct Entry {
        let id: String
        let pattern: NSRegularExpression
        let kind: String
        let note: String
    }

    static var entries: [Entry] = { build() }()

    private static let warnLock = NSLock()
    private static var lastWarn: [String: Int64] = [:]
    static let WARN_INTERVAL_MS: Int64 = 30_000

    /// 可注入日志（App 层用 os.Logger；Core 保持 Foundation-only）
    public static var logSink: ((String) -> Void)?

    /// Perf.sql 协议：空白折叠（不 trim 不转小写），超 120 字符截断 + "…"
    public static func perfSql(_ sql: String) -> String {
        let collapsed = sql.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count > 120 {
            return String(collapsed.prefix(120)) + "…"
        }
        return collapsed
    }

    /// 校验一条即将执行的远程 SQL。
    /// 返回 nil = 合规；否则违规原因（enforce 时同时抛出）。
    public static func check(_ which: String, _ sql: String) -> String? {
        let s = sql
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        for e in entries {
            let range = NSRange(s.startIndex..., in: s)
            if e.pattern.firstMatch(in: s, options: [], range: range) != nil {
                return e.kind == "legacy" ? "legacy·\(e.id): \(e.note)" : nil
            }
        }
        return "未登记 (未匹配任何模板)"
    }

    /// 执行前调用：违规 → 打 jdlv-sqlwarn（30s 去重）；enforce=true → 拒绝执行
    public static func guard_(_ which: String, _ sql: String) throws {
        guard let v = check(which, sql) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let key = "\(which):\(v)"
        var shouldLog = false
        warnLock.lock()
        let last = lastWarn[key]
        if last == nil || now - last! > WARN_INTERVAL_MS {
            lastWarn[key] = now
            shouldLog = true
        }
        warnLock.unlock()
        if shouldLog {
            logSink?("[\(which)] \(v) :: \(perfSql(sql))")
        }
        if enforce {
            throw SqlPolicyViolation("[\(which)] \(v)")
        }
    }

    // MARK: - 模板编译

    private static func reg(_ id: String, _ pattern: String, _ kind: String, _ note: String)
        -> Entry {
        let anchored = "^(" + pattern + ")$"
        let re = try! NSRegularExpression(
            pattern: anchored,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        return Entry(id: id, pattern: re, kind: kind, note: note)
    }

    private static func build() -> [Entry] {
        [
            // admin / probe
            reg("admin.ping", #"select 1"#, "probe", "连接探测"),
            reg("admin.schema", #"select table_name t from information_schema\.tables where table_schema = database\(\)"#, "probe", "结构探测"),
            reg("admin.columns", #"show columns from .*"#, "probe", "列探测"),
            reg("admin.explain", #"explain select .*"#, "probe", "执行计划估算"),
            reg("admin.tablerows", #"select table_rows from information_schema\.tables where table_schema = database\(\) and table_name = (\?|'.*')"#, "probe", "行数估算"),
            reg("probe.shtimg", #"select url from (sht_)?thread_images where url like 'http%' limit 5"#, "probe", "镜像嗅探 (启动期一次, LIMIT 5)"),
            // jdb 首页
            reg("jdb.home.recent", #"select .* from movies m order by release_date desc limit 12"#, "idx", "idx_release"),
            reg("jdb.home.hot", #"select .* from movies m order by want_watch_count desc limit 12"#, "idx", "idx_want"),
            reg("jdb.home.top", #"select .* from rankings_top250 r join movies m on m\.id = r\.movie_id order by r\.`rank` limit 12"#, "small", "top250 小表关联"),
            reg("jdb.home.recent2", #"select .* from movies m order by release_date desc limit \?"#, "idx", "首页最近更新 (per 参数化)"),
            reg("jdb.home.hot2", #"select .* from movies m order by want_watch_count desc limit \?"#, "idx", "首页最多想看 (per 参数化)"),
            reg("jdb.home.top2", #"select .* from rankings_top250 r join movies m on m\.id = r\.movie_id order by r\.`rank` limit \?"#, "small", "首页 TOP250 (per 参数化)"),
            reg("jdb.top250.page", #"select .* from rankings_top250 r join movies m on m\.id = r\.movie_id( where m\.year = \?)? order by r\.`rank` limit \? offset \?"#, "small", "TOP250 完整页 (年份筛选)"),
            reg("jdb.top250.count", #"select count\(\*\) c from rankings_top250 r join movies m on m\.id = r\.movie_id( where m\.year = \?)?"#, "small", "TOP250 计数 (年份筛选)"),
            reg("jdb.top250.years", #"select m\.year, count\(\*\) c from rankings_top250 r join movies m on m\.id = r\.movie_id group by m\.year order by m\.year desc"#, "small", "TOP250 年份分布"),
            // jdb 搜索
            reg("jdb.search.number", #"select .* from movies m where m\.number like \? order by m\.number(, m\.id)?( asc)?( desc)? limit \? offset \?"#, "idx", "idx_movies_number 前缀"),
            reg("jdb.search.fts", #"select .* from movies m where match\(m\.title, m\.number\) against \(.* order by .* limit \? offset \?"#, "fts", "ftx_movies BOOLEAN"),
            reg("jdb.search.derived", #"select .* from \(select id from movies order by release_date desc limit \d+\) k join movies m on m\.id = k\.id( where .*)? order by .* limit \? offset \?"#, "derived", "最近 N 部派生表内二次运算"),
            reg("jdb.search.actor.ids", #"select id from actors where name like \? or aliases like \? or other_name like \? limit \d+"#, "prefix", "女优名前缀 (≤50 人)"),
            reg("jdb.search.actor.movies", #"select .* from movies m where m\.id in \(select movie_id from movie_actors where actor_id in \(.+\)\) order by .* limit \? offset \?"#, "idx", "idx_actor IN + PK 回表"),
            reg("jdb.search.tag.movies", #"select .* from movies m where m\.id in \(select movie_id from movie_tags where tag_id = \?\) order by .* limit \? offset \?"#, "idx", "idx_tag IN + PK 回表"),
            reg("jdb.search.all.union", #"select id from \(\(select m\.id from movies m where m\.number like \? order by m\.number limit \d+\) union distinct \(select m\.id from movies m where match\(m\.title, m\.number\) against \(.* union distinct \(select m\.id from movies m join movie_actors ma on ma\.movie_id = m\.id join actors a on a\.id = ma\.actor_id where a\.name like \? limit \d+\)\) u( order by id)?( limit \d+)?"#, "derived", "三路 UNION 归并 (每路 ≤400)"),
            reg("jdb.search.byids", #"select .* from movies m where m\.id in \(.+\) order by .* limit \? offset \?"#, "pk", "PK IN (≤1600) + 小集合排序"),
            // jdb 搜索/浏览 异步计数
            reg("jdb.count.number", #"select count\(\*\) from movies m where m\.number like \?"#, "count", "idx_movies_number 范围计数"),
            reg("jdb.count.fts", #"select count\(\*\) from movies m where match\(m\.title, m\.number\) against \(.*"#, "count", "FTS 计数"),
            reg("jdb.count.actor", #"select count\(\*\) from movies m where m\.id in \(select movie_id from movie_actors where actor_id in \(.+\)\)"#, "count", "idx_actor 计数"),
            reg("jdb.count.tag", #"select count\(\*\) from movies m where m\.id in \(select movie_id from movie_tags where tag_id = \?\)"#, "count", "idx_tag 计数"),
            reg("jdb.count.union", #"select count\(\*\) from \(.*union distinct.*\) u"#, "count", "UNION 归并计数"),
            reg("jdb.count.derived", #"select count\(\*\) from \(select id from movies order by release_date desc limit \d+\) k join movies m on m\.id = k\.id( where .*)?"#, "count", "派生表内计数"),
            reg("jdb.count.month.derived", #"select count\(\*\) from \(select id from movies order by release_date desc limit \d+\) k join movies m on m\.id = k\.id where substr\(m\.release_date, 6, 2\) = \?"#, "derived", "仅月计数与列表同派生窗口"),
            reg("jdb.count.filtered", #"select count\(\*\) from movies m where .*"#, "count", "异步计数 (走索引筛选; magnet 等无索引列可接受, 已延后)"),
            // jdb 浏览
            reg("jdb.browse.list", #"select .* from movies m( where .*)? order by (m\.release_date desc, m\.id desc|m\.want_watch_count desc, m\.id desc|m\.number asc, m\.id asc) limit \? offset \?"#, "idx", "索引列排序 + keyset/OFFSET≤5000"),
            reg("jdb.browse.derived", #"select .* from \(select id from movies order by release_date desc limit \d+\) k join movies m on m\.id = k\.id( where .*)? order by .* limit \? offset \?"#, "derived", "无索引排序 → 派生表截断 5000"),
            reg("jdb.browse.list2", #"select .* from movies m( where .*)? order by (m\.(release_date|updated_at|score|want_watch_count|id)( asc| desc)?(, m\.(reviews_count|id)( asc| desc)?)*)+ limit \? offset \?"#, "idx", "白名单排序 × 正倒序 + keyset/OFFSET≤5000"),
            reg("jdb.browse.single.tagids", #"select .* from movies m where m\.id in \(select movie_id from movie_tags where tag_id in \(\?.*\)\) order by .* limit \? offset \?"#, "idx", "单体 tag_id IN (idx_tag)"),
            reg("jdb.actor.movies.sort", #"select .* from movies m join movie_actors ma on ma\.movie_id = m\.id where ma\.actor_id = \?( and .*)? order by (m\.(release_date|updated_at|score|id)( asc| desc)?(, m\.(reviews_count|id)( asc| desc)?)*)+ limit \? offset \?"#, "idx", "女优影片排序 × 正倒序 (含标签子查询)"),
            reg("jdb.actor.tags", #"select tag_id id, max\(tag_name\) name, count\(\*\) c from movie_tags where movie_id in \(select movie_id from movie_actors where actor_id = \?\) group by tag_id order by c desc, tag_id asc limit \d+"#, "idx", "女优影片标签聚合 (按 tag_id 去重)"),
            reg("jdb.actor.tags.page", #"select tag_id id, max\(tag_name\) name, count\(\*\) c from movie_tags where movie_id in \(select movie_id from movie_actors where actor_id = \?\) group by tag_id order by c desc, tag_id asc limit \? offset \?"#, "idx", "女优标签聚合分页 (按 tag_id 去重)"),
            reg("jdb.actor.tags.count", #"select count\(distinct tag_id\) c from movie_tags where movie_id in \(select movie_id from movie_actors where actor_id = \?\)"#, "idx", "女优标签总数 (DISTINCT idx_actor 路径)"),
            // 影子库预热
            reg("shadow.warm.jdb", #"select id, number, title, release_date, score, magnets_count, want_watch_count, cover_url, year, number_letter from movies m order by release_date desc limit \? offset \?"#, "idx", "idx_release 分批预热"),
            reg("shadow.warm.sht", #"select .* from (sht_)?threads order by tid desc limit \? offset \?"#, "idx", "PK 分批预热"),
            reg("shadow.warm.jdb2", #"select id, number, title, release_date, year, score, want_watch_count, magnets_count, number_letter from movies m order by release_date desc limit \? offset \?"#, "idx", "索引预热 (无 cover_url)"),
            // 预热引擎 v2
            reg("shadow.warm.movies.head", #"select .* from movies m order by m\.release_date desc, m\.id desc limit \d+"#, "idx", "v2 头部增量 1000 行 (idx_release)"),
            reg("shadow.warm.movies.tail", #"select .* from movies m where m\.release_date < \? order by m\.release_date desc, m\.id desc limit \?"#, "idx", "v2 尾段 keyset (idx_release)"),
            reg("shadow.warm.movies.same", #"select .* from movies m where m\.release_date = \? and m\.id < \? order by m\.id desc limit \?"#, "idx", "v2 同日余量 (同日最多 1392 部)"),
            reg("shadow.warm.movies.null.first", #"select .* from movies m where \(m\.release_date is null or m\.release_date = ''\) order by m\.id desc limit \?"#, "idx", "v2 无日期尾段首次 (id 序)"),
            reg("shadow.warm.movies.null.tail", #"select .* from movies m where \(m\.release_date is null or m\.release_date = ''\) and m\.id < \? order by m\.id desc limit \?"#, "idx", "v2 无日期尾段 keyset"),
            reg("shadow.warm.threads.first", #"select .* from (sht_)?threads order by tid desc limit \?"#, "idx", "v2 98t 首批 (PK 序)"),
            reg("shadow.warm.threads", #"select .* from (sht_)?threads where tid < \? order by tid desc limit \?"#, "idx", "v2 98t keyset (PK)"),
            reg("shadow.warm.actors", #"select .* from actors( where id < \?)? order by id desc limit \?"#, "idx", "v2 女优 keyset (PK)"),
            reg("shadow.warm.links", #"select movie_id, actor_id from movie_actors where movie_id in \(.+\)"#, "idx", "v2 出演关系批量 (PK 前缀 IN ≤500)"),
            reg("shadow.warm.tags", #"select movie_id, tag_id from movie_tags where movie_id in \(.+\)"#, "idx", "v3 标签关系批量 (PK 前缀 IN ≤500)"),
            // jdb 筛选数据
            reg("jdb.filters.years", #"select year, count\(\*\) c from movies where year is not null group by year order by year desc limit \d+"#, "idx", "idx_year loose scan"),
            reg("jdb.filters.letters", #"select number_letter letter, count\(\*\) c from \(select number_letter from movies order by release_date desc limit \d+\) k where number_letter is not null group by number_letter order by c desc limit \d+"#, "derived", "最近 2 万部内聚合"),
            reg("jdb.filters.makers", #"select maker_id id, maker_name name, count\(\*\) c from \(select maker_id, maker_name from movies order by release_date desc limit \d+\) k where maker_id is not null group by maker_id, maker_name order by c desc limit \d+"#, "derived", "最近 2 万部内聚合"),
            // jdb 详情
            reg("jdb.movie.main", #"select .* from movies where id = \?"#, "pk", "movies PK"),
            reg("jdb.movie.tags", #"select tag_id, tag_name from movie_tags where movie_id = \?"#, "idx", "PK(movie_id,tag_id) 前缀"),
            reg("jdb.movie.actors", #"select actor_id, actor_name from movie_actors where movie_id = \?"#, "idx", "PK(movie_id,actor_id) 前缀"),
            reg("jdb.movie.magnets", #"select hash, name, size, cnsub, hd, files_count, created_at from magnets where movie_id = \?"#, "idx", "idx_mmovie"),
            reg("jdb.movie.previews", #"select url from movie_images where movie_id = \? and kind='preview'"#, "idx", "uq_mi 前缀"),
            // jdb 女优
            reg("jdb.actors.page", #"select .* from actors( where .*)? order by .* limit \? offset \?"#, "sort", "10 万行 filesort ~1.3s (已登记临时态, S3 影子库消除)"),
            reg("jdb.actors.count", #"select count\(\*\) from actors( where .*)?"#, "count", "异步计数 (merged_into 过滤 ~100ms)"),
            reg("jdb.actor.main", #"select \* from actors where id = \?"#, "pk", "actors PK"),
            reg("jdb.actor.count", #"select count\(\*\) from movie_actors where actor_id = \?"#, "idx", "idx_actor"),
            reg("jdb.actor.count.tagged", #"select count\(\*\) from movie_actors ma join movies m on m\.id = ma\.movie_id where ma\.actor_id = \? and m\.id in \(select movie_id from movie_tags where tag_id = \?\)"#, "idx", "女优影片计数 (含标签子查询)"),
            reg("jdb.actor.movies", #"select .* from movies m join movie_actors ma on ma\.movie_id = m\.id where ma\.actor_id = \? order by m\.release_date desc limit \? offset \?"#, "idx", "idx_actor + PK 回表"),
            // sht 分类聚合
            reg("sht.cat.subs", #"select board main, board_name name, count\(\*\) c from \(select board, board_name from (sht_)?threads order by tid desc limit \d+\) k where .* group by board, board_name"#, "derived", "最近 2 万帖聚合 (~200ms)"),
            reg("sht.cat.cats", #"select cat_name name, count\(\*\) c from \(select cat_name from (sht_)?threads order by tid desc limit \d+\) k where .* group by cat_name( order by c desc)?"#, "derived", "派生表聚合"),
            reg("sht.cat.types", #"select board_name sub, `type` name, count\(\*\) c from \(select board_name, `type` from (sht_)?threads order by tid desc limit \d+\) k where .* group by board_name, `type`"#, "derived", "派生表聚合"),
            // sht 列表/搜索
            reg("sht.list.page", #"select .* from (sht_)?threads t( where .*)? order by (t\.)?(post_date|last_checked) desc, (t\.)?tid desc limit \? offset \?"#, "idx", "idx_date 索引序扫描+过滤 / FTS 后过滤"),
            reg("sht.list.derived", #"select .* from \(select tid from (sht_)?threads order by tid desc limit \d+\) k join (sht_)?threads t on t\.tid = k\.tid( where .*)? order by .* limit \? offset \?"#, "derived", "updated 排序/单字 → 最近 2 万帖窗口"),
            reg("sht.count.page", #"select count\(\*\) from (sht_)?threads t( where .*)?"#, "count", "异步计数"),
            reg("sht.count.derived", #"select count\(\*\) from \(select tid from (sht_)?threads order by tid desc limit \d+\) k join (sht_)?threads t on t\.tid = k\.tid( where .*)?"#, "count", "派生表内计数"),
            reg("sht.detail.main", #"select \* from (sht_)?threads where tid = \?"#, "pk", "threads PK"),
            reg("sht.detail.magnets", #"select hash, name, size, first_seen, link from (sht_)?magnets where tid = \?"#, "idx", "magnets PK(tid)"),
            reg("sht.detail.ed2k", #"select url, name, size, first_seen from (sht_)?thread_ed2k where tid = \?"#, "idx", "ed2k PK(tid,url) 前缀"),
            reg("sht.detail.images", #"select url from (sht_)?thread_images where tid = \?"#, "idx", "PK(tid,url) 前缀"),
            reg("sht.detail.videos", #"select url from (sht_)?thread_videos where tid = \?"#, "idx", "videos PK(tid,url) 前缀"),
            reg("sht.covers", #"select tid, min\(url\) url from (sht_)?thread_images where tid in \(.+\) group by tid"#, "idx", "PK(tid,url) 前缀 IN"),
            // sht 语义
            reg("sht.sem.cand", #"select tid from (sht_)?threads( where .*)? order by post_date desc limit \?"#, "idx", "idx_date 候选 (不 JOIN)"),
            reg("sht.sem.emb", #"select tid, emb from sht_thread_embs where tid in \(.+\)"#, "pk", "PK IN 二进制拉取"),
            reg("sht.sem.fp", #"select .* from (sht_)?sem_meta limit 1"#, "probe", "模型指纹探测"),
            // sht 导出
            reg("sht.export.page", #"select t\.tid, t\.title, t\.post_date, t\.board_name from (sht_)?threads t( where .*)? order by t\.post_date desc limit \? offset \?"#, "idx", "MATCH/索引筛选 + LIMIT 分批"),
            reg("sht.export.magnets", #"select tid, hash, size from (sht_)?magnets where tid in \(.+\)"#, "idx", "PK(tid) IN"),
            reg("sht.export.ed2k", #"select tid, url, size from (sht_)?thread_ed2k where tid in \(.+\)"#, "idx", "PK 前缀 IN"),
            reg("sht.export.videos", #"select tid, url from (sht_)?thread_videos where tid in \(.+\)"#, "idx", "PK 前缀 IN"),
            // jdb 资讯/热评（小表）
            reg("jdb.articles.count", #"select count\(\*\) c from articles( where .*)?"#, "small", "articles ≈362 行"),
            reg("jdb.articles.page", #"select .* from articles( where .*)? order by released_at desc limit \? offset \?"#, "small", "小表"),
            reg("jdb.article.main", #"select .* from articles where id = \?"#, "pk", "articles PK"),
            reg("jdb.article.cats", #"select category_id, category_name, count\(\*\) n from articles where category_id is not null group by category_id(, category_name)? order by n desc"#, "small", "小表聚合"),
            reg("jdb.article.movies", #"select am\.movie_id, .* from article_movies am where am\.article_id = \? order by am\.position"#, "small", "关联小表"),
            reg("jdb.article.ofmovie", #"select a\.id, .* from article_movies am join articles a on a\.id = am\.article_id where am\.movie_id = \? order by a\.released_at desc"#, "small", "关联小表"),
            reg("jdb.hotreview.keys", #"select period_key from hot_reviews where period = \? group by period_key order by period_key desc"#, "small", "hot_reviews ≈4.7k 行"),
            reg("jdb.hotreview.count", #"select count\(\*\) c from hot_reviews where period = \? and period_key = \?"#, "small", "小表"),
            reg("jdb.hotreview.page", #"select rid, `rank`, .* from hot_reviews where period = \? and period_key = \? order by `rank` limit \? offset \?"#, "small", "小表"),
            // taxonomy
            reg("jdb.tax.makers", #"select id, name, videos_count c from makers order by videos_count desc limit \d+"#, "small", "makers 片商全量索引表 (抓取端产出)"),
            reg("jdb.tax.codes", #"select id, name, videos_count c from codes order by videos_count desc limit \d+"#, "small", "codes 字头全量索引表 (抓取端产出)"),
            reg("jdb.tax.tags", #"select tag_id id, tag_name name, count\(\*\) c from \(select id from movies order by release_date desc limit \d+\) k join movie_tags t on t\.movie_id = k\.id group by tag_id, tag_name order by c desc limit \d+"#, "derived", "最近 2 万部派生窗口内 movie_tags 聚合"),
            reg("jdb.movie.covers", #"select id, cover_url from movies where id in \(.+\)"#, "pk", "PK IN 批量取封面 (影子库回填, ≤1000)"),
            // 图床自检取样
            reg("img.selftest.movie", #"select id, cover_url from movies order by release_date desc limit \d+"#, "probe", "图床自检取样 (索引序 30 条)"),
            reg("img.selftest.thread", #"select tid, url from (sht_)?thread_images order by tid desc limit \d+"#, "probe", "98t 图床自检取样 (PK 序 20 条)"),
            reg("img.selftest.article", #"select content_html from articles order by released_at desc limit \d+"#, "probe", "资讯正文图取样 (小表 5 条)"),
            // P5 精确搜索 / 女优性别 / 番号直达
            reg("jdb.search.exact.number", #"select .* from movies m where m\.number = \? or m\.number like \? order by m\.release_date desc(, m\.id desc)? limit \? offset \?"#, "idx", "番号精确/前缀 (idx_movies_number)"),
            reg("jdb.actors.ids", #"select id, name(, gender)? from actors where id in \(.+\)"#, "pk", "PK IN 批量取女优 (性别)"),
            reg("jdb.actors.exact", #"select id from actors where name = \? limit \d+"#, "pk", "女优名精确匹配 (≤50 人)"),
            reg("jdb.movie.bynumber", #"select id, number(, title)? from movies where number = \? limit 1"#, "idx", "idx_movies_number 精确 (资讯正文番号直达)"),
        ]
    }
}
