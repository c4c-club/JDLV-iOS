import Foundation
import JDLVCore

//
//  HotReviewsVM.swift —— 热评榜 VM（10 §4 + 14_vm_tests A.8 全契约）。
//
//  状态（A.8 HotReviewsUi 逐字段）：loading/refreshing/loadingMore/error/items(nil=未首载)/
//  total/page/per=24/period="all"/key/keys:[String]/hasData=true/lastUpdatedAt/hasMore/
//  refreshResult(RefreshResultChannel)。
//
//  契约：
//  - 空态语义（P7.2）：keys 为空 = 远程库没有热评数据 → hasData=false 明确空态（不再抛错）；
//    apply 时 hasData = m["hasData"] ?? keys.isNotEmpty()；key 从响应回填（key 空 → keys.first）。
//  - 分页同 Articles：hasMore 满页推断 + total 早停 + goPage 本地 ceil 钳制。
//  - TTL 缓存 "hot:{period}:{key}:{page}"：成功 put；不读缓存；失败 stale → ErrText/Fail。
//  - setPeriod：period=p、page=1、key/keys 清空、reload；setKey：key=k、page=1、reload。
//  - dataEpoch 自动刷新：60s 冷却（RefreshPolicy）静默。
//  - demo 模式（仅 DEBUG）：DemoStore.hotReviews 注入（keys/total 由分页扫描补齐）。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol HotReviewsDataSource {
    /// 对齐 Q.hotReviews：返回 items/total/page/per/keys/key/period/hasData
    func hotReviews(period: String, periodKey: String?, page: Int, per: Int) async throws
        -> [String: Any]
}

/// 生产数据源（keys 空不抛异常 → hasData=false，在 Q.hotReviews 内完成）
struct QHotReviewsDataSource: HotReviewsDataSource {
    func hotReviews(period: String, periodKey: String?, page: Int, per: Int) async throws
        -> [String: Any] {
        try await Q.hotReviews(period: period, periodKey: periodKey, page: page, per: per)
    }
}

#if DEBUG

/// demo 数据源：DemoStore.hotReviews + keys/total 补齐
/// （demo 表每 period 恒 2 批，period_key 形态见 DemoStore.insertHotReviews.keyFmt——
/// 纯 key 函数无随机；keys 由候选集实测过滤，DESC 排序新的在前）。
struct DemoHotReviewsDataSource: HotReviewsDataSource {

    func hotReviews(period: String, periodKey: String?, page: Int, per: Int) async throws
        -> [String: Any] {
        let keys = Self.candidateKeys(period: period)
        if keys.isEmpty {
            return ["items": [Row](), "total": Int64(0), "page": page, "per": 24,
                    "keys": [String](), "key": "", "period": period, "hasData": false]
        }
        let key = (periodKey?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            ? keys.first! : periodKey!
        let items = DemoStore.shared.hotReviews(period: period, key: key, page: page)
        // total：从本页向后扫到不足 24（demo 每批 12 行 → ≤2 次）
        var total = (max(1, page) - 1) * 24 + items.count
        if items.count >= 24 {
            var p = page + 1
            while true {
                let more = DemoStore.shared.hotReviews(period: period, key: key, page: p)
                total += more.count
                if more.count < 24 { break }
                p += 1
            }
        }
        return ["items": items, "total": Int64(total), "page": page, "per": 24,
                "keys": keys, "key": key, "period": period, "hasData": true]
    }

    /// 候选批次（keyFmt 确定性形态）→ 实测非空过滤 → DESC（新的在前）
    static func candidateKeys(period: String) -> [String] {
        let candidates: [String]
        switch period {
        case "weekly": candidates = (1...2).map { String(format: "2026-W%02d", $0) }
        case "monthly": candidates = (1...2).map { String(format: "2026-%02d", $0) }
        case "quarterly": candidates = (1...2).map { "2026-Q\($0)" }
        case "yearly": candidates = ["2026"]
        default: candidates = ["latest"]   // all / latest
        }
        return candidates
            .filter { !DemoStore.shared.hotReviews(period: period, key: $0, page: 1).isEmpty }
            .sorted(by: >)
    }
}

#endif

// MARK: - 逐字文案（10 §4）

enum HotReviewsCopy {

    /// 时间段 chips（逐字，顺序固定）
    static let periods: [(label: String, value: String)] = [
        ("全部", "all"), ("上周", "weekly"), ("月度", "monthly"),
        ("季度", "quarterly"), ("年度", "yearly"), ("最新", "latest"),
    ]
    /// 批次行首固定标签
    static let batchLabel = "批次"
    /// 空态两段式（P7.2；全角括号逐字）
    static let emptyNoData = "远程库暂无热评数据（需抓取端跑热评任务后上传）"
    static let emptyFiltered = "暂无热评"

    // 行卡（10 §4.5）
    /// 评分（非空才显示）；点赞「赞 N」0 不显示
    static func likesText(_ likes: String) -> String? {
        let t = likes.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == "0") ? nil : "赞 \(t)"
    }
    /// 次行「number · 评分 {movie_score}」（空段跳过 " · " 连接）
    static func rowSub(number: String, movieScore: String) -> String {
        var parts: [String] = []
        if !number.isEmpty { parts.append(number) }
        if !movieScore.isEmpty { parts.append("评分 \(movieScore)") }
        return parts.joined(separator: " · ")
    }

    // 弹层（10 §4.6）
    /// 标题行「#rank  title」（#与标题间两个空格；title 空则 number）
    static func sheetTitle(rank: String, title: String, number: String) -> String {
        "#\(rank)  \(title.isEmpty ? number : title)"
    }
    /// 元信息「number · 影片评分 {movie_score}」（空段跳过）
    static func sheetMeta(number: String, movieScore: String) -> String {
        var parts: [String] = []
        if !number.isEmpty { parts.append(number) }
        if !movieScore.isEmpty { parts.append("影片评分 \(movieScore)") }
        return parts.joined(separator: " · ")
    }
    /// 「评论 {score 非空 ? "{score}★" : ""} · {user_name}」——score 空时按原样保留「评论  · user」
    static func sheetCommentLine(score: String, userName: String) -> String {
        "评论 \(score.isEmpty ? "" : "\(score)★") · \(userName)"
    }
    /// 「点赞 {likes_count 空则 "0"} · {created_at 前 10 位}」
    static func sheetLikesLine(likes: String, createdAt: String) -> String {
        "点赞 \(likes.isEmpty ? "0" : likes) · \(String(createdAt.prefix(10)))"
    }
    /// 按钮
    static let copyAllButton = "复制全文"
    static let jumpMovieButton = "跳转影片详情"
    /// 复制成功 Toast
    static let copiedToast = "已复制评论全文"
    /// 全文空（SelectionContainer 内）
    static let sheetNoBody = "(无正文)"
}

// MARK: - HotReviewsVM（14 A.8）

@MainActor
final class HotReviewsVM: ObservableObject {

    // MARK: 依赖（可注入）

    let source: HotReviewsDataSource
    let cache: BrowseCacheStore
    weak var store: SettingsStore?
    var onToast: (String) -> Void
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    init(
        source: HotReviewsDataSource? = nil,
        cache: BrowseCacheStore = MemoryBrowseCache.shared,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoHotReviewsDataSource() : QHotReviewsDataSource())
        #else
        self.source = source ?? QHotReviewsDataSource()
        #endif
        self.cache = cache
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    static func makeDefault() -> HotReviewsVM { HotReviewsVM() }

    // MARK: 状态（A.8 逐字段）

    @Published var loading = false
    @Published var refreshing = false
    @Published var loadingMore = false
    @Published var error: String? = nil
    @Published var items: [Row]? = nil
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var per = 24
    @Published var period = "all"
    /// 当前批次（响应回填；key 空 → keys.first）
    @Published var key = ""
    /// 历史批次（新在前）；空 = 远程库无该时间段数据
    @Published var keys: [String] = []
    /// keys 为空 = 远程库没有热评数据（P7.2 明确空态，不再抛错）
    @Published var hasData = true
    @Published var hasMore = true
    @Published var lastUpdatedAt: Int64 = 0

    let refreshChannel = RefreshResultChannel()

    private var reqId = 0
    private var seenEpoch: Int = -1
    private var lastAutoAt: Int64 = 0

    // MARK: 纯函数（测试共用）

    /// 列表缓存键：hot:{period}:{key}:{page}
    static func cacheKey(period: String, key: String, page: Int) -> String {
        "hot:\(period):\(key):\(page)"
    }

    /// goPage 本地钳制（同 Articles：ceil(total/per)，per<=0 按 1）
    static func clampGoPage(_ p: Int, total: Int64, per: Int) -> Int {
        var target = max(1, p)
        if total > 0 {
            let maxPage = max(1, Int(ceil(Double(total) / Double(max(per, 1)))))
            target = min(target, maxPage)
        }
        return target
    }

    // MARK: 生命周期

    /// bind：列表空 → reload
    func bind() async {
        if (items ?? []).isEmpty {
            await reload()
        }
    }

    /// dataEpoch 变更：60s 冷却静默刷新
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

    func reload(force: Bool = false, keepPage: Bool = false, auto: Bool = false) async {
        loading = items == nil
        refreshing = force
        error = nil
        if !keepPage { page = 1 }
        loadingMore = false
        await fetch(append: false, fromRefresh: force && !auto)
    }

    /// 下拉刷新入口
    func refresh() async {
        await reload(force: true)
    }

    private func fetch(append: Bool, fromRefresh: Bool) async {
        reqId += 1
        let rid = reqId
        let targetPage = append ? page + 1 : page
        let key = Self.cacheKey(period: period, key: self.key, page: targetPage)
        do {
            let d = try await source.hotReviews(
                period: period, periodKey: self.key.isEmpty ? nil : self.key,
                page: targetPage, per: per)
            guard rid == reqId else { return }
            cache.put(key, d)   // 只 put 不 get（失败 stale 兜底）
            apply(d, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
        } catch {
            guard rid == reqId else { return }
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

    /// apply：keys 空 → hasData=false 明确空态；key 从响应回填；append 按 rid 去重
    private func apply(
        _ d: [String: Any], rid: Int, append: Bool, targetPage: Int, fromRefresh: Bool
    ) {
        guard rid == reqId else { return }
        let fresh = d["items"] as? [Row] ?? []
        let prev = items ?? []
        let merged: [Row]
        if append {
            var seen = Set(prev.map { $0.s("rid") })
            merged = prev + fresh.filter { seen.insert($0.s("rid")).inserted }
        } else {
            merged = fresh
        }
        items = merged
        page = targetPage
        if let t = ArticlesVM.numOf(d, "total") { total = t }
        // P7.2：hasData = m["hasData"] ?: keys.isNotEmpty()；key 从响应回填
        if let ks = d["keys"] as? [String] { keys = ks }
        if let k = d["key"] as? String { key = k }
        if let hd = d["hasData"] as? Bool {
            hasData = hd
        } else {
            hasData = !keys.isEmpty
        }
        hasMore = fresh.count >= max(1, per)
        lastUpdatedAt = nowMs()
        loading = false
        refreshing = false
        loadingMore = false
        if fromRefresh { refreshChannel.emit(.done(merged.count)) }
    }

    // MARK: 翻页

    /// loadNext：守卫 + hasMore + total 早停（同 Articles）
    func loadNext() async {
        if loading || refreshing || loadingMore { return }
        guard let it = items, !it.isEmpty else { return }
        guard hasMore else { return }
        if total > 0 && it.count >= total { return }
        loadingMore = true
        await fetch(append: true, fromRefresh: false)
    }

    /// goPage：本地 ceil 钳制；target==page 且有 items → 不动
    func goPage(_ p: Int) async {
        let target = Self.clampGoPage(p, total: total, per: per)
        if target == page, !(items ?? []).isEmpty { return }
        page = target
        await reload(keepPage: true)
    }

    // MARK: 筛选入口（10 §4.2/§4.3）

    /// 切时间段：period=p、page=1、key/keys 清空、reload
    func setPeriod(_ p: String) async {
        guard p != period else { return }
        period = p
        page = 1
        key = ""
        keys = []
        hasData = true
        await reload()
    }

    /// 切批次：key=k、page=1、reload
    func setKey(_ k: String) async {
        guard k != key else { return }
        key = k
        await reload()
    }
}
