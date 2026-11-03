import Foundation
import SwiftUI
import JDLVCore

//
//  SearchVM.swift —— 搜索 Tab VM（14_vm_tests.md A.6 SearchVm 全契约 + A.0 公共契约）。
//
//  职责：首页三段（home）+ 全库搜索（本地索引优先路由）+ 精确/模糊模式 + 跳页 +
//        同源翻页（14 A.6 / 07 C / 03 §1）。
//
//  数据源路由：SearchData 协议注入，两种模式用同一份 VM 代码：
//  - 生产：QSearchData（Q.home / Q.search / Q.searchCount）；
//  - DEBUG + demo 模式（-JDLV_DEMO 1）：DemoSearchData（DemoStore），并同时向
//    JdbSearch.idx 注入 DemoIdxSearchable → 本地索引优先 / 0 命中回落远程全链路可演示。
//
//  缓存（本阶段内存 TTL，QCache 磁盘接线 P10 后补；键表 = 07 C8 / 14 A.10）：
//  | 内容     | 键                                   | TTL                |
//  | 首页三段 | home:{per}                           | homeTtl(默认10分钟)；force=0 |
//  | 搜索页   | search:{q}:{scope}:{mode}:{p}:{per}[:L] | 10 分钟（本地来源 +":L"）|
//  | 搜索计数 | searchcount:{q}:{scope}:{useLocal}   | 10 分钟            |
//
//  文案逐字（含全角/半角标点）：「◌ 正在显示缓存数据, 后台刷新中…」
//  「⚠ 离线: 正在显示缓存的首页数据」「本地无结果，正在查远程…」（全角逗号）
//  「⚠ 离线: 显示缓存搜索结果」「跳页过深（最多约 N 页），请用滚动加载」（全角括号+全角逗号）。
//

// MARK: - 结果载体

/// Q.home 三段结果（recent/hot/top + 派生标注；Done(n) 的 n = 三段条数之和，07 C0）
struct SearchHomeResult: Equatable {
    var recent: [Row]
    var hot: [Row]
    var top: [Row]
    var derived: String

    var totalCount: Int { recent.count + hot.count + top.count }
}

/// 搜索结果页（Q.search / JdbSearch.Page 适配后；served 结构化来源标注，S14-P9）
struct SearchPageResult: Equatable {
    var items: [Row]
    var derived: String
    var served: String
}

// MARK: - 数据访问协议（生产 Q 与 DEBUG DemoStore 注入同一 VM 代码）

protocol SearchData: AnyObject {
    /// Q.home(per)（离线本地兜底在 Q 层完成）
    func home(per: Int) async throws -> SearchHomeResult
    /// Q.search(q, scope, p, per, mode)（远程路径）
    func search(q: String, scope: String, page: Int, per: Int, mode: String) async throws -> SearchPageResult
    /// Q.searchCount（失败 → -1 = 未知，UI 显示"已加载 N 条"）
    func searchCount(q: String, scope: String) async -> Int64
}

// MARK: - 内存 TTL 缓存（P9a：内存版；P10 换 QCache 磁盘）

final class SearchMemCache {
    static let shared = SearchMemCache()

    private struct Entry {
        var payload: Any
        var ts: Int64
    }

    private var map: [String: Entry] = [:]
    private let lock = NSLock()
    private let now: () -> Int64

    init(now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.now = now
    }

    func put<T>(_ payload: T, key: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = Entry(payload: payload, ts: now())
    }

    /// TTL 内命中；ttlMinutes <= 0（force）恒 miss
    func get<T>(_ type: T.Type, key: String, ttlMinutes: Int) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard ttlMinutes > 0, let e = map[key] else { return nil }
        guard now() - e.ts <= Int64(ttlMinutes) * 60_000 else { return nil }
        return e.payload as? T
    }

    /// 过期缓存兜底（SWR 三级第 2 级）
    func stale<T>(_ type: T.Type, key: String) -> T? {
        lock.lock(); defer { lock.unlock() }
        return map[key]?.payload as? T
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }
}

// MARK: - 搜索历史（UserDefaults「jdlv_search_history」，上限 10）

enum SearchHistory {
    static let storeKey = "jdlv_search_history"
    static let cap = 10

    static func load(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: storeKey) ?? []
    }

    /// 去重置顶 + 截断 10 条
    static func add(_ q: String, defaults: UserDefaults = .standard) {
        var list = load(defaults: defaults)
        list.removeAll { $0 == q }
        list.insert(q, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        defaults.set(list, forKey: storeKey)
    }
}

// MARK: - 设置读取口（VM 只读；写回由页面经 SettingsStore 完成）
// @MainActor：SettingsStore 是 MainActor 类，同步读取口须同隔离域才能作为 witness。

@MainActor
protocol SearchSettingsReading: AnyObject {
    var searchHomeTtl: Int { get }        // homeTtl（分钟，默认 10）
    var searchHomePer: Int { get }        // homePer 档位 {12,18,24,36}
    var searchPerPage: Int { get }        // perPage（默认 40）
    var searchModeRaw: Int { get }        // search_mode 0=exact 1=fuzzy
    var searchViewMode: Int { get }       // view_mode 0/1/2
    var searchSetupRequired: Bool { get } // 首启引导判定
}

extension SettingsStore: SearchSettingsReading {
    var searchHomeTtl: Int { settings.homeTtl }
    var searchHomePer: Int { settings.homePer }
    var searchPerPage: Int { settings.perPage }
    var searchModeRaw: Int { settings.searchMode }
    var searchViewMode: Int { settings.viewMode }
    var searchSetupRequired: Bool { settings.setupRequired }
}

// MARK: - 逐字文案集中点（07 C 节；全角/半角标点照抄）

enum SearchCopy {
    static let searchPlaceholder = "番号 / 标题 / 女优 / 标签…"

    // offlineNote / 来源标注（C6 / A.6；「本地无结果，正在查远程…」为全角逗号）
    static let swrNote = "◌ 正在显示缓存数据, 后台刷新中…"
    static let offlineHomeNote = "⚠ 离线: 正在显示缓存的首页数据"
    static let localMissNote = "本地无结果，正在查远程…"
    static let remoteNote = "远程全库"
    static let offlineSearchNote = "⚠ 离线: 显示缓存搜索结果"

    // 空态 / 错态（C5/C6：弯引号原样；hint 半角逗号+空格）
    static let emptyTextIdle = "输入关键词开始搜索"
    static func emptyResult(_ q: String) -> String { "未找到 “\(q)” 相关结果" }
    static let emptyResultHint = "试试更短的关键词, 或切换搜索范围/匹配模式"
    static let emptyHomeSection = "远程库暂无该数据 (需抓取端上传)"   // 半角括号

    // 结果 footer（C5）
    static let exactScopeNote = "精确匹配 · 已限定最近 5000 部内"
    static let localNoteTail = " · 点此改用远程全库搜索"

    // 首启引导（C1：全角冒号/全角括号）
    static let setupTitle = "首次使用 · 请先配置数据源"
    static let setupHint = "设置 → ① 数据源：填写主机 / 账号 / 密码后保存即可开始使用（服务器与手机需在同一局域网，或已配置代理）"
    static let setupAction = "去设置"

    // 首次引导卡（C2.4）
    static let welcomeTitle = "👋 欢迎使用 JDLV Mobile"
    static let welcomeHint = "首次使用请在设置里填写数据库地址与账号 (凭证来源见项目 mysql.txt 说明)"
    static let welcomeAction = "去设置数据源"

    // 首页三段（C4 段头逐字）+ 查看全部
    static let sectionRecent = "🆕 最近更新"
    static let sectionHot = "🔥 最多想看"
    static let sectionTop = "🏆 TOP250"
    static let viewAll = "查看全部 ›"

    // 历史区（C7）
    static let historyTitle = "最近搜索"

    // 范围 chips（C2 表：文案 → scope 值）
    static let scopes: [(label: String, value: String)] = [
        ("综合", "all"), ("番号", "number"), ("字头", "letter"), ("标题", "title"),
        ("女优", "actor"), ("标签", "tag"), ("系列", "series"),
    ]

    // 匹配模式（C2.3）
    static let modeExact = "精确"
    static let modeFuzzy = "模糊"

    // 资讯/热评入口（C2.5）
    static let entriesArticles = "资讯"
    static let entriesHotReviews = "热评"
}

// MARK: - SearchVM（@MainActor ObservableObject；等价 Android SearchVm）

@MainActor
final class SearchVM: ObservableObject {

    // MARK: 公开状态（14 A.6 SearchUi 逐项）

    @Published var loading = false            // 仅首载（home==nil && items==nil 时才出骨架）
    @Published var refreshing = false         // 手动下拉刷新（与 loading 独立：刷新不闪白）
    @Published var loadingMore = false
    @Published var error: String?
    @Published var home: SearchHomeResult?
    @Published var items: [Row]?
    @Published var total: Int64 = -1          // -1 = 未知（searchCount 异步补充）
    @Published var page = 1
    @Published var per = 40
    @Published var viewMode = 0               // 0 小图 / 1 大图 / 2 列表
    @Published var offlineNote: String?
    @Published var derived: String?
    @Published var scope = "all"
    @Published var mode = "fuzzy"             // "exact" / "fuzzy"
    @Published var query = ""                 // 搜索框文本（VM 持有：防抖与路由共用）
    @Published var lastUpdatedAt: Int64 = 0
    @Published var readIds: Set<String> = []
    @Published var favIds: Set<String> = []
    @Published var hasMore = true             // 满页才可能有下一页（铁律 20）
    @Published var setup = false              // 首启引导态（不查询、不显示"查询失败"）
    @Published var served = ""                // 结构化来源标注 "local"/"remote"
    /// 本地索引覆盖数（footer「本地索引已含 N 部」后台 IO 计算；-1 = 未计算；
    /// internal 可写：测试注入用）
    @Published var localIdxTotal: Int64 = -1
    /// 跳页过深等 VM Toast（页面消费后 clearToast）
    @Published var toast: String?
    /// 刷新结果通道（仅手动下拉 force && !auto 写入；页面消费后清位）
    let refreshResult = RefreshResultChannel()

    /// 本地索引目标上限（LimitMath 接线 P10+；<=0 = 不限 → footer "(不限)" 变体）
    var localIdxTarget: Int64 = 0

    // MARK: 私有状态

    private let data: SearchData
    private let cache: SearchMemCache
    private let clock: () -> Int64
    private let isOnline: () -> Bool
    private let readFav: (([String]) -> (read: Set<String>, fav: Set<String>))?

    private weak var settings: SearchSettingsReading?
    private var persistMode: ((String) -> Void)?

    /// 竞态防护 rid：每次 fetch 前 reqId++；返回时 rid != reqId 整体丢弃（A.0）
    private var reqId = 0
    /// 计数独立序（fetchCount 双保险：rid==reqId && cs==countSeq 才写 total）
    private var countSeq = 0
    /// 同源翻页：最近一次来源 "local"/"remote"（A.6 loadNext）
    private(set) var lastSource = ""
    /// "改用远程全库" 出口（forceRemoteRetry 置位；新搜索复位）
    private var forceRemote = false
    /// D-3 退避：上次自动重搜失败记 now、成功清 0（S1 D-3；保留字段与写入语义）
    private(set) var lastAutoFailAt: Int64 = 0
    private var seenEpoch = -1
    private var lastAutoAt: Int64 = 0
    private var homeKicked = false
    /// 防抖任务（输入 300ms 可取消；scope/mode 变化立即重搜不走此路）
    private var debounceTask: Task<Void, Never>?
    /// 最近一次实际发起搜索的键（query|scope|mode）——防抖与 doSearch 去重
    private(set) var lastAppliedKey = ""

    init(data: SearchData,
         cache: SearchMemCache = .shared,
         isOnline: (() -> Bool)? = nil,
         readFav: (([String]) -> (read: Set<String>, fav: Set<String>))? = nil,
         clock: (() -> Int64)? = nil) {
        self.data = data
        self.cache = cache
        self.isOnline = isOnline ?? { true }
        self.readFav = readFav
        self.clock = clock ?? { Int64(Date().timeIntervalSince1970 * 1000) }
    }

    // MARK: 首页 per 档位（C4：{12,18,24,36}，档位外归一 24；JDLVCore.HOME_PER_OPTS 模块内）

    static let homePerOpts: Set<Int> = [12, 18, 24, 36]

    static func normHomePer(_ v: Int) -> Int {
        homePerOpts.contains(v) ? v : 24
    }

    /// 页缓存键：search:{q}:{scope}:{mode}:{p}:{per}[:L]（本地来源 +":L"，07 C0/C8）
    static func pageKey(_ q: String, _ scope: String, _ mode: String,
                        _ p: Int, _ per: Int, local: Bool) -> String {
        "search:\(q):\(scope):\(mode):\(p):\(per)" + (local ? ":L" : "")
    }

    // MARK: bind（B09：setup 引导态不查询；否则 loadHome；同步 viewMode/per/mode）

    func bind(to reader: SearchSettingsReading?,
              persistMode: ((String) -> Void)? = nil) {
        settings = reader
        self.persistMode = persistMode
        viewMode = reader?.searchViewMode ?? viewMode
        per = normalizePer(reader?.searchPerPage ?? per, default: 40)
        mode = (reader?.searchModeRaw ?? 1) == 0 ? "exact" : "fuzzy"
        setup = reader?.searchSetupRequired ?? setup
        guard !setup, !homeKicked else { return }
        homeKicked = true
        Task { await loadHome(force: false) }
    }

    // MARK: 首页三段（loadHome：stale-then-refresh 三级，A.6）

    func loadHome(force: Bool, auto: Bool = false) async {
        let fromRefresh = force && !auto
        let p = Self.normHomePer(settings?.searchHomePer ?? 24)
        let key = "home:\(p)"
        let ttl = force ? 0 : max(0, settings?.searchHomeTtl ?? 10)

        // 1 级：TTL 内缓存直接用（force → TTL=0 → 必 miss）
        if ttl > 0, let cached: SearchHomeResult = cache.get(SearchHomeResult.self, key: key, ttlMinutes: ttl) {
            applyHome(cached)
            return
        }

        let rid = reqId + 1
        reqId = rid
        defer { if rid == reqId { loading = false; refreshing = false } }

        // 2 级：有 stale → 先渲染 stale + SWR 注记，后台刷新
        if let stale: SearchHomeResult = cache.stale(SearchHomeResult.self, key: key) {
            applyHome(stale, note: SearchCopy.swrNote)
            do {
                let fresh = try await data.home(per: p)
                guard rid == reqId else { return }
                cache.put(fresh, key: key)
                applyHome(fresh)
                if fromRefresh { refreshResult.emit(.done(fresh.totalCount)) }
            } catch {
                guard rid == reqId else { return }
                applyHome(stale, note: SearchCopy.offlineHomeNote)
                if fromRefresh { refreshResult.emit(.fail("首页查询失败")) }
            }
            return
        }

        // 3 级：全无 → 实查（失败 ErrText + fromRefresh 时 Fail）
        if !auto {
            if home == nil && items == nil {
                loading = true
                error = nil
            }
            if fromRefresh { refreshing = true }
        }
        do {
            let fresh = try await data.home(per: p)
            guard rid == reqId else { return }
            cache.put(fresh, key: key)
            applyHome(fresh)
            if fromRefresh { refreshResult.emit(.done(fresh.totalCount)) }
        } catch {
            guard rid == reqId else { return }
            if !auto { error = ErrText.of(error) }
            if fromRefresh { refreshResult.emit(.fail("首页查询失败")) }
        }
    }

    private func applyHome(_ h: SearchHomeResult, note: String? = nil) {
        home = h
        offlineNote = note
        error = nil
        lastUpdatedAt = clock()
        loading = false
    }

    // MARK: 搜索路由（S12-P1：钳制 → 本地优先 → 0 命中回落远程 → 页缓存 → fetchCount）

    func search(resetPage: Bool = true, requestedPage: Int = 1,
                force: Bool = false, auto: Bool = false) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let s = scope
        let m = mode
        let effPer = max(1, per)
        let fromRefresh = force && !auto
        lastAppliedKey = "\(q)|\(s)|\(m)"

        // 1. PaginationGuard.clamp（resetPage 时 total 视 0 → 5000 行硬 OFFSET 上限；
        //    clamped 且 p>1 → toast「跳页过深（最多约 N 页），请用滚动加载」）
        let decision = PaginationGuard.clamp(
            requested: requestedPage, total: resetPage ? 0 : total, per: effPer)
        if decision.clamped, requestedPage > 1 {
            toast = AppCopy.tooDeepToast(maxPage: decision.page)
        }
        let p = decision.page

        if resetPage { forceRemote = false }
        let base = Self.pageKey(q, s, m, p, effPer, local: false)

        let rid = reqId + 1
        reqId = rid
        defer { if rid == reqId { loading = false; refreshing = false } }
        if !auto {
            if items == nil && home == nil {
                loading = true
                error = nil
            }
            if fromRefresh { refreshing = true }
        }

        // 2. 本地索引优先（!forceRemote && localReady && scope ∈ LOCAL_SCOPES）
        if !forceRemote && JdbSearch.localReady() && JdbSearch.LOCAL_SCOPES.contains(s) {
            do {
                let lp = try await JdbSearch.searchLocalIdx(q: q, scope: s, page: p, per: effPer)
                guard rid == reqId else { return }
                if !lp.items.isEmpty {
                    lastSource = "local"
                    let r = SearchPageResult(items: lp.items, derived: lp.derived ?? "", served: "local")
                    cache.put(r, key: base + ":L")
                    applyResult(lp.items, page: p, derived: lp.derived ?? "", served: "local")
                    lastAutoFailAt = 0            // 成功解除退避
                    computeLocalIdxTotal()
                    fetchCount(q: q, scope: s, preferLocal: true)
                    return
                }
                // 本地 0 命中：离线 → 直接空结果 return；在线 → 落远程（S12-P6）
                if !isOnline() {
                    lastSource = "local"
                    applyResult([], page: p, derived: lp.derived ?? "", served: "local")
                    lastAutoFailAt = 0
                    return
                }
                offlineNote = SearchCopy.localMissNote
            } catch {
                guard rid == reqId else { return }
                // 本地异常 → 落远程
            }
        }

        // 3. 远程路径：页缓存 TTL 10 分钟（force → TTL=0 必实查）→ Q.search → fetchCount
        let cacheTtl = force ? 0 : 10
        if cacheTtl > 0, let c: SearchPageResult = cache.get(SearchPageResult.self, key: base, ttlMinutes: cacheTtl) {
            lastSource = "remote"
            applyResult(c.items, page: p, derived: c.derived, served: c.served)
            lastAutoFailAt = 0
            fetchCount(q: q, scope: s, preferLocal: false)
            return
        }
        do {
            let rp = try await data.search(q: q, scope: s, page: p, per: effPer, mode: m)
            guard rid == reqId else { return }
            lastSource = "remote"
            cache.put(rp, key: base)
            // offlineNote = derived 非空取之，否则「远程全库」（A.6 远程路径逐字）
            applyResult(rp.items, page: p, derived: rp.derived, served: rp.served,
                        note: rp.derived.isEmpty ? SearchCopy.remoteNote : rp.derived)
            lastAutoFailAt = 0
            if fromRefresh { refreshResult.emit(.done(rp.items.count)) }
            fetchCount(q: q, scope: s, preferLocal: false)
        } catch {
            guard rid == reqId else { return }
            lastAutoFailAt = clock()          // S1 D-3 退避
            if !auto {
                if let stale: SearchPageResult = cache.stale(SearchPageResult.self, key: base) {
                    applyResult(stale.items, page: p, derived: stale.derived, served: stale.served,
                                note: SearchCopy.offlineSearchNote)
                } else {
                    error = ErrText.of(error)
                    if fromRefresh { refreshResult.emit(.fail(ErrText.of(error))) }
                }
            }
        }
    }

    /// 结果应用（非 append：整页替换 + hasMore=满页 + total 视 -1 待计数）
    private func applyResult(_ newItems: [Row], page p: Int, derived d: String,
                             served sv: String, note: String? = nil) {
        items = newItems
        page = p
        hasMore = newItems.count == per
        derived = d
        served = sv
        offlineNote = note
        error = nil
        total = -1
        lastUpdatedAt = clock()
        loading = false
        refreshReadFav(newItems)
    }

    /// fetchCount：独立 countSeq 双保险；本地来源用 countLocalIdx；
    /// 缓存 searchcount:{q}:{scope}:{useLocal} TTL 10 分钟（本地 0 命中不调 → 调用方约束）
    private func fetchCount(q: String, scope: String, preferLocal: Bool) {
        countSeq += 1
        let cs = countSeq
        let rid = reqId
        let key = "searchcount:\(q):\(scope):\(preferLocal ? 1 : 0)"
        if let c: Int64 = cache.get(Int64.self, key: key, ttlMinutes: 10) {
            applyCount(c, rid: rid, cs: cs)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let v: Int64
            if preferLocal {
                v = await JdbSearch.countLocalIdx(q: q, scope: scope)
            } else {
                v = await self.data.searchCount(q: q, scope: scope)
            }
            if v >= 0 { self.cache.put(v, key: key) }   // -1（未知）不落缓存
            self.applyCount(v, rid: rid, cs: cs)
        }
    }

    private func applyCount(_ v: Int64, rid: Int, cs: Int) {
        guard rid == reqId, cs == countSeq else { return }
        if v >= 0 { total = v }    // takeIf { it >= 0 }：-1 不回退已到计数
    }

    // MARK: 同源翻页（A.6 loadNext：lastSource local/remote；失败静默）

    func loadNext() async {
        if loading || refreshing || loadingMore { return }
        guard hasMore, let cur = items, !cur.isEmpty else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        loadingMore = true
        defer { loadingMore = false }
        let rid = reqId        // 不自增：翻页不使在途计数失效；新 search/loadHome 自增即失效
        let next = page + 1
        let s = scope
        let m = mode
        let effPer = per

        do {
            if lastSource == "local" {
                let lp = try await JdbSearch.searchLocalIdx(q: q, scope: s, page: next, per: effPer)
                guard rid == reqId else { return }
                let r = SearchPageResult(items: lp.items, derived: lp.derived ?? "", served: "local")
                cache.put(r, key: Self.pageKey(q, s, m, next, effPer, local: true))
                appendPage(r.items, nextPage: next, derived: r.derived)
            } else {
                let key = Self.pageKey(q, s, m, next, effPer, local: false)
                let rp: SearchPageResult
                if let c: SearchPageResult = cache.get(SearchPageResult.self, key: key, ttlMinutes: 10) {
                    rp = c
                } else {
                    rp = try await data.search(q: q, scope: s, page: next, per: effPer, mode: m)
                    guard rid == reqId else { return }
                    cache.put(rp, key: key)
                }
                appendPage(rp.items, nextPage: next, derived: rp.derived)
            }
        } catch {
            // 静默：失败仅 loadingMore=false（A.6）
        }
    }

    /// append 去重按 id；hasMore = 本页满页
    private func appendPage(_ newItems: [Row], nextPage: Int, derived d: String) {
        let existing = Set((items ?? []).map { $0.s("id") })
        let fresh = newItems.filter { !existing.contains($0.s("id")) }
        items = (items ?? []) + fresh
        page = nextPage
        hasMore = newItems.count == per
        derived = d
        lastUpdatedAt = clock()
    }

    // MARK: 跳页 / 模式 / 远程重试 / 范围

    /// goPage：search(resetPage=false, page=max(1,p))——钳制走 PaginationGuard（A.6）
    func goPage(_ p: Int) async {
        await search(resetPage: false, requestedPage: max(1, p))
    }

    /// setMode：落 searchMode（页面持久化）并重搜（A.6）
    func setMode(_ m: String) {
        guard m == "exact" || m == "fuzzy", m != mode else { return }
        mode = m
        persistMode?(m)
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await search() }
        }
    }

    /// 范围 chips：选中即切 scope；query 非空时立即重搜（C2）
    func setScope(_ s: String) {
        guard s != scope else { return }
        scope = s
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { await search() }
        }
    }

    /// footer「改用远程全库」出口（C5/A.6 forceRemoteRetry）
    func forceRemoteRetry() {
        forceRemote = true
        Task { await search(resetPage: false, requestedPage: page) }
    }

    /// 输入防抖（C3：300ms 可取消；再变即取消上次）
    func queryEdited() {
        debounceTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if "\(q)|\(scope)|\(mode)" == lastAppliedKey { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    /// 防抖与去重状态复位（doSearch 立即搜前调，防 300ms 后重复一发）
    func resetDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
        lastAppliedKey = ""
    }

    func consumeToast() {
        toast = nil
    }

    // MARK: 下拉刷新 / 错误重试（C0：query 空 → loadHome(force)；有 query → 重搜 force）

    func refreshFromPull() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            Task { await loadHome(force: true) }
        } else {
            Task { await search(resetPage: true, requestedPage: 1, force: true) }
        }
    }

    // MARK: dataEpoch 自动刷新（A.0：冷却 60s 静默；首次只记录）

    func onDataEpoch(_ v: Int) {
        if v <= 0 || v == seenEpoch { return }
        let first = seenEpoch < 0
        seenEpoch = v
        if first { return }
        let now = clock()
        guard RefreshPolicy.shouldAuto(lastAutoAt, now: now) else { return }
        lastAutoAt = now
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            Task { await loadHome(force: true, auto: true) }
        } else {
            Task { await search(resetPage: true, requestedPage: 1, force: true, auto: true) }
        }
    }

    // MARK: 本地索引覆盖（footer「本地索引已含 …」后台 IO 计算，C5）

    private func computeLocalIdxTotal() {
        guard localIdxTotal < 0 else { return }
        Task { [weak self] in
            guard let self else { return }
            let n = (try? JdbSearch.idx?.countOf(table: "idx_movies")) ?? -1
            self.localIdxTotal = n ?? -1
        }
    }

    /// footer 本地来源标注（千分位；target<=0 = 不限，C5 逐字）
    var localNoteText: String {
        let grouped = { (v: Int64) -> String in
            NumberFormatter.groupedInt(v)
        }
        let tail = SearchCopy.localNoteTail
        if localIdxTotal <= 0 { return "本地索引" + tail }
        if localIdxTarget <= 0 { return "本地索引已含 \(grouped(localIdxTotal)) 部 (不限)" + tail }
        return "本地索引已含 \(grouped(localIdxTotal)) / \(grouped(localIdxTarget)) 部" + tail
    }

    // MARK: 已读/收藏集合（LocalStore 接线后续阶段；先留批量查询口）

    private func refreshReadFav(_ rows: [Row]) {
        guard let provider = readFav else { return }
        let ids = rows.map { $0.s("id") }
        guard !ids.isEmpty else { return }
        let r = provider(ids)
        readIds = r.read
        favIds = r.fav
    }
}

// MARK: - 工具

extension NumberFormatter {
    static func groupedInt(_ v: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - 生产数据源（Q.home / Q.search / Q.searchCount 委托）

final class QSearchData: SearchData {
    func home(per: Int) async throws -> SearchHomeResult {
        let m = try await Q.home(per: per)
        return SearchHomeResult(
            recent: m["recent"] as? [Row] ?? [],
            hot: m["hot"] as? [Row] ?? [],
            top: m["top"] as? [Row] ?? [],
            derived: m["derived"] as? String ?? "")
    }

    func search(q: String, scope: String, page: Int, per: Int, mode: String) async throws -> SearchPageResult {
        let m = try await Q.search(q: q, scope: scope, page: page, per: per, mode: mode)
        return SearchPageResult(
            items: m["items"] as? [Row] ?? [],
            derived: m["derived"] as? String ?? "",
            served: m["served"] as? String ?? "remote")
    }

    func searchCount(q: String, scope: String) async -> Int64 {
        (try? await Q.searchCount(q: q, scope: scope)) ?? -1
    }
}

// MARK: - DEBUG demo 数据源（DemoStore 适配；Release 无此段）

#if DEBUG

/// demo 本地索引适配（注入 JdbSearch.idx → 本地优先 / 0 命中回落远程全链路可演示）。
/// localReady 恒 true（demo 库恒"就绪"）；女优数 < 1000 → actor 本地不就绪（与生产阈值语义一致）。
/// 本地检索口径：number/letter → 番号前缀；title/all → 标题子串（tag/series 本地无列 → 落远程）。
final class DemoIdxSearchable: IdxSearchable {
    private let store = DemoStore.shared
    private let lock = NSLock()
    private var cachedMovies: [Row]?

    /// DemoStore.browse 全量（132 部 < 200 上限，单页取完）
    private func allMovies() -> [Row] {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedMovies { return c }
        let items = store.browse(f: Filters(), page: 1, per: 200)["items"] as? [Row] ?? []
        cachedMovies = items
        return items
    }

    private func filter(_ q: String, scope: String) -> [Row] {
        let ql = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rows = allMovies()
        switch scope {
        case "number", "letter":
            rows = rows.filter { $0.s("number").lowercased().hasPrefix(ql) }
        case "title":
            rows = rows.filter { $0.s("title").contains(q.trimmingCharacters(in: .whitespacesAndNewlines)) }
        default:   // all
            let raw = q.trimmingCharacters(in: .whitespacesAndNewlines)
            rows = rows.filter {
                $0.s("number").lowercased().hasPrefix(ql) || $0.s("title").contains(raw)
            }
        }
        rows.sort { ($0.s("release_date"), $0.s("id")) > ($1.s("release_date"), $1.s("id")) }
        return rows
    }

    func localReady() -> Bool { true }
    func countOf(table: String) throws -> Int64 { Int64(allMovies().count) }
    func countActors() throws -> Int64 { Int64(DemoStore.actorCount) }   // 72 < 1000 → actor 本地不就绪
    func searchMovies(q: String, scope: String, per: Int, offset: Int) throws -> [Row] {
        let rows = filter(q, scope: scope)
        guard offset >= 0, offset < rows.count else { return [] }
        return Array(rows[offset..<min(offset + per, rows.count)])
    }
    func countMovies(q: String, scope: String) throws -> Int64 { Int64(filter(q, scope: scope).count) }
    func searchActorMovies(q: String, page: Int, per: Int) throws -> [Row] { [] }
    func countActorMovies(q: String) throws -> Int64 { 0 }
    func searchMoviesByTag(tagId: String, limit: Int, offset: Int) throws -> [Row] { [] }
    func countMoviesByTag(tagId: String) throws -> Int64 { 0 }
    func threadById(tid: String) throws -> Row? { nil }
    func searchThreads(q: String, board: String, boardName: String, type: String,
                       hasMagnet: Bool, limit: Int, offset: Int) throws -> [Row] { [] }
    func threadsBy(sort: String, asc: Bool, limit: Int, offset: Int) throws -> [Row] { [] }
}

/// demo SearchData：home → DemoStore.homeSections；search → 广口径内存过滤（远程语义）。
/// 本地（DemoIdxSearchable）只搜 番号前缀/标题子串，标签/系列/女优/片商走"远程" →
/// 查「企划」（标签）即触发「本地无结果，正在查远程…」回落链路。
final class DemoSearchData: SearchData {
    private let store = DemoStore.shared
    private let idxLock = NSLock()
    /// "远程"检索调用计数（测试/UI 测试断言本地优先路由用）
    private(set) var remoteSearchCalls = 0

    init() {
        idxLock.lock()
        if JdbSearch.idx == nil { JdbSearch.idx = DemoIdxSearchable() }
        idxLock.unlock()
    }

    func home(per: Int) async throws -> SearchHomeResult {
        let segs = store.homeSections(per: per)
        return SearchHomeResult(
            recent: segs["recent"] ?? [],
            hot: segs["hot"] ?? [],
            top: segs["top"] ?? [],
            derived: "")
    }

    func search(q: String, scope: String, page: Int, per: Int, mode: String) async throws -> SearchPageResult {
        remoteSearchCalls += 1
        return SearchPageResult(items: demoRemoteRows(q: q, scope: scope, page: page, per: per),
                                derived: "", served: "remote")
    }

    func searchCount(q: String, scope: String) async -> Int64 {
        Int64(demoRemoteAll(q: q, scope: scope).count)
    }

    // MARK: demo 远程口径（广过滤：番号前缀/标题/标签/系列/片商；女优经 actors → 关联影片）

    private func allMovies() -> [Row] {
        store.browse(f: Filters(), page: 1, per: 200)["items"] as? [Row] ?? []
    }

    private func demoRemoteAll(q raw: String, scope: String) -> [Row] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let ql = q.lowercased()
        var rows: [Row]
        switch scope {
        case "number", "letter":
            rows = allMovies().filter { $0.s("number").lowercased().hasPrefix(ql) }
        case "tag":
            rows = allMovies().filter { movie in
                movie.s("tags").split(separator: ",")
                    .contains { $0.trimmingCharacters(in: .whitespaces) == q }
            }
        case "series":
            rows = allMovies().filter { $0.s("series_name").contains(q) }
        case "actor":
            let aids = store.actors(page: 1, per: 50, sort: "videos", gender: "all", q: q)
                .map { $0.s("id") }
            var merged: [Row] = []
            var seen = Set<String>()
            for aid in aids {
                for m in store.actorMovies(aid: aid, page: 1) where seen.insert(m.s("id")).inserted {
                    merged.append(m)
                }
            }
            rows = merged
        case "title":
            rows = allMovies().filter { $0.s("title").contains(q) }
        default:   // all
            rows = allMovies().filter {
                $0.s("number").lowercased().hasPrefix(ql)
                    || $0.s("title").contains(q)
                    || $0.s("tags").contains(q)
                    || $0.s("maker_name").contains(q)
                    || $0.s("series_name").contains(q)
            }
        }
        rows.sort { ($0.s("release_date"), $0.s("id")) > ($1.s("release_date"), $1.s("id")) }
        return rows
    }

    private func demoRemoteRows(q: String, scope: String, page: Int, per: Int) -> [Row] {
        let rows = demoRemoteAll(q: q, scope: scope)
        let offset = max(0, (max(1, page) - 1) * per)
        guard offset < rows.count else { return [] }
        return Array(rows[offset..<min(offset + per, rows.count)])
    }
}

#endif

// MARK: - 组装入口（demo 模式路由；两种模式同一 VM 代码）

extension SearchVM {
    static func makeDefault(isOnline: (() -> Bool)? = nil) -> SearchVM {
        #if DEBUG
        if DemoDataSource.enabled() {
            return SearchVM(data: DemoSearchData(), isOnline: isOnline)
        }
        #endif
        return SearchVM(data: QSearchData(), isOnline: isOnline)
    }
}
