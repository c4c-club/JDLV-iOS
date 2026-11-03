import Foundation
import JDLVCore

//
//  ActorsVM.swift —— 女优列表页 VM（09 A 节 ActorsScreen/ActorsVm + 14_vm_tests A.3 全契约）。
//
//  状态（A.3 ActorsUi 逐字段）：loading/refreshing/loadingMore/error/items(nil=未首载)/
//  total/page/per=30/sort="videos"/gender="f"/q/lastUpdatedAt/hasMore/refreshResult。
//
//  契约：
//  - 竞态 rid：fetch 前 reqId++；apply/catch 先校验 rid != reqId → 整体丢弃。
//  - SWR：reload 保留旧 items（loading 只在 items==null 首载骨架）。
//  - 离线回落三级：TTL 缓存**只 put 不 get**（每次实查，A.3）→ 失败 stale 兜底 →
//    error=ErrText.of(e)。
//  - Q.actors 返回 **total 恒 -1**（COUNT 已拆出异步）→ hasMore 按满页推断（本页条数 >= per，
//    铁律 20）；PageChip 恒「N / ?」；首屏（非 append）异步 actorsCount（失败 -1 保持未知）。
//  - 追加去重按 id；goPage 仅 maxOf(1, p) 钳制（无 PaginationGuard）+ reload(keepPage=true)。
//  - bind 语义（NA-02）：items 为空 → 同步设置里的 actorSort/actorGender 后**必 reload**
//    （旧版默认值恒等导致永不首查）；非空但与设置不一致 → reload；否则不动。
//  - setGender/setSort：先写 state → 落盘设置（updateSettings）→ reload（不回读 prefs）。
//  - 缓存键 "actors:{sort}:{gender}:{q}:{page}"。
//  - demo 模式（仅 DEBUG）：DemoStore.actors 注入（total 恒 -1、计数恒 -1 → PageChip「N / ?」）。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol ActorsDataSource {
    /// 对齐 Q.actors：返回 items/total(恒 -1)/page/approx（键名与 Android 逐字一致）
    func actors(sort: String, q: String, page: Int, per: Int, gender: String) async throws
        -> [String: Any]
    /// 异步计数（失败 -1 → UI 保持「已加载 N 条」/「N / ?」）
    func actorsCount(q: String, gender: String) async -> Int64
}

/// 生产数据源（离线回落/探活/markOffline 全在 Q.actors 内）
struct QActorsDataSource: ActorsDataSource {
    func actors(sort: String, q: String, page: Int, per: Int, gender: String) async throws
        -> [String: Any] {
        try await Q.actors(sort: sort, q: q, page: page, per: per, gender: gender)
    }

    func actorsCount(q: String, gender: String) async -> Int64 {
        await Q.actorsCount(q: q, gender: gender)
    }
}

#if DEBUG

/// demo 数据源：同一协议注入 DemoStore.actors（total 恒 -1，与 Q.actors 口径一致）
struct DemoActorsDataSource: ActorsDataSource {
    func actors(sort: String, q: String, page: Int, per: Int, gender: String) async throws
        -> [String: Any] {
        let rows = DemoStore.shared.actors(page: page, per: per, sort: sort, gender: gender, q: q)
        return ["items": rows, "total": Int64(-1), "page": page, "approx": true]
    }

    func actorsCount(q: String, gender: String) async -> Int64 { -1 }
}

#endif

// MARK: - 逐字文案（09 A 节）

enum ActorsCopy {
    private init() {}

    /// SearchBarCompact placeholder（逐字）
    static let searchPlaceholder = "搜索女优姓名 / 别名…"
    /// 性别 3 档（label → value 逐字）
    static let genderOptions: [(label: String, value: String)] =
        [("女", "f"), ("男", "m"), ("全部", "all")]
    /// 排序 6 档（label → value 逐字）
    static let sortOptions: [(label: String, value: String)] = [
        ("影片数", "videos"), ("人气", "popularity"), ("姓名", "name"),
        ("出道", "debut"), ("单体均分", "avg_solo"), ("全部均分", "avg_all"),
    ]
    /// DropdownBox label
    static let genderLabel = "性别"
    static let sortLabel = "排序"
    /// 空/错态（ListScaffold 与 header 内状态块同文）
    static let emptyText = "远程库暂无女优数据 (离线时显示本地索引)"
}

// MARK: - ActorsVM（14 A.3）

@MainActor
final class ActorsVM: ObservableObject {

    // MARK: 依赖（可注入）

    let source: ActorsDataSource
    /// 缓存（只 put 不 get；失败 stale 兜底）
    let cache: BrowseCacheStore
    /// 设置桥（ActorsView onAppear 注入；测试 nil —— bind 同步/落盘全部静默跳过）
    weak var store: SettingsStore?
    /// 全局 Toast 通道
    var onToast: (String) -> Void
    /// 可注入时钟（lastUpdatedAt 测试用）
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    init(
        source: ActorsDataSource? = nil,
        cache: BrowseCacheStore = MemoryBrowseCache.shared,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoActorsDataSource() : QActorsDataSource())
        #else
        self.source = source ?? QActorsDataSource()
        #endif
        self.cache = cache
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    /// 页面默认构造
    static func makeDefault() -> ActorsVM { ActorsVM() }

    // MARK: 状态（A.3 逐字段）

    @Published var loading = false
    @Published var refreshing = false
    @Published var loadingMore = false
    @Published var error: String? = nil
    /// null = 未首载（首载骨架）；非 null 保留旧值（SWR 不闪白）
    @Published var items: [Row]? = nil
    /// Q.actors 恒 -1（未知）；异步 actorsCount 到达才 > 0
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var per = 30
    @Published var sort = "videos"
    @Published var gender = "f"
    /// 搜索词（search 写入；缓存键段）
    @Published var q = ""
    @Published var hasMore = true
    @Published var lastUpdatedAt: Int64 = 0

    /// 刷新结果通道（仅手动下拉路径写入；页面消费后 consume 清位）
    let refreshChannel = RefreshResultChannel()

    private var reqId = 0
    private var seenEpoch: Int = -1
    private var lastAutoAt: Int64 = 0

    // MARK: 纯函数（测试共用）

    /// 列表缓存键：actors:{sort}:{gender}:{q}:{page}（只 put 不 get）
    static func cacheKey(sort: String, gender: String, q: String, page: Int) -> String {
        "actors:\(sort):\(gender):\(q):\(page)"
    }

    // MARK: 生命周期

    /// bind（NA-02）：items 为空 → 同步设置里的 actorSort/actorGender 后必 reload；
    /// 非空但与设置不一致 → reload；否则不动
    func bind() async {
        let sSort = store?.settings.actorSort ?? sort
        let sGender = store?.settings.actorGender ?? gender
        let listEmpty = (items ?? []).isEmpty
        if listEmpty {
            sort = sSort
            gender = sGender
            await reload()
        } else if sort != sSort || gender != sGender {
            sort = sSort
            gender = sGender
            await reload()
        }
    }

    /// dataEpoch 变更（数据源级）：60s 冷却（RefreshPolicy）静默刷新（auto 不写 refreshResult）
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
    /// page = keepPage ? 当前 : 1（NA-01 跳页保页码）、items 保留（SWR 不闪白）
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
        let key = Self.cacheKey(sort: sort, gender: gender, q: q, page: targetPage)
        do {
            let d = try await source.actors(
                sort: sort, q: q, page: targetPage, per: per, gender: gender)
            guard rid == reqId else { return }   // 旧响应一律丢弃
            cache.put(key, d)   // 只 put 不 get（结果缓存仅作失败 stale 兜底）
            apply(d, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
            if !append && targetPage == 1 {
                await fetchCount(rid: rid)
            }
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
            error = msg
            if fromRefresh { refreshChannel.emit(.fail(msg)) }
        }
    }

    /// apply：append 按 id 去重拼接；total<0 不回退；hasMore=满页推断；
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
        // total<0 = 未知 → 保留已异步到达的计数不回退（铁律 20）
        if let t = BrowseVM.numOf(d, "total"), t >= 0 { total = t }
        hasMore = fresh.count >= max(1, per)   // 按满页推断（total 未知也能翻页）
        lastUpdatedAt = nowMs()
        loading = false
        refreshing = false
        loadingMore = false
        if fromRefresh { refreshChannel.emit(.done(merged.count)) }
    }

    /// 首屏异步计数：失败 -1 → 静默保持「已加载 N 条」（total 未知 → PageChip「N / ?」）
    private func fetchCount(rid: Int) async {
        let c = await source.actorsCount(q: q, gender: gender)
        guard rid == reqId, c >= 0 else { return }
        total = c
    }

    // MARK: 翻页

    /// loadNext：守卫（loading/refreshing/loadingMore/items 空/!hasMore）
    func loadNext() async {
        if loading || refreshing || loadingMore { return }
        guard let it = items, !it.isEmpty else { return }
        guard hasMore else { return }
        loadingMore = true
        await fetch(append: true, fromRefresh: false)
    }

    /// goPage：仅 maxOf(1, p) 钳制（无 PaginationGuard，A.4）→ reload(keepPage=true)
    func goPage(_ p: Int) async {
        page = max(1, p)
        await reload(keepPage: true)
    }

    // MARK: 搜索 / 筛选入口（A.6：page=1 + reload）

    /// search（SearchBarCompact 提交 / 300ms 防抖回调）：q 存 VM 字段，page=1，reload
    func search(_ term: String) async {
        q = term.trimmingCharacters(in: .whitespaces)
        await reload()
    }

    /// setGender：先写 state → 落盘 actorGender → reload
    func setGender(_ v: String) async {
        gender = v
        store?.updateSettings { $0.actorGender = v }
        await reload()
    }

    /// setSort：先写 state → 落盘 actorSort → reload
    func setSort(_ v: String) async {
        sort = v
        store?.updateSettings { $0.actorSort = v }
        await reload()
    }
}
