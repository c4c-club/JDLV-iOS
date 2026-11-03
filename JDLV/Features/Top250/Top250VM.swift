import Foundation
import JDLVCore

//
//  Top250VM.swift —— TOP250 完整页 VM（10 §5；Android 内嵌 Top250Vm 口径）。
//
//  状态：loading/refreshing/loadingMore/error/items(nil=未首载)/total/page/per=40/
//  year/years:[Row]/viewMode/lastUpdatedAt/hasMore/refreshResult。
//
//  契约：
//  - TTL 缓存：列表 "top250:{year}:{page}" TTL 10min（读取路径 get 命中直接用；
//    force 刷新 TTL=0 绕过）；年份分布 "top250years" TTL 60min，失败不阻塞列表（只剩「全部」）。
//  - setYear：page=1、items 清空（清空 → 首载骨架）、hasMore=true、reload。
//  - hasMore = 本页条数 >= per；append 按 id 去重；total COUNT 同步真值。
//  - 列数：viewMode==1 → 1 列；否则屏宽 ≥600（或 regular）→ 3 列；否则 2 列（§5.4）。
//  - 竞态 rid；SWR（reload 保留旧 items；仅 setYear 清空）。
//  - demo 模式（仅 DEBUG）：DemoStore.top250/top250Years 注入。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol Top250DataSource {
    /// 对齐 Q.top250：返回 items/total/page/per/year
    func top250(year: String?, page: Int, per: Int) async throws -> [String: Any]
    /// Q.top250Years：失败静默回 []（不阻塞列表）
    func top250Years() async -> [Row]
}

/// 生产数据源（离线三级回落/探活全在 Q.top250 内）
struct QTop250DataSource: Top250DataSource {
    func top250(year: String?, page: Int, per: Int) async throws -> [String: Any] {
        try await Q.top250(year: year, page: page, per: per)
    }

    func top250Years() async -> [Row] { await Q.top250Years() }
}

#if DEBUG

/// demo 数据源：DemoStore.top250（40/页）+ top250Years（year/n 列）+ total 分页扫描补齐
struct DemoTop250DataSource: Top250DataSource {

    func top250(year: String?, page: Int, per: Int) async throws -> [String: Any] {
        let y = (year?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? "" : year!
        let items = DemoStore.shared.top250(year: y, page: page)
        var total = (max(1, page) - 1) * 40 + items.count
        if items.count >= 40 {
            var p = page + 1
            while true {
                let more = DemoStore.shared.top250(year: y, page: p)
                total += more.count
                if more.count < 40 { break }
                p += 1
            }
        }
        return ["items": items, "total": Int64(total), "page": page, "per": 40,
                "year": y]
    }

    func top250Years() async -> [Row] { DemoStore.shared.top250Years() }
}

#endif

// MARK: - 逐字文案（10 §5）

enum Top250Copy {

    /// 顶栏标题
    static let title = "🏆 TOP250"
    /// 副标题（全角冒号；year 空 → 全部；"年"紧跟年份无空格）
    static func subtitle(total: Int64, year: String) -> String {
        "共 \(total) 部 · 当前：\(year.isEmpty ? "全部" : "\(year)年")"
    }
    /// 「全部」年份 chip（year=""）
    static let allYears = "全部"
    /// 年份 chip 文案："{年份} ({条数})"
    static func yearChip(_ year: String, _ count: Int64) -> String {
        "\(year) (\(count))"
    }
    /// 空态
    static let emptyText = "该年份 TOP250 无数据"
}

// MARK: - Top250VM

@MainActor
final class Top250VM: ObservableObject {

    // MARK: 依赖（可注入）

    let source: Top250DataSource
    /// 列表 TTL 缓存（get 命中直接用；TTL 10min；put 供 stale 兜底）
    let cache: BrowseCacheStore
    /// 年份分布缓存（TTL 60min）
    let yearsCache: BrowseCacheStore
    weak var store: SettingsStore?
    var onToast: (String) -> Void
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    init(
        source: Top250DataSource? = nil,
        cache: BrowseCacheStore = MemoryBrowseCache.shared,
        yearsCache: BrowseCacheStore = MemoryBrowseCache.shared,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoTop250DataSource() : QTop250DataSource())
        #else
        self.source = source ?? QTop250DataSource()
        #endif
        self.cache = cache
        self.yearsCache = yearsCache
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    static func makeDefault() -> Top250VM { Top250VM() }

    // MARK: 状态

    @Published var loading = false
    @Published var refreshing = false
    @Published var loadingMore = false
    @Published var error: String? = nil
    @Published var items: [Row]? = nil
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var per = 40
    /// 当前年份（"" = 全部）
    @Published var year = ""
    /// 年份分布（m.year/c；失败不阻塞列表 → 只剩「全部」）
    @Published var years: [Row] = []
    /// 列数（viewMode==1 → 1 列；来自设置）
    @Published var viewMode = 0
    @Published var hasMore = true
    @Published var lastUpdatedAt: Int64 = 0

    let refreshChannel = RefreshResultChannel()

    private var reqId = 0

    // MARK: 纯函数（测试共用）

    /// 列表缓存键：top250:{year}:{page}（TTL 10min）
    static func cacheKey(year: String, page: Int) -> String {
        "top250:\(year):\(page)"
    }
    /// 年份分布缓存键（TTL 60min）
    static let yearsCacheKey = "top250years"

    /// 年份行 → (year, count)（Q 列 c / demo 列 n 双口径；year 空跳过由调用方处理）
    static func yearEntry(_ r: Row) -> (year: String, count: Int64) {
        let n = r.keys.contains("c") ? r.i("c") : r.i("n")
        return (r.s("year"), n)
    }

    /// 副标题（Top250Copy.subtitle 直通；独立出口供测试）
    static func subtitle(total: Int64, year: String) -> String {
        Top250Copy.subtitle(total: total, year: year)
    }

    // MARK: 生命周期

    /// bind：设置同步 viewMode；列表空 → reload；年份分布并行惰性加载
    func bind() async {
        if let s = store { viewMode = s.settings.viewMode }
        let yearsTask = Task { await loadYears() }
        if (items ?? []).isEmpty {
            await reload()
        }
        await yearsTask.value
    }

    /// 年份分布：缓存 60min → Q.top250Years() → put；失败静默（只剩「全部」）
    func loadYears() async {
        if let hit = yearsCache.get(Self.yearsCacheKey, ttlMinutes: 60),
           let ys = hit["years"] as? [Row] {
            years = ys
            return
        }
        let ys = await source.top250Years()
        years = ys
        if !ys.isEmpty {
            yearsCache.put(Self.yearsCacheKey, ["years": ys])
        }
    }

    // MARK: 查询与刷新

    func reload(force: Bool = false, keepPage: Bool = false) async {
        loading = items == nil
        refreshing = force
        error = nil
        if !keepPage { page = 1 }
        loadingMore = false
        await fetch(append: false, fromRefresh: force)
    }

    /// 下拉刷新入口（TTL 0 绕过缓存）
    func refresh() async {
        await reload(force: true)
    }

    private func fetch(append: Bool, fromRefresh: Bool) async {
        reqId += 1
        let rid = reqId
        let targetPage = append ? page + 1 : page
        let key = Self.cacheKey(year: year, page: targetPage)
        // TTL 缓存读取路径（§5.5：TTL 10min；force 刷新绕过）
        if !append,
           let hit = cache.get(key, ttlMinutes: fromRefresh ? 0 : 10),
           hit["items"] != nil {
            apply(hit, rid: rid, append: false, targetPage: targetPage, fromRefresh: false)
            return
        }
        do {
            let d = try await source.top250(
                year: year.isEmpty ? nil : year, page: targetPage, per: per)
            guard rid == reqId else { return }
            cache.put(key, d)
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

    /// apply：append 按 id 去重；hasMore=满页；refreshResult 仅手动下拉路径写入
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
        if let t = ArticlesVM.numOf(d, "total") { total = t }
        if let y = d["year"] as? String { year = y }
        hasMore = fresh.count >= max(1, per)
        lastUpdatedAt = nowMs()
        loading = false
        refreshing = false
        loadingMore = false
        if fromRefresh { refreshChannel.emit(.done(merged.count)) }
    }

    // MARK: 翻页

    func loadNext() async {
        if loading || refreshing || loadingMore { return }
        guard let it = items, !it.isEmpty else { return }
        guard hasMore else { return }
        loadingMore = true
        await fetch(append: true, fromRefresh: false)
    }

    /// goPage：本地 ceil 钳制（total 已知）；target==page 且有 items → 不动
    func goPage(_ p: Int) async {
        let target = ArticlesVM.clampGoPage(p, total: total, per: per)
        if target == page, !(items ?? []).isEmpty { return }
        page = target
        await reload(keepPage: true)
    }

    // MARK: 年份切换（§5.3：page=1、items 清空、hasMore=true、reload）

    func setYear(_ y: String) async {
        guard y != year else { return }
        year = y
        page = 1
        items = nil   // 清空 → 首载骨架
        hasMore = true
        total = 0
        await reload()
    }
}
