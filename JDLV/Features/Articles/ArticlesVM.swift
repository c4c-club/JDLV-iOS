import Foundation
import JDLVCore

//
//  ArticlesVM.swift —— 资讯列表 VM（10 §2 + 14_vm_tests A.7 全契约）+ 资讯详情 VM（10 §2.5）。
//
//  ArticlesVM 状态（A.7 ArticlesUi 逐字段）：loading/refreshing/loadingMore/error/
//  items(nil=未首载)/total/page/per=24/categoryId(Int?)/q/categories/lastUpdatedAt/
//  hasMore/refreshResult(RefreshResultChannel)。
//
//  契约：
//  - 竞态 rid：fetch 前 reqId++；apply/catch 先校验 rid != reqId → 整体丢弃。
//  - SWR：reload 保留旧 items（loading 只在 items==null 首载骨架）；refreshing 独立。
//  - 分页：loadNext 守卫 + hasMore（满页推断）+ `total>0 && items.size>=total` 早停；
//    goPage 本地 ceil(total/per) 钳制（per<=0 按 1），target==page 且有 items → 不动。
//  - TTL 缓存 "articles:{categoryId}:{q}:{page}"：成功 put；不读缓存；失败 stale 兜底
//    → ErrText / fromRefresh 时 RefreshResult.Fail。
//  - bind：列表空 → 拉分类（runCatching 静默，Q.articleCategories 失败回 []）+ reload。
//  - dataEpoch 自动刷新：60s 冷却（RefreshPolicy）静默（auto 不写 refreshResult）。
//  - demo 模式（仅 DEBUG）：DemoStore.articles 注入（补 total/分类聚合/正文 HTML 合成）。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol ArticlesDataSource {
    /// 对齐 Q.articles：返回 items/total(COUNT 同步真值)/page/per
    func articles(page: Int, per: Int, categoryId: Int?, q: String) async throws
        -> [String: Any]
    /// Q.articleCategories：失败静默回 []（内部已兜）
    func articleCategories() async -> [Row]
    /// Q.article：nil = 表缺列/无此 id
    func article(aid: String) async throws -> Row?
    /// Q.articleMovies：失败静默回 []
    func articleMovies(aid: String) async -> [Row]
    /// Q.movieByNumber：番号直达（正文可点）；nil = 未收录
    func movieByNumber(number: String) async -> Row?
}

/// 生产数据源（离线回落/探活/markOffline 全在 Q 层内）
struct QArticlesDataSource: ArticlesDataSource {
    func articles(page: Int, per: Int, categoryId: Int?, q: String) async throws
        -> [String: Any] {
        try await Q.articles(page: page, per: per, categoryId: categoryId, q: q)
    }

    func articleCategories() async -> [Row] { await Q.articleCategories() }

    func article(aid: String) async throws -> Row? { try await Q.article(aid: aid) }

    func articleMovies(aid: String) async -> [Row] { await Q.articleMovies(aid: aid) }

    func movieByNumber(number: String) async -> Row? { await Q.movieByNumber(number: number) }
}

#if DEBUG

/// demo 数据源：DemoStore.articles/article + 确定性合成（表缺 content_html/article_movies，
/// 合成规则见各方法注释；番号合成为 DemoStore 影片真实番号 → 番号可点 push movie 全链路）。
struct DemoArticlesDataSource: ArticlesDataSource {

    func articles(page: Int, per: Int, categoryId: Int?, q: String) async throws
        -> [String: Any] {
        let cid = categoryId.map(String.init) ?? ""
        let items = DemoStore.shared.articles(page: page, categoryId: cid, q: q)
        // DemoStore.articles 不回 total：从本页向后逐页扫到不足 24 为止（demo 24 条 → ≤2 次）
        var total = (max(1, page) - 1) * 24 + items.count
        if items.count >= 24 {
            var p = page + 1
            while true {
                let more = DemoStore.shared.articles(page: p, categoryId: cid, q: q)
                total += more.count
                if more.count < 24 { break }
                p += 1
            }
        }
        return ["items": items, "total": Int64(total), "page": page, "per": 24]
    }

    /// 分类聚合（10 §2.2：GROUP BY category_id ORDER BY n DESC）；demo 全量扫一页后本地聚合
    func articleCategories() async -> [Row] {
        var all: [Row] = []
        var p = 1
        while true {
            let rows = DemoStore.shared.articles(page: p, categoryId: "", q: "")
            all.append(contentsOf: rows)
            if rows.count < 24 { break }
            p += 1
        }
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for r in all {
            let id = r.s("category_id")
            guard !id.isEmpty else { continue }
            if counts[id] == nil { order.append(id) }
            names[id] = r.s("category_name")
            counts[id, default: 0] += 1
        }
        let sorted = order.sorted { l, r in
            let cl = counts[l] ?? 0, cr = counts[r] ?? 0
            return cl != cr ? cl > cr : l < r
        }
        return sorted.map { id in
            Row([
                "category_id": .string(id),
                "category_name": .string(names[id] ?? ""),
                "n": .int(Int64(counts[id] ?? 0)),
            ])
        }
    }

    /// 详情行：DemoStore.article + 合成 content_html（含真实 demo 番号 → 番号可点链路）+
    /// author → author_name 列名对齐（demo 表列名 author）
    func article(aid: String) async throws -> Row? {
        guard var r = DemoStore.shared.article(aid: aid) else { return nil }
        if r.s("author_name").isEmpty { r["author_name"] = .string(r.s("author")) }
        if r.s("content_html").isEmpty {
            let num1 = Self.demoNumber(seed: fnv1a(aid))
            let num2 = Self.demoNumber(seed: fnv1a(aid) &+ 0x9E37_79B9)
            r["content_html"] = .string(
                "<p>演示资讯正文（合成数据）。本文用于验证资讯详情的分块渲染链路。</p>" +
                    "<p>本期推荐作品 <b>\(num1)</b>，评测与访谈全文见本期杂志。</p>" +
                    "<p>同期还有 \(num2) 等作品入库，点击番号可直达影片详情页。</p>" +
                    "<p>感谢阅读，本段为第二块文本，用于验证文本/图片交替切块。</p>")
        }
        r["cover_path"] = .string("")   // demo 表无 cover_path 列
        return r
    }

    /// 相关影片：demo 无 article_movies 表 → 按 aid 哈希确定性取 2 部 demo 影片
    func articleMovies(aid: String) async -> [Row] {
        var rows: [Row] = []
        for k in 0..<2 {
            let h = fnv1a(aid) &+ UInt64(k) &* 9_973
            let idx = Int(h % UInt64(DemoStore.movieCount))
            guard let m = DemoStore.shared.movie(mid: String(100_000 + idx)) else { continue }
            rows.append(Row([
                "movie_id": .string(m.s("id")), "number": .string(m.s("number")),
                "title": .string(m.s("title")), "score": .double(m.d("score")),
                "release_date": .string(m.s("release_date")),
                "thumb_url": .string(m.s("cover_url")),
            ]))
        }
        return rows
    }

    /// 番号直达：DemoStore 影片番号规则 PREFIX-NNN（id = 100_000 + NNN - 1）定位后
    /// 用真实行校验（防跨桶误配；大小写不敏感）
    func movieByNumber(number: String) async -> Row? {
        let t = number.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let n = Int(parts[1]),
              n >= 1, n <= DemoStore.movieCount else { return nil }
        guard let m = DemoStore.shared.movie(mid: String(100_000 + n - 1)),
              m.s("number").lowercased() == t.lowercased() else { return nil }
        return Row(["id": .string(m.s("id")), "number": .string(m.s("number"))])
    }

    /// 合成正文番号：直接取一部真实 demo 影片的番号（保证番号可点 → movieByNumber →
    /// push movie 全链路；FC2 等数字前缀番号不会被番号正则命中，天然排除）
    static func demoNumber(seed: UInt64) -> String {
        let idx = Int(seed % UInt64(DemoStore.movieCount))
        return DemoStore.shared.movie(mid: String(100_000 + idx))?.s("number") ?? "ABC-001"
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}

#endif

// MARK: - 逐字文案（10 §2）

enum ArticlesCopy {
    private init() {}

    /// SearchBarCompact placeholder（逐字）
    static let searchPlaceholder = "搜索资讯标题 / 正文…"
    /// 分类 chips 首项（categoryId=nil）
    static let allCategory = "全部"
    /// 空态（ListScaffold 与 header ListStatusBlock 两处相同）
    static let emptyText = "暂无资讯 (需抓取端跑资讯任务并上传)"

    // 详情（10 §2.5）
    /// row 未加载时顶栏标题
    static let navTitleFallback = "资讯"
    /// row==null（查询成功但无此 id）
    static let notFoundText = "未找到该资讯"
    /// origin_name 字面前缀（半角冒号）
    static let originPrefix = "来源:"
    /// 去标签纯文本 <20 字且 HTML 含 <img
    static let imageMainNote = "该篇以图片为主"
    /// html 为空白
    static let noBodyText = "(无正文)"
    /// 番号未收录 Toast
    static func uncollectedNumber(_ n: String) -> String { "未收录番号 \(n)" }
    /// 关联影片块标题
    static let relatedMoviesTitle = "相关影片"
}

// MARK: - 图片 URL 归一（12 §2.4 Img.articleCover 对位；冷却/重写在 PosterImage 内完成）

enum ArticleImg {
    /// Img.articleCover：空 → ""；"//" 开头补 https:；其余走 ImgBreaker.url
    /// （guarded + jdbImgUrl 重写：external/未知路径原样，articles/ 路径自动重写 app 图床）
    static func articleCover(_ u: String) -> String {
        var s = u.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "" }
        if s.hasPrefix("//") { s = "https:" + s }
        return ImgBreaker.shared.url(s)
    }

    /// ArticleCard 无封面判定：cover_url 与 cover_path 归一后均空
    static func hasCover(coverUrl: String, coverPath: String) -> Bool {
        !articleCover(coverUrl).isEmpty || !articleCover(coverPath).isEmpty
    }
}

// MARK: - ArticlesVM（14 A.7）

@MainActor
final class ArticlesVM: ObservableObject {

    // MARK: 依赖（可注入）

    let source: ArticlesDataSource
    /// 缓存（成功 put；不读；失败 stale 兜底）
    let cache: BrowseCacheStore
    /// 设置桥（ArticlesView onAppear 注入；测试 nil）
    weak var store: SettingsStore?
    /// 全局 Toast 通道
    var onToast: (String) -> Void
    /// 可注入时钟
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    init(
        source: ArticlesDataSource? = nil,
        cache: BrowseCacheStore = MemoryBrowseCache.shared,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoArticlesDataSource() : QArticlesDataSource())
        #else
        self.source = source ?? QArticlesDataSource()
        #endif
        self.cache = cache
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    /// 页面默认构造
    static func makeDefault() -> ArticlesVM { ArticlesVM() }

    // MARK: 状态（A.7 逐字段）

    @Published var loading = false
    @Published var refreshing = false
    @Published var loadingMore = false
    @Published var error: String? = nil
    /// null = 未首载（首载骨架）；非 null 保留旧值（SWR 不闪白）
    @Published var items: [Row]? = nil
    /// COUNT 同步真值（Q.articles）
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var per = 24
    /// nil = 全部分类
    @Published var categoryId: Int? = nil
    @Published var q = ""
    @Published var categories: [Row] = []
    @Published var hasMore = true
    @Published var lastUpdatedAt: Int64 = 0

    /// 刷新结果通道（仅手动下拉路径写入；页面消费后 consume 清位）
    let refreshChannel = RefreshResultChannel()

    private var reqId = 0
    private var seenEpoch: Int = -1
    private var lastAutoAt: Int64 = 0

    // MARK: 纯函数（测试共用）

    /// 列表缓存键：articles:{categoryId}:{q}:{page}
    static func cacheKey(categoryId: Int?, q: String, page: Int) -> String {
        "articles:\(categoryId.map(String.init) ?? ""):\(q):\(page)"
    }

    /// goPage 本地钳制（A.7：maxPage = ceil(total/per)，per<=0 按 1；total<=0 只钳下界）
    static func clampGoPage(_ p: Int, total: Int64, per: Int) -> Int {
        var target = max(1, p)
        if total > 0 {
            let maxPage = max(1, Int(ceil(Double(total) / Double(max(per, 1)))))
            target = min(target, maxPage)
        }
        return target
    }

    /// 卡片元信息（10 §2.3：分类名/作者名/released_at 前 10 位/{n} 字，空段跳过 " · " 连接）
    static func cardMetaParts(_ r: Row) -> [String] {
        var parts: [String] = []
        let cat = r.s("category_name")
        if !cat.isEmpty { parts.append(cat) }
        let author = r.s("author_name")
        if !author.isEmpty { parts.append(author) }
        let released = String(r.s("released_at").prefix(10))
        if !released.isEmpty { parts.append(released) }
        let words = r.i("word_count")
        if words > 0 { parts.append("\(words) 字") }
        return parts
    }

    // MARK: 生命周期

    /// bind：列表空 → 拉分类（runCatching 静默）+ reload；否则不动
    func bind() async {
        if (items ?? []).isEmpty {
            await loadCategories()
            await reload()
        }
    }

    /// 分类（Q.articleCategories 失败回 []，永不抛错 → 静默）
    func loadCategories() async {
        categories = await source.articleCategories()
    }

    /// dataEpoch 变更：60s 冷却静默刷新（auto 不写 refreshResult）
    func onDataEpoch(_ v: Int) async {
        if v <= 0 || v == seenEpoch { return }
        if seenEpoch < 0 { seenEpoch = v; return }
        let now = nowMs()
        guard RefreshPolicy.shouldAuto(lastAutoAt, now: now) else { return }
        seenEpoch = v
        lastAutoAt = now
        await reload(force: true, auto: true)
    }

    // MARK: 查询与刷新

    /// reload：loading 仅首载骨架、refreshing=force、error 清位、
    /// page = keepPage ? 当前 : 1、items 保留（SWR 不闪白）
    func reload(force: Bool = false, keepPage: Bool = false, auto: Bool = false) async {
        loading = items == nil
        refreshing = force
        error = nil
        if !keepPage { page = 1 }
        loadingMore = false
        await fetch(append: false, fromRefresh: force && !auto)
    }

    /// 下拉刷新入口（refreshing=true + fromRefresh 写 RefreshResult）
    func refresh() async {
        await reload(force: true)
    }

    /// fetch：rid 竞态守卫 → Q 层（只 put 不 get）→ stale 兜底 → ErrText
    private func fetch(append: Bool, fromRefresh: Bool) async {
        reqId += 1
        let rid = reqId
        let targetPage = append ? page + 1 : page
        let key = Self.cacheKey(categoryId: categoryId, q: q, page: targetPage)
        do {
            let d = try await source.articles(
                page: targetPage, per: per, categoryId: categoryId, q: q)
            guard rid == reqId else { return }   // 旧响应一律丢弃
            cache.put(key, d)   // 只 put 不 get（结果缓存仅作失败 stale 兜底）
            apply(d, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
        } catch {
            guard rid == reqId else { return }
            // 失败 → stale（无视 TTL 旧缓存）→ SWR 回退；无 stale → ErrText + fromRefresh 时 Fail
            if let stale = cache.stale(key) {
                apply(stale, rid: rid, append: append, targetPage: targetPage,
                      fromRefresh: fromRefresh)
                return
            }
            loading = false
            refreshing = false
            loadingMore = false
            let msg = ErrText.of(error)
            self.error = msg
            if fromRefresh { refreshChannel.emit(.fail(msg)) }
        }
    }

    /// apply：append 按 id 去重拼接；total 同步真值直写；hasMore=满页推断；
    /// refreshResult 仅手动下拉路径写入
    private func apply(
        _ d: [String: Any], rid: Int, append: Bool, targetPage: Int, fromRefresh: Bool
    ) {
        guard rid == reqId else { return }
        let fresh = d["items"] as? [Row] ?? []
        let prev = items ?? []
        let merged: [Row]
        if append {
            var seen = Set(prev.map { $0.s("id") })
            merged = prev + fresh.filter { seen.insert($0.s("id")).inserted }
        } else {
            merged = fresh
        }
        items = merged
        page = targetPage
        if let t = Self.numOf(d, "total") { total = t }
        hasMore = fresh.count >= max(1, per)   // 按满页推断
        lastUpdatedAt = nowMs()
        loading = false
        refreshing = false
        loadingMore = false
        if fromRefresh { refreshChannel.emit(.done(merged.count)) }
    }

    /// [String: Any] 数值宽容解包（Int64/Int/Double/NSNumber → Int64）
    static func numOf(_ d: [String: Any], _ k: String) -> Int64? {
        switch d[k] {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }

    // MARK: 翻页

    /// loadNext：守卫 + hasMore + total 早停（A.7：total>0 && items.size>=total）
    func loadNext() async {
        if loading || refreshing || loadingMore { return }
        guard let it = items, !it.isEmpty else { return }
        guard hasMore else { return }
        if total > 0 && it.count >= total { return }   // 本地计数早停
        loadingMore = true
        await fetch(append: true, fromRefresh: false)
    }

    /// goPage：本地 ceil(total/per) 钳制（A.7）；target==page 且有 items → 不动
    func goPage(_ p: Int) async {
        let target = Self.clampGoPage(p, total: total, per: per)
        if target == page, !(items ?? []).isEmpty { return }
        page = target
        await reload(keepPage: true)
    }

    // MARK: 搜索 / 分类入口

    /// search（SearchBarCompact 回车提交；title LIKE / content_text LIKE 在 Q 层）
    func search(_ term: String) async {
        q = term.trimmingCharacters(in: .whitespaces)
        await reload()
    }

    /// 切分类：categoryId 写 state → page=1 → reload
    func setCategory(_ id: Int?) async {
        categoryId = id
        await reload()
    }
}

// MARK: - ArticleDetailVM（10 §2.5 资讯详情）

@MainActor
final class ArticleDetailVM: ObservableObject {

    let source: ArticlesDataSource
    var onToast: (String) -> Void

    init(source: ArticlesDataSource? = nil, onToast: ((String) -> Void)? = nil) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoArticlesDataSource() : QArticlesDataSource())
        #else
        self.source = source ?? QArticlesDataSource()
        #endif
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    static func makeDefault() -> ArticleDetailVM { ArticleDetailVM() }

    // MARK: 状态（loading → 首载转圈；error 且无 row → ErrorBox；无 error 无 row → 未找到）

    /// 初值 true（onAppear 首查前一帧不闪「未找到该资讯」）
    @Published var loading = true
    @Published var error: String? = nil
    @Published var row: Row? = nil
    /// 关联影片（Q.articleMovies；空 → 整块隐藏）
    @Published var relatedMovies: [Row] = []

    private var reqId = 0
    private(set) var loadedAid = ""

    /// load：rid 竞态守卫；同 aid 已有结果幂等；related 失败静默
    func load(aid: String) async {
        if loadedAid == aid && (row != nil || error != nil) { return }
        reqId += 1
        let rid = reqId
        loading = true
        error = nil
        do {
            let r = try await source.article(aid: aid)
            guard rid == reqId else { return }
            row = r
            loadedAid = aid
            loading = false
            let rel = await source.articleMovies(aid: aid)
            guard rid == reqId else { return }
            relatedMovies = rel
        } catch {
            guard rid == reqId else { return }
            loading = false
            self.error = ErrText.of(error)
        }
    }

    /// 番号点击：Q.movieByNumber → movie id；未收录 → Toast「未收录番号 N」+ nil
    func resolveNumber(_ number: String) async -> String? {
        let r = await source.movieByNumber(number: number)
        if let id = r?.s("id"), !id.isEmpty { return id }
        onToast(ArticlesCopy.uncollectedNumber(number))
        return nil
    }

    /// B.10 release 对位：返回销毁重置；再进 load 自动重载
    func release() {
        reqId += 1
        loadedAid = ""
        row = nil
        error = nil
        relatedMovies = []
        loading = true
    }

    /// 正文 HTML（content_html；缺列/空 → ""）
    var html: String { row?.s("content_html") ?? "" }

    /// 详情元信息（10 §2.5：分类名/作者名/来源:{origin_name}/released_at 前 10 位，空段跳过）
    static func metaParts(_ r: Row) -> [String] {
        var parts: [String] = []
        let cat = r.s("category_name")
        if !cat.isEmpty { parts.append(cat) }
        let author = r.s("author_name")
        if !author.isEmpty { parts.append(author) }
        let origin = r.s("origin_name")
        if !origin.isEmpty { parts.append("来源:\(origin)") }
        let released = String(r.s("released_at").prefix(10))
        if !released.isEmpty { parts.append(released) }
        return parts
    }

    /// 相关影片次行（10 §2.5：number · release_date，空段过滤 " · " 连接）
    static func relatedMovieSub(_ r: Row) -> String {
        var parts: [String] = []
        let number = r.s("number")
        if !number.isEmpty { parts.append(number) }
        let rd = r.s("release_date")
        if !rd.isEmpty { parts.append(rd) }
        return parts.joined(separator: " · ")
    }

    /// 封面（16:9；articleCover(cover_url 空则 cover_path)）
    var coverUrl: String {
        guard let r = row else { return "" }
        return ArticleImg.articleCover(r.s("cover_url").isEmpty
            ? r.s("cover_path") : r.s("cover_url"))
    }

    /// 灯箱 gallery = [顶部封面(若有)] + 正文可进灯箱图（外链图排除、解析为空的排除）
    var lightboxGallery: [String] {
        var g: [String] = []
        if !coverUrl.isEmpty { g.append(coverUrl) }
        g.append(contentsOf: ArticleHtml.lightboxImages(html).images)
        return g
    }

    /// 正文第 rawIndex 张（原始序）→ gallery 下标（封面偏移 1/0；被过滤 → nil）
    func galleryIndexOfBodyImage(_ rawIndex: Int) -> Int? {
        let lb = ArticleHtml.lightboxImages(html)
        guard rawIndex >= 0, rawIndex < lb.rawToFiltered.count,
              let filtered = lb.rawToFiltered[rawIndex] else { return nil }
        let offset = coverUrl.isEmpty ? 0 : 1
        return filtered + offset
    }
}
