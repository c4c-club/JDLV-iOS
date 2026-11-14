import Foundation
import JDLVCore

//
//  ShtVM.swift —— 98t 帖子列表 VM（09 C 节 / 14_vm_tests A.4 全契约）。
//
//  状态（A.4 ShtUi 逐字段）：queryState（单向数据流，唯一写点 setQuery）/
//  loading/refreshing/loadingMore/error/items(nil=未首载)/covers(Map tid→url)/total/page/
//  per=20/viewMode/hasMagnet/fuzzy=false/semantic=false/sort="date"/main/cat/type/
//  mains/subs/types/catTs/readIds/favIds/derived/lastUpdatedAt/hasMore/refreshResult。
//
//  契约（C9 / A.0 / A.4）：
//  - 竞态 rid：fetch 前 reqId++；apply/catch 先校验 rid != reqId → 整体丢弃
//    （含缓存命中路径与 stale 回退路径；失败结果也不得覆盖新请求）。
//  - SWR：reload/筛选变化保留旧 items（loading 只在 items==null 首载骨架）。
//  - 缓存键 "sht_list:{main}:{cat}:{type}:{q}:{hasMagnet}:{fuzzy}:{semantic}:{sort}:{per}:{page}"
//    TTL 5 分钟 —— 键必须含 semantic（A-19：否则「精确」与「语义」同键串味）。
//  - keyset 锚点 anchors[page] = Pair(排序键值, tid)：ShtSearch.orderColOf(sort)
//    （updated→last_checked / 空值回落 post_date）取 fresh.last() 列值 + tid；
//    fuzzy||semantic 无锚点（置 null）；append 成功也写锚点（P5.3：否则第二页后锚点丢失）；
//    goPage/非 append fetch 清空（NA-34：换排序/筛选后列语义变了）。
//  - 模式互斥：toggleFuzzy/toggleSemantic 开一个关另一个 + 清锚点 + reload（NA-06）。
//  - MAX_MERGED_ITEMS = 500 追加软上限（到顶只能跳页）。
//  - hasMore 按满页推断（本页条数 >= per）；total<0 不回退已异步到达的计数（铁律 20）。
//  - 计数：Q.shtBrowseCount 首屏（非 append 且 page==1）异步，失败静默保持 -1。
//  - 语义：SemanticUnavailableError = 明确业务态 error=e.message（默认「语义模型未导入」），
//    不进 stale 兜底；其余异常 stale → ErrText.of(e)。
//  - 分类 "sht_cat" TTL 24h；loadCats(force)：force 跳缓存；链 get → stale → Q.shtCategories()。
//    bind 延后（S11-P6）：首屏落地（items != nil）后 ≥200ms 再 loadCats(false) —— 简化
//    Android「轮询 items!=nil 最多 3000ms（150ms 步进）+ delay 200ms」为固定 200ms 延迟
//    （iOS bind 同步 await reload，reload 返回即落地）。
//  - exportLinks：Q.shtExport 流式回调 → cacheDir/share/jdlv_export_{ts}.txt
//    （写前清空 share 目录只留最新一份，A-11）；格式逐字见 ShtExportComposer；
//    n==0 删文件返回 null。
//  - setter 先写 state 再 refetch，不从 prefs 回读（S11-P2 模式）。
//  - demo 模式（仅 DEBUG）：与生产同一 ShtDataSource 协议注入 DemoStore。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

/// 98t 数据源（Q.shtBrowse / Q.shtBrowseCount / Q.shtCategories / Q.shtExport 簽名对位）
protocol ShtDataSource {
    /// 对齐 Q.shtBrowse：返回 items/total(-1 未知)/covers/derived/page（键名与 Android 逐字一致）
    func shtBrowse(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool,
        page: Int, per: Int, anchor: (String, String)?, mode: String, sort: String,
        cand: Int, threshold: Float
    ) async throws -> [String: Any]
    /// 失败返回 -1（UI 保持「已加载 N 条」）
    func shtBrowseCount(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool, sort: String
    ) async -> Int64
    /// 对齐 Q.shtCategories：mains/subs/types（[Row]）+ total + ts
    func shtCategories() async throws -> [String: Any]
    /// 对齐 Q.shtExport 流式回调（行键 tid/title/date/kind/link/size；kind 磁力/ED2K/视频）
    func shtExport(
        main: String, cat: String, type: String, q: String,
        onRows: ([Row]) async -> Void
    ) async throws
    /// 对齐 Q.shtThread（详情 VM 用）：thread 主行 + magnets/ed2k/images/videos/blocks/words
    func shtThread(tid: String) async throws -> [String: Any]?
}

/// 生产数据源（Q 层；离线回落/探活/影子兜底全在 Q 层内）
struct QShtDataSource: ShtDataSource {
    func shtBrowse(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool,
        page: Int, per: Int, anchor: (String, String)?, mode: String, sort: String,
        cand: Int, threshold: Float
    ) async throws -> [String: Any] {
        try await Q.shtBrowse(
            main: main, cat: cat, type: type, q: q, hasMagnet: hasMagnet,
            page: page, per: per, anchor: anchor, mode: mode, sort: sort,
            cand: cand, threshold: threshold)
    }

    func shtBrowseCount(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool, sort: String
    ) async -> Int64 {
        await Q.shtBrowseCount(
            main: main, cat: cat, type: type, q: q, hasMagnet: hasMagnet, sort: sort)
    }

    func shtCategories() async throws -> [String: Any] {
        try await Q.shtCategories()
    }

    func shtExport(
        main: String, cat: String, type: String, q: String,
        onRows: ([Row]) async -> Void
    ) async throws {
        try await Q.shtExport(
            main: main, cat: cat, type: type, dFrom: "", dTo: "", q: q,
            maxThreads: 800, onRows: onRows)
    }

    func shtThread(tid: String) async throws -> [String: Any]? {
        try await Q.shtThread(tid: tid)
    }
}

// MARK: - TTL 页缓存（复用 BrowseVM 的进程内共享 MemoryBrowseCache：Android QCache 对位）

protocol ShtCacheStore {
    /// ttlMinutes > 0 且超期 → nil（行保留）
    func get(_ key: String, ttlMinutes: Int) -> [String: Any]?
    func put(_ key: String, _ payload: [String: Any])
    /// 无视 TTL 的旧缓存（SWR 回退 / 离线渲染）
    func stale(_ key: String) -> [String: Any]?
}

/// MemoryBrowseCache（Features/Browse/BrowseVM.swift 的进程内共享缓存）追加遵约 ——
/// 98t 列表/分类与浏览页共用同一 Android QCache 对位实例，跨页不互串（键前缀隔离）。
extension MemoryBrowseCache: ShtCacheStore {}

// MARK: - 已读/收藏批量标记（E9：kind = "sht"）

struct ShtMarkSource {
    // R4 P6：标记闭包 async（LocalStoreActor 串行后台执行，SQLite 离主线程）
    var historySet: ([String]) async throws -> Set<String>
    var favSet: ([String]) async throws -> Set<String>
    var historyIs: (String) async -> Bool
    var favIs: (String) async -> Bool
    var historyMark: (String, String) async -> Void
    var favToggle: (String, String) async -> Bool

    static func empty() -> ShtMarkSource {
        ShtMarkSource(
            historySet: { _ in [] }, favSet: { _ in [] },
            historyIs: { _ in false }, favIs: { _ in false },
            historyMark: { _, _ in }, favToggle: { _, _ in false })
    }

    /// 生产：LocalStore（jdlv_local.db）；demo：DemoStore.favorites（仅收藏读；
    /// 收藏切换走进程内 Set —— DemoStore 无写入口，不改 Services 文件）。
    static func `default`() -> ShtMarkSource {
        #if DEBUG
        if DemoDataSource.enabled() {
            return ShtMarkSource(
                historySet: { _ in [] },
                favSet: { ids in
                    let favs = Set(DemoStore.shared.favList(kind: "sht").map { $0.s("id") })
                    return favs.intersection(ids)
                },
                historyIs: { _ in false },
                favIs: { tid in DemoShtFavs.contains(tid) },
                historyMark: { _, _ in },
                favToggle: { tid, title in
                    DemoStore.shared.favList(kind: "sht").contains { $0.s("id") == tid }
                        ? false   // 预置收藏行不在此切换（demo 只演示 UI 链路）
                        : DemoShtFavs.toggle(tid)
                })
        }
        #endif
        // R4 P6：闭包内首次经 BrowseMarks.open() 后台打开；单条查询失败按未标记展示
        // （列表 badge 语义；错误呈现门禁 V42 由 FavsVM/BrowseVM 承担）
        return ShtMarkSource(
            historySet: { ids in
                guard let a = await BrowseMarks.open() else { return [] }
                return (try? await a.historySet(kind: "sht", ids: ids)) ?? []
            },
            favSet: { ids in
                guard let a = await BrowseMarks.open() else { return [] }
                return (try? await a.favSet(kind: "sht", ids: ids)) ?? []
            },
            historyIs: { tid in
                guard let a = await BrowseMarks.open() else { return false }
                return (try? await a.historyIs(kind: "sht", id: tid)) ?? false
            },
            favIs: { tid in
                guard let a = await BrowseMarks.open() else { return false }
                return (try? await a.favIs(kind: "sht", id: tid)) ?? false
            },
            historyMark: { tid, title in
                guard let a = await BrowseMarks.open() else { return }
                _ = try? await a.historyMark(kind: "sht", id: tid, title: title)
            },
            favToggle: { tid, title in
                guard let a = await BrowseMarks.open() else { return false }
                return (try? await a.favToggle(kind: "sht", id: tid, title: title)) ?? false
            })
    }
}

// MARK: - demo 收藏进程内存（DEBUG；DemoStore 无写入口的对位补丁）

#if DEBUG
enum DemoShtFavs {
    private static var set: Set<String> = []
    static func contains(_ id: String) -> Bool { set.contains(id) }
    /// true = 切换后为已收藏
    static func toggle(_ id: String) -> Bool {
        if set.contains(id) { set.remove(id); return false }
        set.insert(id)
        return true
    }
}
#endif

// MARK: - 导出 txt 组装（C4 格式逐字；纯函数供测试）

enum ShtExportComposer {
    /// 首行：`# 导出: 主版=${main} 副版=${cat} 类型=${type}` +（有搜索词时）` 搜索=${q}`（半角冒号）
    static func header(main: String, cat: String, type: String, q: String) -> String {
        var line = "# 导出: 主版=\(main) 副版=\(cat) 类型=\(type)"
        if !q.isEmpty { line += " 搜索=\(q)" }
        return line + "\n"
    }

    /// 每帖首行（tid 变化时）：`"\n[${post_date}] ${title}\n"`
    static func threadHeader(date: String, title: String) -> String {
        "\n[\(date)] \(title)\n"
    }

    /// 每链接一行：`"${kind}: ${link}"` +（size 非空时）`" (${size})"`（半角冒号+空格）
    static func linkLine(kind: String, link: String, size: String) -> String {
        var line = "\(kind): \(link)"
        if !size.isEmpty { line += " (\(size))" }
        return line + "\n"
    }

    /// 流式行 → 全文（行序保持；tid 变化时插帖头；磁力 link = magnet:?xt=urn:btih:<hash> 已由 Q 拼）
    static func assemble(_ rows: [Row], main: String, cat: String, type: String, q: String) -> String {
        var out = header(main: main, cat: cat, type: type, q: q)
        var lastTid = ""
        for r in rows {
            let tid = r.s("tid")
            if tid != lastTid {
                out += threadHeader(date: r.s("date"), title: r.s("title"))
                lastTid = tid
            }
            out += linkLine(kind: r.s("kind"), link: r.s("link"), size: r.s("size"))
        }
        return out
    }
}

// MARK: - 导出结果（UI 分享用）

struct ShtExportResult: Identifiable {
    let url: URL
    let count: Int
    var id: String { url.absoluteString }
}

// MARK: - ShtVM（A.4 全契约）

@MainActor
final class ShtVM: ObservableObject {

    /// 追加软上限（E8；到顶只能跳页，页面无额外提示文案）
    static let MAX_MERGED_ITEMS = 500
    /// 列表缓存 TTL（分钟）
    static let LIST_TTL_MINUTES = 5
    /// 分类索引缓存键 + TTL（24 小时）
    static let CAT_KEY = "sht_cat"
    static let CAT_TTL_MINUTES = 24 * 60

    // MARK: 数据源 / 缓存 / 标记（可注入）

    let source: ShtDataSource
    let cache: ShtCacheStore
    /// 已读/收藏批量查（ShtView onAppear 注入默认实现；测试注入假源）
    var marks: ShtMarkSource?
    /// 全局 Toast 通道（AppServices.showToast；测试注入收集器）
    var onToast: (String) -> Void
    /// 「语义」未导入模型时跳设置（C5：nav("settings")——不静默降级；视图注入切 tab）
    var onOpenSettings: () -> Void
    /// 语义模型导入判定（生产 OnnxEmbedder.isInstalled()；测试注入）
    var semanticInstalled: () -> Bool
    /// 设置桥（ShtView 注入 SettingsStore；测试 nil —— syncFromSettings/落盘全部静默跳过）
    weak var store: SettingsStore?
    /// 可注入时钟（lastUpdatedAt / 导出文件名 ts / 分类延后计时测试用）
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    /// 导出目录（cacheDir/share；测试注入临时目录）
    var exportDirectory: () -> URL = {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return cache.appendingPathComponent("share", isDirectory: true)
    }
    /// 分类延后时长（S11-P6 简化：Android 3s 轮询 + 200ms → 固定 200ms；测试可改 0）
    var catsDelayMs: UInt64 = 200

    // MARK: 状态（A.4 ShtUi 逐字段）

    /// queryState 单向数据流：唯一写点 setQuery()（C9）
    @Published private(set) var queryState = ""
    @Published var loading = false
    @Published var refreshing = false
    @Published var loadingMore = false
    @Published var error: String? = nil
    /// null = 未首载（首载骨架）；非 null 保留旧值（SWR 不闪白）
    @Published var items: [Row]? = nil
    /// tid → url（非 append 查询替换整张 map 防旧 tid 残留，NA-22；append 合并）
    @Published var covers: [String: String] = [:]
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var per = 20
    @Published var viewMode = 0
    @Published var hasMagnet = false
    @Published var fuzzy = false
    @Published var semantic = false
    @Published var sort = "date"
    @Published var main = ""
    @Published var cat = ""
    @Published var type = ""
    @Published var mains: [Row] = []
    @Published var subs: [Row] = []
    @Published var types: [Row] = []
    @Published var catTs: Int64 = 0
    @Published var readIds: Set<String> = []
    @Published var favIds: Set<String> = []
    @Published var derived = ""
    @Published var lastUpdatedAt: Int64 = 0
    @Published var hasMore = true

    // MARK: 内部

    /// keyset 锚点：anchors[page] = Pair(排序键值, tid)（第 N 页锚点给第 N+1 页用）
    private(set) var anchors: [Int: (String, String)] = [:]
    private var reqId = 0
    private var boundOnce = false

    init(
        source: ShtDataSource? = nil,
        cache: ShtCacheStore = MemoryBrowseCache.shared,
        marks: ShtMarkSource? = nil,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoShtDataSource() : QShtDataSource())
        #else
        self.source = source ?? QShtDataSource()
        #endif
        self.cache = cache
        self.marks = marks
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
        self.onOpenSettings = {}
        #if DEBUG
        self.semanticInstalled = { DemoDataSource.enabled() ? false : OnnxEmbedder.isInstalled() }
        #else
        self.semanticInstalled = { OnnxEmbedder.isInstalled() }
        #endif
    }

    // MARK: 纯函数（VM/页面/测试共用）

    /// 列表缓存键（A-19：必须含 semantic，否则「精确」与「语义」同键串味）
    static func listCacheKey(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool,
        fuzzy: Bool, semantic: Bool, sort: String, per: Int, page: Int
    ) -> String {
        "sht_list:\(main):\(cat):\(type):\(q):\(hasMagnet):\(fuzzy):\(semantic):\(sort):\(per):\(page)"
    }

    /// 锚点取值：fresh.last() 的 orderColOf(sort) 列值（updated→last_checked，date→post_date；
    /// 空值回落 post_date）+ tid；行空 → nil
    static func anchorOf(_ rows: [Row], sort: String) -> (String, String)? {
        guard let last = rows.last else { return nil }
        let col = ShtSearch.orderColOf(sort: sort)
        var v = last.s(col)
        if v.isEmpty { v = last.s("post_date") }   // 空值回落 post_date
        let tid = last.s("tid")
        if tid.isEmpty { return nil }
        return (v, tid)
    }

    /// mode 参数：semantic→"semantic"，fuzzy→"fuzzy"，否则 "exact"（C9）
    static func modeOf(fuzzy: Bool, semantic: Bool) -> String {
        semantic ? "semantic" : (fuzzy ? "fuzzy" : "exact")
    }

    /// filterCount = main/cat/type 非空个数 + (hasMagnet ? 1 : 0)（C3）
    var filterCount: Int {
        var n = 0
        for v in [main, cat, type] where !v.isEmpty { n += 1 }
        if hasMagnet { n += 1 }
        return n
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

    /// Img.shtCover() 对位：98t 远程原始 URL 不走 jdb 图床；空/非 http → 无图；
    /// 分桶或单 URL 冷却命中 → 空串（触发静态占位）（E10）
    static func shtCoverUrl(_ raw: String) -> String {
        let u = raw.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, u.hasPrefix("http") else { return "" }
        return ImgBreaker.shared.isCooling(url: u) ? "" : u
    }

    /// 卡片封面 URL：covers map 优先（tid→url），为空回退行内 cover/cover_url（P3.8）
    func coverUrl(tid: String, row: Row) -> String {
        let raw = covers[tid]
            ?? (row.s("cover").isEmpty ? row.s("cover_url") : row.s("cover"))
        return Self.shtCoverUrl(raw)
    }

    // MARK: queryState（C9：唯一写点）

    /// 唯一写点；提交走 search(queryState)（不 trim，Q 层自行 trim）
    func setQuery(_ q: String) { queryState = q }

    /// 搜索提交（C2：提交 → search(queryState.value)；不 trim）
    func search(_ q: String? = nil) async {
        if let q = q { setQuery(q) }
        page = 1
        await reload()
    }

    // MARK: 生命周期（C8 bind / C9）

    /// bind：首次进入先 reload() 列表（分类聚合延后）；非首次 bind 同步 viewMode/shtHasMagnet/shtPer
    func bind(dataEpoch: Int) async {
        if boundOnce {
            syncFromSettings()
            return
        }
        boundOnce = true
        syncFromSettings()
        await reload()
        // 分类延后（S11-P6）：首屏落地（items != nil）后 ≥200ms 再 loadCats(false)，
        // 避免与首屏并发抢连接 —— 简化 Android「轮询 items!=nil 最多 3000ms（150ms 步进）
        // + delay 200ms」为固定 200ms 延迟（iOS bind 同步 await reload，返回即已落地）。
        if items != nil {
            try? await Task.sleep(nanoseconds: catsDelayMs * 1_000_000)
            await loadCats(force: false)
        }
    }

    /// 设置回读（viewMode/shtHasMagnet/shtPer；store 未注入 → 静默跳过）
    func syncFromSettings() {
        guard let s = store?.settings else { return }
        viewMode = s.viewMode
        hasMagnet = s.shtHasMagnet
        per = normalizePer(s.shtPer, default: 20)
    }

    // MARK: 查询与刷新语义

    /// reload：loading 仅首载骨架（items==nil）、refreshing=force、error 清位、
    /// page = keepPage ? 当前 : 1（NA-01 跳页保页码）
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

    /// fetch：rid 竞态守卫 → TTL 缓存 → Q 层 → stale 兜底 → ErrText
    private func fetch(append: Bool, fromRefresh: Bool) async {
        reqId += 1
        let rid = reqId
        let targetPage = append ? page + 1 : page
        if !append { anchors.removeAll() }   // NA-34：筛选/排序/跳页变化锚点作废
        let key = Self.listCacheKey(
            main: main, cat: cat, type: type, q: queryState, hasMagnet: hasMagnet,
            fuzzy: fuzzy, semantic: semantic, sort: sort, per: per, page: targetPage)
        // ① TTL 内缓存命中（路径一致，同样写锚点/计数）
        if let hit = cache.get(key, ttlMinutes: Self.LIST_TTL_MINUTES) {
            await apply(hit, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
            await countIfNeeded(rid: rid, append: append, targetPage: targetPage)
            return
        }
        do {
            // ② 远程：append 用 anchors[page]（当前页末行锚点）查下一页；
            //    fuzzy/semantic 无锚点（这两模式无 keyset）
            var anchor: (String, String)? = append ? anchors[page] : nil
            if fuzzy || semantic { anchor = nil }
            let d = try await source.shtBrowse(
                main: main, cat: cat, type: type, q: queryState, hasMagnet: hasMagnet,
                page: targetPage, per: per, anchor: anchor,
                mode: Self.modeOf(fuzzy: fuzzy, semantic: semantic), sort: sort,
                cand: store?.settings.semCand ?? 3000,
                threshold: Float(store?.settings.semThreshold ?? 10) / 100.0)
            guard rid == reqId else { return }   // 旧响应一律丢弃
            cache.put(key, d)
            await apply(d, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
            await countIfNeeded(rid: rid, append: append, targetPage: targetPage)
        } catch {
            guard rid == reqId else { return }
            // ★ 语义模型未导入 = 明确业务态：不进 stale 兜底（C9/A.4）
            if error is SemanticUnavailableError {
                loading = false
                refreshing = false
                loadingMore = false
                self.error = Self.semanticMessage(error)
                return
            }
            // ③ stale（无视 TTL）→ SWR 回退；无 stale → ErrText + fromRefresh 时 Fail
            if let stale = cache.stale(key) {
                await apply(stale, rid: rid, append: append, targetPage: targetPage, fromRefresh: fromRefresh)
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

    /// SemanticUnavailableError → e.message（默认「语义模型未导入」）
    static func semanticMessage(_ e: Error) -> String {
        if let s = e as? SemanticUnavailableError {
            return s.message.isEmpty ? "语义模型未导入" : s.message
        }
        return "语义模型未导入"
    }

    private func countIfNeeded(rid: Int, append: Bool, targetPage: Int) async {
        guard !append, targetPage == 1 else { return }
        // 首屏异步计数：Q.shtBrowseCount 失败 -1 → 静默保持（无计数缓存键，E4 表无 sht 计数项）
        let c = await source.shtBrowseCount(
            main: main, cat: cat, type: type, q: queryState,
            hasMagnet: hasMagnet, sort: sort)
        guard rid == reqId else { return }
        if c >= 0 { total = c }   // total<0（未知）不回退已异步到达的计数
    }

    /// apply：append 按 tid 去重拼接；写锚点（append 也写，P5.3）；fuzzy/semantic 不写；
    /// covers 非 append 替换整张（NA-22）+ 空 map 时行内兜底（P3.8）；total<0 不回退；
    /// hasMore=满页推断；readIds/favIds 批量 union
    private func apply(
        _ d: [String: Any], rid: Int, append: Bool, targetPage: Int, fromRefresh: Bool
    ) async {
        guard rid == reqId else { return }
        let fresh = d["items"] as? [Row] ?? []
        let prev = items ?? []
        let merged: [Row]
        if append {
            var seen = Set(prev.map { $0.s("tid") })
            merged = prev + fresh.filter { seen.insert($0.s("tid")).inserted }
        } else {
            merged = fresh
        }
        items = merged
        page = targetPage
        // keyset 锚点：本页末行（排序键值, tid）；fuzzy/semantic 无锚点；
        // append 成功也写（P5.3：否则第二页后锚点丢失）
        if !fuzzy && !semantic, let a = Self.anchorOf(fresh, sort: sort) {
            anchors[targetPage] = a
        } else {
            anchors.removeValue(forKey: targetPage)
        }
        // total<0 = 未知 → 保留已异步到达的计数不回退
        if let t = Self.numOf(d, "total"), t >= 0 { total = t }
        hasMore = fresh.count >= max(1, per)   // 按满页推断（total 未知也能翻页）
        derived = d["derived"] as? String ?? ""
        lastUpdatedAt = nowMs()
        loading = false
        refreshing = false
        loadingMore = false
        if fromRefresh { refreshChannel.emit(.done(merged.count)) }
        // covers：非 append 查询替换整张 map（防旧 tid 残留，NA-22），追加时合并（P3.8 前段）
        var nextCovers = append ? covers : [:]
        let resp = d["covers"] as? [String: String] ?? [:]
        for (k, v) in resp { nextCovers[k] = v }
        // 兜底：covers 为空时用 items 内 cover/cover_url 填 map（P3.8）
        if resp.isEmpty {
            for r in fresh {
                let u = r.s("cover").isEmpty ? r.s("cover_url") : r.s("cover")
                if !u.isEmpty { nextCovers[r.s("tid")] = u }
            }
        }
        covers = nextCovers
        // 已读/收藏批量查（E9；跨页累积 union）
        if let marks = marks {
            let ids = merged.map { $0.s("tid") }.filter { !$0.isEmpty }
            if !ids.isEmpty {
                // R4 P6：标记查询 async（单条失败按未标记展示；badge 缺失不清空既有数据）
                let read = (try? await marks.historySet(ids)) ?? []
                let fav = (try? await marks.favSet(ids)) ?? []
                if rid == reqId {
                    readIds = readIds.union(read)
                    favIds = favIds.union(fav)
                }
            }
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

    /// goPage：anchors 清空 + maxOf(1,p) + reload(keepPage=true)（C9/E7：跳页走 OFFSET 不需要锚点）
    func goPage(_ p: Int) async {
        anchors.removeAll()
        page = max(1, p)
        await reload(keepPage: true)
    }

    // MARK: 筛选入口（C5：全部 page=1 重查，SWR 保留旧列表）

    /// setMain：级联清空 cat+type；page=1 + reload
    func setMain(_ v: String) async {
        main = v
        cat = ""
        type = ""
        page = 1
        await refetch()
    }

    /// setCat：级联清空 type；page=1 + reload
    func setCat(_ v: String) async {
        cat = v
        type = ""
        page = 1
        await refetch()
    }

    /// setType：page=1 + reload
    func setType(_ v: String) async {
        type = v
        page = 1
        await refetch()
    }

    /// clearFilters（R3 FilterSheet「重置」）：主版清空（级联清 cat+type）+ 关磁力开关 +
    /// 模糊/语义关闭，page=1 + reload
    func clearFilters() async {
        main = ""
        cat = ""
        type = ""
        if hasMagnet {
            hasMagnet = false
            store?.updateSettings { $0.shtHasMagnet = false }
        }
        fuzzy = false
        semantic = false
        anchors.removeAll()
        page = 1
        await refetch()
    }

    /// toggleMagnet：落盘 shtHasMagnet + page=1 + reload
    func toggleMagnet() async {
        hasMagnet.toggle()
        store?.updateSettings { $0.shtHasMagnet = self.hasMagnet }
        page = 1
        await refetch()
    }

    /// toggleFuzzy：与语义互斥（开启时 semantic=false）+ 清锚点 + reload（NA-06：切换后必须重查）
    func toggleFuzzy() async {
        fuzzy.toggle()
        if fuzzy { semantic = false }
        anchors.removeAll()
        page = 1
        await refetch()
    }

    /// toggleSemantic：与模糊互斥；未导入模型时不切换 —— Toast 逐字 + 跳设置（不静默降级）
    func toggleSemantic() async {
        if !semantic && !semanticInstalled() {
            onToast("未导入语义模型 — 请到 设置 → 语义搜索模型 导入")
            onOpenSettings()
            return
        }
        semantic.toggle()
        if semantic { fuzzy = false }
        anchors.removeAll()
        page = 1
        await refetch()
    }

    /// 排序（C3：发布日期→date / 最后更新→updated）；换排序清锚点
    func setSort(_ v: String) async {
        sort = v == "updated" ? "updated" : "date"
        anchors.removeAll()
        page = 1
        await refetch()
    }

    /// 每页（C5：20/40/60/80/100，写设置 shtPer）
    func setPer(_ v: Int) async {
        per = normalizePer(v, default: 20)
        store?.updateSettings { $0.shtPer = self.per }
        page = 1
        await refetch()
    }

    /// 仅改 state + 落盘，不重查（viewMode 全局设置与浏览页共用）
    func setViewMode(_ v: Int) {
        viewMode = v
        store?.updateSettings { $0.viewMode = v }
    }

    /// setter 先写 state 再 refetch，不从 prefs 回读（S11-P2 模式，避免异步落盘旧值）
    func refetch() async {
        await reload()
    }

    // MARK: 分类索引（C8：24h 缓存）

    /// 链路：非 force → get(24h) → stale → Q.shtCategories() + put；force 直接远程
    func loadCats(force: Bool) async {
        if !force, let hit = cache.get(Self.CAT_KEY, ttlMinutes: Self.CAT_TTL_MINUTES) {
            applyCats(hit)
            return
        }
        if !force, let stale = cache.stale(Self.CAT_KEY) {
            applyCats(stale)
            return
        }
        do {
            let d = try await source.shtCategories()
            cache.put(Self.CAT_KEY, d)
            applyCats(d)
        } catch {
            // 分类加载失败静默（不阻塞列表；C8）
        }
    }

    private func applyCats(_ d: [String: Any]) {
        mains = d["mains"] as? [Row] ?? []
        subs = d["subs"] as? [Row] ?? []
        types = d["types"] as? [Row] ?? []
        catTs = Self.numOf(d, "ts") ?? 0
    }

    // MARK: 导出（C4）

    /// exportLinks：Q.shtExport 流式回调 → cacheDir/share/jdlv_export_{ts}.txt
    /// （写前清空 share 目录只留最新一份，A-11）；n==0 删文件返回 nil。
    /// Toast（页面/VM 分工）：调用前页面先 Toast「导出中… (当前筛选范围)」；
    /// 成功本函数 Toast「✓ 已导出 ${n} 条链接」+ 返回文件（页面弹系统分享）；
    /// 0 条 Toast「导出失败或无数据」；异常 Toast「导出失败: ${msg 前 80 字}」（半角冒号）。
    func exportLinks() async -> ShtExportResult? {
        var rows: [Row] = []
        do {
            let q = queryState
            try await source.shtExport(
                main: main, cat: cat, type: type, q: q) { chunk in
                    rows.append(contentsOf: chunk)
                }
        } catch {
            let name = String(describing: Swift.type(of: error))
            let msg = (error as? CustomStringConvertible)?.description ?? ""
            let shown = msg.isEmpty ? name : String(msg.prefix(80))
            onToast("导出失败: \(shown)")   // 半角冒号
            return nil
        }
        if rows.isEmpty {
            onToast("导出失败或无数据")
            return nil
        }
        // 写前清空 share 目录历史（只留最新一份，A-11）
        let dir = exportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let olds = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in olds where f.lastPathComponent.hasPrefix("jdlv_export_") {
                try? FileManager.default.removeItem(at: f)
            }
        }
        let text = ShtExportComposer.assemble(rows, main: main, cat: cat, type: type, q: queryState)
        let file = dir.appendingPathComponent("jdlv_export_\(nowMs()).txt")
        do {
            try text.data(using: .utf8)?.write(to: file)
        } catch {
            onToast("导出失败: \(String(describing: Swift.type(of: error)))")
            return nil
        }
        let n = rows.count
        onToast("✓ 已导出 \(n) 条链接")
        return ShtExportResult(url: file, count: n)
    }

    // MARK: 刷新结果通道（仅手动下拉路径写入；页面消费后 consume 清位）

    let refreshChannel = RefreshResultChannel()
}

// MARK: - demo 数据源（仅 DEBUG；同一 ShtDataSource 协议注入 DemoStore，页面层零改动切换）

#if DEBUG
/// demo 列响应与生产 Q.shtBrowse 键一致：items/total(-1)/covers/page/approx/derived。
/// covers 恒空 map → VM 走行内 cover/cover_url 兜底（P3.8 路径在 demo 闭环）。
struct DemoShtDataSource: ShtDataSource {
    func shtBrowse(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool,
        page: Int, per: Int, anchor: (String, String)?, mode: String, sort: String,
        cand: Int, threshold: Float
    ) async throws -> [String: Any] {
        // 语义模式：demo 无模型 → 与生产 Q 同文案明确业务态（禁静默降级）
        if mode == "semantic" {
            throw SemanticUnavailableError(
                "语义模型未导入或加载失败 — 请到 设置 → 语义搜索模型 导入")
        }
        var rows = DemoStore.shared.shtList(
            main: main, cat: cat, type: type, q: q, page: page, per: per)
        if hasMagnet { rows = rows.filter { $0.i("magnet_count") > 0 } }
        if sort == "updated" {
            rows.sort { ($0.s("last_checked"), $0.s("tid")) > ($1.s("last_checked"), $1.s("tid")) }
        }
        return [
            "total": Int64(-1), "items": rows, "page": page,
            "covers": [String: String](), "approx": true, "derived": "",
        ]
    }

    func shtBrowseCount(
        main: String, cat: String, type: String, q: String, hasMagnet: Bool, sort: String
    ) async -> Int64 {
        -1   // demo 计数未知（「已加载 N 条」口径）
    }

    /// demo 分类聚合：全量 threads（96 条 < 200）按 mains/subs/types 派生（对齐 Q.shtCategories 键）
    func shtCategories() async throws -> [String: Any] {
        let rows = DemoStore.shared.shtList(main: "", cat: "", type: "", q: "", page: 1, per: 200)
        var mainC: [String: Int64] = [:]
        var subC: [String: (main: String, c: Int64)] = [:]
        var typeC: [String: (sub: String, c: Int64)] = [:]
        for r in rows {
            let board = r.s("board")
            if !board.isEmpty { mainC[board, default: 0] += 1 }
            let bn = r.s("board_name")
            if !bn.isEmpty {
                var e = subC[bn] ?? (board, 0)
                e.c += 1
                subC[bn] = e
            }
            let t = r.s("type")
            if !t.isEmpty {
                var e = typeC[t] ?? (bn, 0)
                e.c += 1
                typeC[t] = e
            }
        }
        let mains = mainC.sorted { $0.value > $1.value }
            .map { Row(["name": .string($0.key), "c": .int($0.value)]) }
        let subs = subC.sorted { $0.value.c > $1.value.c }
            .map { Row(["main": .string($0.value.main), "name": .string($0.key), "c": .int($0.value.c)]) }
        let types = typeC.sorted { $0.value.c > $1.value.c }
            .map { Row(["sub": .string($0.value.sub), "name": .string($0.key), "c": .int($0.value.c)]) }
        return [
            "categories": [Row](), "mains": mains, "subs": subs, "types": types,
            "total": Int64(rows.count), "approx": true,
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
        ]
    }

    /// demo 导出：post_date DESC 流式分批（一批交齐，≤800 帖）；每帖按 magnet_count
    /// 合成磁力行（hash = demo{tid}{i}），与 Q.shtExport 行键 tid/title/date/kind/link/size 一致。
    func shtExport(
        main: String, cat: String, type: String, q: String,
        onRows: ([Row]) async -> Void
    ) async throws {
        var rows = DemoStore.shared.shtList(main: main, cat: cat, type: type, q: q, page: 1, per: 200)
        rows.sort { $0.s("post_date") > $1.s("post_date") }
        rows = Array(rows.prefix(800))
        var out: [Row] = []
        for t in rows {
            let n = min(Int(t.i("magnet_count")), 2)
            for i in 0..<n {
                out.append(Row([
                    "tid": .string(t.s("tid")), "title": .string(t.s("title")),
                    "date": .string(t.s("post_date")), "kind": .string("磁力"),
                    "link": .string("magnet:?xt=urn:btih:demo\(t.s("tid"))\(i)"),
                    "size": .string("734"),
                ]))
            }
        }
        await onRows(out)
    }

    /// demo 帖子详情：threads 行 + 合成 magnets/images/blocks（键与 Q.shtThread 输出一致）
    func shtThread(tid: String) async throws -> [String: Any]? {
        guard let t = DemoStore.shared.shtThread(tid: tid) else { return nil }
        var d: [String: Any] = [:]
        for k in t.keys { d[k] = QDemoRow.anyOf(t, k) }
        let isImage = t.s("cat_name") == "自拍图片区"
        let isLit = t.s("cat_name") == "小说文学区"
        // magnets：magnet_count>0 合成（空 link 拼 magnet:?xt=urn:btih:<hash>，对齐 Q）
        var mags: [[String: Any]] = []
        let mc = min(Int(t.i("magnet_count")), 2)
        for i in 0..<mc {
            let hash = "demo\(tid)\(i)"
            mags.append([
                "hash": hash, "name": "演示磁力 \(i + 1)", "size": "734",
                "first_seen": t.s("post_date"), "link": "magnet:?xt=urn:btih:\(hash)",
            ])
        }
        d["magnets"] = mags
        d["ed2k"] = [[String: Any]]()
        d["videos"] = [String]()
        // images：图片贴给 cover_url；文字贴给一张示意图
        let cover = t.s("cover_url")
        d["images"] = cover.isEmpty ? (isImage ? ["https://demo.jdlv.local/thread/\(tid)a.jpg"] : [])
                                    : [cover]
        // blocks：文学区合成正文块（ReaderBody 全参数在 demo 可视）
        if isLit {
            var blocks: [[String: Any]] = []
            for i in 1...6 {
                blocks.append([
                    "t": "演示帖子正文第 \(i) 段。这段文字用于在演示模式下验证阅读器的字号、行距、段距与首行缩进效果。",
                    "sz": 0,
                ])
            }
            blocks.append(["t": "加粗强调段（b=1）。", "b": "1", "sz": 0])
            d["blocks"] = blocks
        }
        d["words"] = t.map["words"] ?? .int(0)
        return d
    }
}

/// Row → Any（ShtVM 文件内自足，不复用 Q 内部 jrow）
enum QDemoRow {
    static func anyOf(_ r: Row, _ k: String) -> Any {
        guard let v = r.map[k] else { return NSNull() }
        switch v {
        case .null: return NSNull()
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(let d): return d
        case .bool(let b): return b
        }
    }
}
#endif
