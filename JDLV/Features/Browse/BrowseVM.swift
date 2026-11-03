import Foundation
import JDLVCore

//
//  BrowseVM.swift —— 影片浏览页 VM（08 A 节 / C 节、14_vm_tests A.0/A.2 全契约）。
//
//  状态（C.1 BrowseUi 逐字段）：loading/refreshing/loadingMore/error/items(nil=未首载)/
//  total/page/per=40/viewMode/sort="release_date"/asc=false/f:Filters/years/codes/makers/tags/
//  tagQuery/tagMode="common"/filterSource("loading"→remote|fallback|stale|assets)/taxonomyTs/
//  lastUpdatedAt/readIds/favIds/derived/approx/hasMore=true/refreshResult(RefreshResultChannel)。
//
//  契约（A.0 / C.3）：
//  - 竞态 rid：fetch 前 reqId++；apply/catch 先校验 rid != reqId → 整体丢弃。
//  - SWR：reload/筛选变化保留旧 items（loading 只在 items==null 首载骨架）。
//  - 离线回落三级：TTL 缓存 → stale（无视 TTL）→ error=ErrText.of(e)。
//  - keyset 锚点 anchors[page] = 响应 anchor 字段（本页末行键值）；缓存命中/新鲜统一写入；
//    非 append（筛选/排序/跳页）清空（NA-34）。
//  - hasMore 按满页推断（本页条数 >= per）；total<0 不回退已异步到达的计数（铁律 20）。
//  - 追加软上限 MAX_MERGED_ITEMS = 500（NA-22：到顶用跳页，页面无额外提示文案）。
//  - 跳页 PaginationGuard.clamp（5000 行硬 OFFSET 上限）；钳制且 p>1 → Toast
//    「跳页过深（最多约 N 页），请用滚动加载」。
//  - 缓存键 "browse:{f}:{sort}:{asc}:{per}:{page}"（含 asc，S11-P2 防正/倒序串缓存）；
//    计数键 "bcount:{f}:{sort}" TTL 5 分钟；TTL 用设置 filterTtl（默认 60 分钟）。
//  - normSort：want→want_watch_count；白名单 {release_date,id,score,want_watch_count}，
//    其余 → release_date。
//  - applyFilters(f, sortOverride)：反查入口；sortOverride 非空 → 覆盖 sort 且 asc 恒 false
//    （倒序，修"写 settings 再回读"竞态导致的段头排序丢失）。
//  - taxonomy 加载链（A.7）：缓存 jdb_taxonomy(24h) → Q.taxonomy()（makers≤500/codes≤3000/
//    tags≤500/years≤40）→ 失败 stale（source=stale）→ Q.filters()（source=assets，
//    tags 由 categories 拍平 id/name/c=0 按 id 去重）；远程索引表空 → fallback=true。
//  - onDataEpoch：60s 冷却（RefreshPolicy）；首次只记录不刷；auto=true 静默（不写 refreshResult）。
//  - 离线本地索引路径（LocalFilterSql/IdxDb 读源）为 P13 接线点：本阶段 Q.browse 内
//    browseLocal 恒 nil，行为与 Android "本地库为空" 分支一致；VM 侧接口已留（source 协议）。
//  - demo 模式（仅 DEBUG）：与生产同一 BrowseDataSource 协议注入 DemoStore.browse。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol BrowseDataSource {
    /// 对齐 Q.browse：返回 items/total/anchor/derived/approx（键名与 Android 逐字一致）
    func browse(
        f: Filters, page: Int, per: Int, sort: String,
        asc: Bool, anchor: [String]?
    ) async throws -> [String: Any]
    /// 失败返回 -1（UI 保持「已加载 N 条」）
    func browseCount(f: Filters, sort: String) async -> Int64
}

/// 生产数据源（Q 层；离线回落/探活/5000 OFFSET 兜底全在 Q.browse 内）
struct QBrowseDataSource: BrowseDataSource {
    func browse(
        f: Filters, page: Int, per: Int, sort: String,
        asc: Bool, anchor: [String]?
    ) async throws -> [String: Any] {
        try await Q.browse(f: f, page: page, per: per, sort: sort, asc: asc, anchor: anchor)
    }

    func browseCount(f: Filters, sort: String) async -> Int64 {
        await Q.browseCount(f: f, sort: sort)
    }
}

// MARK: - taxonomy 筛选索引加载（A.7 降级链）

/// 筛选索引束（来源四态：remote|fallback|stale|assets；ts 毫秒）
struct BrowseTaxonomyBundle {
    var years: [Row] = []
    var codes: [Row] = []
    var makers: [Row] = []
    var tags: [Row] = []
    var fallback = false
    var ts: Int64 = 0
    var source = "loading"
}

protocol BrowseTaxonomyLoader {
    func load() async -> BrowseTaxonomyBundle
}

/// 生产链：缓存(24h) → Q.taxonomy() → stale → Q.filters()(assets, tags 拍平)
struct ProductionTaxonomyLoader: BrowseTaxonomyLoader {
    let cache: BrowseCacheStore

    func load() async -> BrowseTaxonomyBundle {
        let key = "jdb_taxonomy"
        // ① TTL 内缓存命中（fallback 标记随缓存走 → source 同步）
        if let hit = cache.get(key, ttlMinutes: 24 * 60) {
            return Self.bundle(from: hit,
                               source: (hit["fallback"] as? Bool) == true ? "fallback" : "remote")
        }
        // ② 远程 taxonomy（各段独立容错，永不 throw）
        let m = await Q.taxonomy()
        let makers = m["makers"] as? [Row] ?? []
        let codes = m["codes"] as? [Row] ?? []
        let tags = m["tags"] as? [Row] ?? []
        let years = m["years"] as? [Row] ?? []
        let fallback = (m["fallback"] as? Bool) == true
        let ts = Self.numOf(m, "ts") ?? 0
        // 全空 = 远程不可达/索引任务未跑 → stale → assets 降级
        if makers.isEmpty && codes.isEmpty && tags.isEmpty && years.isEmpty {
            if let stale = cache.stale(key) {
                return Self.bundle(from: stale, source: "stale")
            }
            // ③ Q.filters()：旧派生窗口聚合 + assets tags_index.json 拍平（source=assets）
            let fm = await Q.filters()
            return Self.bundleFromFilters(fm, source: "assets")
        }
        cache.put(key, m)
        return BrowseTaxonomyBundle(
            years: years, codes: codes, makers: makers, tags: tags,
            fallback: fallback, ts: ts, source: fallback ? "fallback" : "remote")
    }

    static func numOf(_ d: [String: Any], _ k: String) -> Int64? {
        switch d[k] {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        default: return nil
        }
    }

    static func bundle(from m: [String: Any], source: String) -> BrowseTaxonomyBundle {
        BrowseTaxonomyBundle(
            years: m["years"] as? [Row] ?? [],
            codes: m["codes"] as? [Row] ?? [],
            makers: m["makers"] as? [Row] ?? [],
            tags: m["tags"] as? [Row] ?? [],
            fallback: (m["fallback"] as? Bool) == true,
            ts: numOf(m, "ts") ?? 0,
            source: source)
    }

    /// Q.filters() 返回 → bundle；letters 行键 letter/c → codes 的 id/name/c 对位。
    static func bundleFromFilters(_ fm: [String: Any], source: String) -> BrowseTaxonomyBundle {
        let letters = fm["letters"] as? [Row] ?? []
        let codes: [Row] = letters.map {
            Row(["id": .string($0.s("letter")), "name": .string($0.s("letter")), "c": .int($0.i("c"))])
        }
        // tags：filters() 已拍平（id/name/c=0，distinctBy id —— S15-08 离线首启 chips 非空）
        let flat = fm["tags"] as? [[String: Any]] ?? []
        let tags: [Row] = flat.map { t in
            let id = t["id"] as? String ?? ""
            let name = t["name"] as? String ?? ""
            let c: Int64
            switch t["c"] {
            case let n as Int64: c = n
            case let n as Int: c = Int64(n)
            default: c = 0
            }
            return Row(["id": .string(id), "name": .string(name), "c": .int(c)])
        }
        return BrowseTaxonomyBundle(
            years: fm["years"] as? [Row] ?? [],
            codes: codes,
            makers: fm["makers"] as? [Row] ?? [],
            tags: tags,
            fallback: false,
            ts: 0,
            source: source)
    }
}

#if DEBUG
/// demo 数据源：同一协议注入 DemoStore.browse（列名与真实库一致，P9 页面层零改动切换）。
/// anchor 恒空串 → VM 解析为 nil → OFFSET 分页；total 真值（approx=false）。
struct DemoBrowseDataSource: BrowseDataSource {
    func browse(
        f: Filters, page: Int, per: Int, sort: String,
        asc: Bool, anchor: [String]?
    ) async throws -> [String: Any] {
        var ff = f
        // demo release_date 为 %04d-%02d 格式：月份无补零输入（面板 chips 1..12）先补零
        if ff.month.count == 1 { ff.month = "0" + ff.month }
        return DemoStore.shared.browse(f: ff, page: page, per: per, sort: sort, asc: asc)
    }

    func browseCount(f: Filters, sort: String) async -> Int64 {
        -1   // demo total 已随页响应返回（真值），计数通道保持未知不回退
    }
}

/// demo taxonomy：从 DemoStore 合成数据聚合（years≤40/codes≤3000/makers≤500/tags≤500，
/// 按计数倒序）；tags id=name（demo movies.tags 存名称 CSV，与 DemoBrowseDataSource 口径闭环）。
struct DemoTaxonomyLoader: BrowseTaxonomyLoader {
    func load() async -> BrowseTaxonomyBundle {
        let items = DemoStore.shared
            .browse(f: Filters(), page: 1, per: 200, sort: "id", asc: false)["items"] as? [Row] ?? []
        var yearC: [String: Int64] = [:]
        var letterC: [String: Int64] = [:]
        var makerC: [String: Int64] = [:]
        var tagC: [String: Int64] = [:]
        for r in items {
            let y = r.s("year")
            if !y.isEmpty { yearC[y, default: 0] += 1 }
            let l = r.s("number_letter")
            if !l.isEmpty { letterC[l, default: 0] += 1 }
            let mk = r.s("maker_name")
            if !mk.isEmpty { makerC[mk, default: 0] += 1 }
            for t in r.s("tags").split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty {
                tagC[t, default: 0] += 1
            }
        }
        func rows(_ dict: [String: Int64], cap: Int) -> [Row] {
            dict.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(cap)
            .map { Row(["id": .string($0.key), "name": .string($0.key), "c": .int($0.value)]) }
        }
        let years = yearC.keys.sorted(by: >).prefix(40)
            .map { Row(["year": .string($0), "c": .int(yearC[$0] ?? 0)]) }
        return BrowseTaxonomyBundle(
            years: years, codes: rows(letterC, cap: 3000), makers: rows(makerC, cap: 500),
            tags: rows(tagC, cap: 500), fallback: false,
            ts: Int64(Date().timeIntervalSince1970 * 1000), source: "remote")
    }
}
#endif

// MARK: - TTL 页缓存（进程内；磁盘层 page_cache.db 接线留 P13 离线读源一并做）

protocol BrowseCacheStore {
    /// ttlMinutes > 0 且超期 → nil（行保留）
    func get(_ key: String, ttlMinutes: Int) -> [String: Any]?
    func put(_ key: String, _ payload: [String: Any])
    /// 无视 TTL 的旧缓存（SWR 回退 / 离线渲染）
    func stale(_ key: String) -> [String: Any]?
}

/// 进程内共享缓存（Android QCache 内存层对位；payload 直接持有 [Row] 值类型，线程安全）
final class MemoryBrowseCache: BrowseCacheStore {
    static let shared = MemoryBrowseCache()

    private struct Entry {
        var payload: [String: Any]
        var ts: Int64
    }

    private var dict: [String: Entry] = [:]
    private let lock = NSLock()

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    func get(_ key: String, ttlMinutes: Int) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard let e = dict[key] else { return nil }
        if ttlMinutes > 0 && Self.nowMs() - e.ts > Int64(ttlMinutes) * 60_000 { return nil }
        return e.payload
    }

    func put(_ key: String, _ payload: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        dict[key] = Entry(payload: payload, ts: Self.nowMs())
    }

    func stale(_ key: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return dict[key]?.payload
    }
}

// MARK: - 已读/收藏批量标记（A-1：列表页批量 IN 查，替代逐条单查）

struct BrowseMarkSource {
    var historySet: ([String]) -> Set<String>
    var favSet: ([String]) -> Set<String>

    static func empty() -> BrowseMarkSource {
        BrowseMarkSource(historySet: { _ in [] }, favSet: { _ in [] })
    }

    /// 生产：LocalStore（jdlv_local.db）；demo：DemoStore.favorites（仅收藏）。
    static func `default`() -> BrowseMarkSource {
        #if DEBUG
        if DemoDataSource.enabled() {
            return BrowseMarkSource(
                historySet: { _ in [] },
                favSet: { ids in
                    let favs = Set(DemoStore.shared.favList(kind: "movie").map { $0.s("id") })
                    return favs.intersection(ids)
                })
        }
        #endif
        guard let store = BrowseMarks.shared else { return .empty() }
        return BrowseMarkSource(
            historySet: { ids in (try? store.historySet(kind: "movie", ids: ids)) ?? [] },
            favSet: { ids in (try? store.favSet(kind: "movie", ids: ids)) ?? [] })
    }
}

/// LocalStore 单例宿主（App 壳层尚无全局 LocalStore，P9b 先落此处；后续页可复用）
enum BrowseMarks {
    static let shared: LocalStore? = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("jdlv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try? LocalStore(directory: dir.path)
    }()
}

// MARK: - BrowseVM（A.2 全契约）

@MainActor
final class BrowseVM: ObservableObject {

    /// 追加软上限（NA-22；到顶只能跳页，页面无额外提示文案）
    static let MAX_MERGED_ITEMS = 500

    // MARK: 数据源 / 缓存 / 加载器（可注入）

    let source: BrowseDataSource
    let cache: BrowseCacheStore
    let taxonomyLoader: BrowseTaxonomyLoader
    /// 已读/收藏批量查（BrowseView onAppear 注入默认实现；测试注入假源）
    var marks: BrowseMarkSource?
    /// 全局 Toast 通道（AppServices.showToast；测试注入收集器）
    var onToast: (String) -> Void
    /// 刷新结果通道（仅手动下拉路径写入；页面消费后 consume 清位）
    let refreshChannel = RefreshResultChannel()
    /// 设置桥（BrowseView 注入 SettingsStore；测试 nil —— syncFromSettings/落盘全部静默跳过）
    weak var store: SettingsStore?
    /// 可注入时钟（onDataEpoch 60s 冷却 / lastUpdatedAt 测试用）
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: 状态（C.1 BrowseUi 逐字段）

    @Published var loading = false
    @Published var refreshing = false
    @Published var loadingMore = false
    @Published var error: String? = nil
    /// null = 未首载（首载骨架）；非 null 保留旧值（SWR 不闪白）
    @Published var items: [Row]? = nil
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var per = 40
    @Published var viewMode = 0
    @Published var sort = "release_date"
    /// false=倒序（默认）
    @Published var asc = false
    @Published var f = Filters()
    @Published var years: [Row] = []
    @Published var codes: [Row] = []
    @Published var makers: [Row] = []
    @Published var tags: [Row] = []
    @Published var tagQuery = ""
    @Published var tagMode = "common"
    /// loading → remote | fallback | stale | assets
    @Published var filterSource = "loading"
    @Published var taxonomyTs: Int64 = 0
    @Published var lastUpdatedAt: Int64 = 0
    @Published var readIds: Set<String> = []
    @Published var favIds: Set<String> = []
    @Published var derived = ""
    @Published var approx = false
    @Published var hasMore = true

    // MARK: 内部

    /// keyset 锚点：anchors[page] = 本页末行键值（响应 anchor 字段；缓存命中/新鲜统一写入）
    private(set) var anchors: [Int: [String]] = [:]
    private var reqId = 0
    private var seenEpoch: Int = -1
    private var lastAutoAt: Int64 = 0

    /// TTL 用设置 filterTtl（默认 60 分钟）
    private var filterTtl: Int { store?.settings.filterTtl ?? 60 }

    init(
        source: BrowseDataSource? = nil,
        cache: BrowseCacheStore = MemoryBrowseCache.shared,
        taxonomyLoader: BrowseTaxonomyLoader? = nil,
        marks: BrowseMarkSource? = nil,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoBrowseDataSource() : QBrowseDataSource())
        #else
        self.source = source ?? QBrowseDataSource()
        #endif
        self.cache = cache
        #if DEBUG
        self.taxonomyLoader = taxonomyLoader
            ?? (DemoDataSource.enabled()
                ? DemoTaxonomyLoader()
                : ProductionTaxonomyLoader(cache: cache))
        #else
        self.taxonomyLoader = taxonomyLoader ?? ProductionTaxonomyLoader(cache: cache)
        #endif
        self.marks = marks
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    // MARK: 纯函数（VM/页面/测试共用）

    /// normSort：want→want_watch_count；白名单 {release_date,id,score,want_watch_count}，其余 → release_date
    static func normSort(_ v: String) -> String {
        if v == "want" { return "want_watch_count" }
        return Q.BROWSE_SORT_KEYS.contains(v) ? v : "release_date"
    }

    /// {f} 键段（Kotlin data class toString 形态；12 字段全量进键）
    static func filterKey(_ f: Filters) -> String {
        "Filters(year=\(f.year), month=\(f.month), maker=\(f.maker), letter=\(f.letter), "
            + "tags=\(f.tags), magnet=\(f.magnet), cnsub=\(f.cnsub), canPlay=\(f.canPlay), "
            + "single=\(f.single), seriesId=\(f.seriesId), directorId=\(f.directorId), "
            + "publisherId=\(f.publisherId))"
    }

    /// 列表缓存键：browse:{f}:{sort}:{asc}:{per}:{page}（⚠ 必须含 asc，正/倒序不互读缓存）
    static func listCacheKey(f: Filters, sort: String, asc: Bool, per: Int, page: Int) -> String {
        "browse:\(filterKey(f)):\(sort):\(asc):\(per):\(page)"
    }

    /// 计数缓存键：bcount:{f}:{sort}（TTL 5 分钟）
    static func countCacheKey(f: Filters, sort: String) -> String {
        "bcount:\(filterKey(f)):\(sort)"
    }

    /// filterCount = 非空文本筛选（year/month/maker/letter/seriesId/directorId/publisherId/tags）
    /// 个数 + 为真开关（magnet/cnsub/canPlay/single）个数
    var filterCount: Int {
        var n = 0
        for v in [f.year, f.month, f.maker, f.letter, f.seriesId, f.directorId, f.publisherId, f.tags]
        where !v.isEmpty { n += 1 }
        for b in [f.magnet, f.cnsub, f.canPlay, f.single] where b { n += 1 }
        return n
    }

    /// 反查摘要条拼接（A.2 逐字）：前缀「反查：」+ 各条件 " · " 连接；无条件 → nil
    static func lookupSummary(_ f: Filters) -> String? {
        var parts: [String] = []
        if !f.letter.isEmpty { parts.append("番号:\(f.letter)") }        // 半角冒号
        if !f.maker.isEmpty { parts.append("片商") }                     // 仅类别名不带值
        if !f.seriesId.isEmpty { parts.append("系列") }
        if !f.directorId.isEmpty { parts.append("导演") }
        if !f.publisherId.isEmpty { parts.append("发行商") }
        if !f.year.isEmpty { parts.append("年份:\(f.year)") }
        if !f.month.isEmpty { parts.append("月份:\(f.month)") }
        let tagN = f.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.count
        if tagN > 0 { parts.append("标签×\(tagN)") }
        if f.magnet { parts.append("有磁力") }
        if f.cnsub { parts.append("中字") }                              // ⚠ 摘要「中字」≠面板 chip「中文字幕」
        if f.canPlay { parts.append("可播") }
        if f.single { parts.append("单体") }
        guard !parts.isEmpty else { return nil }
        return "反查：" + parts.joined(separator: " · ")
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

    // MARK: 生命周期（C.2）

    /// bind：seenEpoch<0 记当前 epoch（进入页面不刷）；years/makers 均空 → loadFilters+reload；
    /// 否则仅 syncFromSettings（回读 viewMode/per/sort/asc）
    func bind(dataEpoch: Int) async {
        if seenEpoch < 0 { seenEpoch = dataEpoch }
        if years.isEmpty && makers.isEmpty {
            await loadFilters()
            await reload()
        } else {
            syncFromSettings()
        }
    }

    /// dataEpoch 变更（数据源/代理/图床/库名/超时）：v<=0 || v==seenEpoch 忽略；
    /// 首次（seenEpoch<0）只记录；60s 冷却（RefreshPolicy）内打点 skip；
    /// 允许 → reload(force=true, auto=true) 静默（不写 refreshResult）
    func onDataEpoch(_ v: Int) async {
        if v <= 0 || v == seenEpoch { return }
        if seenEpoch < 0 { seenEpoch = v; return }
        let now = nowMs()
        guard RefreshPolicy.shouldAuto(lastAutoAt, now: now) else { return }
        seenEpoch = v
        lastAutoAt = now
        await reload(force: true, auto: true)
    }

    /// 设置回读（viewMode/per/sort/asc；store 未注入 → 静默跳过）
    func syncFromSettings() {
        guard let s = store?.settings else { return }
        viewMode = s.viewMode
        per = normalizePer(s.perPage)
        sort = Self.normSort(s.jdbSort)
        asc = s.jdbSortAsc
    }

    // MARK: 查询与刷新语义（C.3）

    /// reload：loading 仅首载骨架（items==nil）、refreshing=force、error 清位、
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

    /// refetch（setSort/setSortAsc/setPer 专用）：iOS 侧 setter 先写 state 不回读 prefs，
    /// 与 Android 语义等价
    private func refetch() async {
        await reload()
    }

    /// fetch：rid 竞态守卫 → TTL 缓存 → Q 层 → stale 兜底 → ErrText
    private func fetch(append: Bool, fromRefresh: Bool) async {
        reqId += 1
        let rid = reqId
        let targetPage = append ? page + 1 : page
        if !append { anchors.removeAll() }   // 筛选/排序/跳页变化锚点作废（NA-34）
        let key = Self.listCacheKey(f: f, sort: sort, asc: asc, per: per, page: targetPage)
        // ① TTL 内缓存命中（路径一致，同样写锚点/计数）
        if let hit = cache.get(key, ttlMinutes: filterTtl) {
            apply(hit, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
            await countIfNeeded(rid: rid, append: append, targetPage: targetPage)
            return
        }
        do {
            // ② 远程（append 用 anchors[page] 查 page+1；keyset 非空走 O(1) 续页）
            let anchor = append ? anchors[page] : nil
            let d = try await source.browse(
                f: f, page: targetPage, per: per, sort: sort, asc: asc, anchor: anchor)
            guard rid == reqId else { return }   // 旧响应一律丢弃
            cache.put(key, d)
            apply(d, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
            await countIfNeeded(rid: rid, append: append, targetPage: targetPage)
        } catch {
            // ③ stale（无视 TTL）→ SWR 回退；无 stale → ErrText + fromRefresh 时 Fail
            guard rid == reqId else { return }
            if let stale = cache.stale(key) {
                apply(stale, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
                await countIfNeeded(rid: rid, append: append, targetPage: targetPage)
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

    private func countIfNeeded(rid: Int, append: Bool, targetPage: Int) async {
        if !append && targetPage == 1 {
            await fetchCount(rid: rid)
        }
    }

    /// apply：append 按 id 去重拼接；写锚点；total<0 不回退；hasMore=满页推断；
    /// refreshResult 仅手动下拉路径写入；首屏异步计数
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
        // keyset 锚点：本页末行键值（缓存命中/新鲜统一在此写；空 → OFFSET 跳页路径）
        if let a = d["anchor"] as? [String], !a.isEmpty {
            anchors[targetPage] = a
        } else {
            anchors.removeValue(forKey: targetPage)
        }
        // total<0 = 未知 → 保留已异步到达的计数不回退
        if let t = Self.numOf(d, "total"), t >= 0 { total = t }
        hasMore = fresh.count >= max(1, per)   // 按满页推断（total 未知也能翻页）
        approx = (d["approx"] as? Bool) == true
        derived = d["derived"] as? String ?? ""
        lastUpdatedAt = nowMs()
        loading = false
        refreshing = false
        loadingMore = false
        if fromRefresh { refreshChannel.emit(.done(merged.count)) }
        // 已读/收藏批量查（A-1；跨页累积 union）
        if let marks = marks {
            let ids = merged.map { $0.s("id") }.filter { !$0.isEmpty }
            if !ids.isEmpty {
                let read = marks.historySet(ids)
                let fav = marks.favSet(ids)
                if rid == reqId {
                    readIds = readIds.union(read)
                    favIds = favIds.union(fav)
                }
            }
        }
        // TODO(P13): 影子兜底在线回填封面 —— !append && merged 非空 && derived 含「本地缓存」时
        // 后台 Q.movieCovers(ids) 回填 cover_url（rid 校验后），不动滚动位置。
    }

    /// 首屏异步计数：bcount:{f}:{sort} TTL 5 分钟；Q.browseCount 失败 -1 → 保持「已加载 N 条」
    /// （-1 不落缓存，避免瞬时失败把计数通道封死 5 分钟）
    private func fetchCount(rid: Int) async {
        let key = Self.countCacheKey(f: f, sort: sort)
        if let hit = cache.get(key, ttlMinutes: 5), let c = Self.numOf(hit, "count") {
            if rid == reqId && c >= 0 { total = c }
            return
        }
        let c = await source.browseCount(f: f, sort: sort)
        guard rid == reqId else { return }
        if c >= 0 {
            cache.put(key, ["count": c])
            total = c
        }
    }

    // MARK: 翻页

    /// loadNext：守卫（loading/refreshing/loadingMore/items 空/!hasMore）+ 500 软上限
    func loadNext() async {
        if loading || refreshing || loadingMore { return }
        guard let it = items, !it.isEmpty else { return }
        guard hasMore else { return }
        guard it.count < Self.MAX_MERGED_ITEMS else { return }
        loadingMore = true
        await fetch(append: true, fromRefresh: false)
    }

    /// goPage：PaginationGuard 钳制（5000 行硬帽）→ 钳制且 p>1 → Toast → reload(keepPage=true)
    func goPage(_ p: Int) async {
        let d = PaginationGuard.clamp(requested: p, total: total, per: per)
        if d.clamped && p > 1 {
            onToast(AppCopy.tooDeepToast(maxPage: d.page))
        }
        page = d.page
        await reload(keepPage: true)
    }

    // MARK: 筛选入口（C.4：全部 page=1 重查，SWR 保留旧列表）

    /// setFilter：f 变换 + page=1 → fetch
    func setFilter(_ mut: (inout Filters) -> Void) async {
        var nf = f
        mut(&nf)
        f = nf
        page = 1
        loading = items == nil
        error = nil
        await fetch(append: false, fromRefresh: false)
    }

    /// toggleTag：f.tags CSV 增删 + page=1 → fetch
    func toggleTag(_ id: String) async {
        var nf = f
        nf.toggleTag(id)
        f = nf
        page = 1
        loading = items == nil
        error = nil
        await fetch(append: false, fromRefresh: false)
    }

    private func toggleFlag(_ kp: WritableKeyPath<Filters, Bool>) async {
        var nf = f
        nf[keyPath: kp].toggle()
        f = nf
        page = 1
        loading = items == nil
        error = nil
        await fetch(append: false, fromRefresh: false)
    }

    func toggleMagnet() async { await toggleFlag(\.magnet) }
    func toggleCnsub() async { await toggleFlag(\.cnsub) }
    func toggleCanPlay() async { await toggleFlag(\.canPlay) }
    func toggleSingle() async { await toggleFlag(\.single) }

    /// clearFilters：f=Filters() + page=1 → fetch（不清排序/视图/每页）
    func clearFilters() async {
        f = Filters()
        page = 1
        loading = items == nil
        error = nil
        await fetch(append: false, fromRefresh: false)
    }

    /// applyFilters：反查跳转入口（LookupScreen 调）——anchors 清空 + syncFromSettings +
    /// f 覆盖 + page=1；sortOverride 非空 → 覆盖 sort（normSort）且 **asc 恒 false（倒序）**
    func applyFilters(_ nf: Filters, sortOverride: String? = nil) async {
        anchors.removeAll()
        syncFromSettings()
        f = nf
        page = 1
        loading = items == nil
        error = nil
        if let s = sortOverride {
            sort = Self.normSort(s)
            asc = false   // 反查带排序恒倒序（修"写 settings 再回读"竞态导致的排序丢失）
        }
        await fetch(append: false, fromRefresh: false)
    }

    // MARK: 排序 / 每页 / 视图 setter（先写 state → 落盘 → refetch，不回读 prefs）

    func setSort(_ v: String) async {
        sort = Self.normSort(v)
        store?.updateSettings { $0.jdbSort = self.sort }
        await refetch()
    }

    /// 落盘 jdbSortAsc（纯展示设置，不重建连接）
    func setSortAsc(_ v: Bool) async {
        asc = v
        store?.updateSettings { $0.jdbSortAsc = v }
        await refetch()
    }

    /// normalizePer 吸附到 20/40/60/80/100 档
    func setPer(_ v: Int) async {
        per = normalizePer(v)
        store?.updateSettings { $0.perPage = self.per }
        await refetch()
    }

    /// 仅改 state + 落盘，不重查
    func setViewMode(_ v: Int) {
        viewMode = v
        store?.updateSettings { $0.viewMode = v }
    }

    /// 仅改 state，不发查询（即时过滤面板 chips）
    func setTagQuery(_ v: String) { tagQuery = v }
    func setTagMode(_ v: String) { tagMode = v }

    // MARK: 筛选索引加载（A.7 loadFilters）

    /// 链路：缓存 jdb_taxonomy(24h) → Q.taxonomy() → stale → Q.filters()(assets)；
    /// 加载失败静默（不阻塞浏览）；taxonomyTs 秒级落盘（B.5 规则 7）
    func loadFilters() async {
        let b = await taxonomyLoader.load()
        years = b.years
        codes = b.codes
        makers = b.makers
        tags = b.tags
        filterSource = b.source
        taxonomyTs = b.ts
        if b.ts > 0 {
            store?.updateSettings { $0.taxonomyTs = b.ts / 1000 }
        }
    }
}
