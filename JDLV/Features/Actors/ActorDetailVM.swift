import Foundation
import JDLVCore

//
//  ActorDetailVM.swift —— 女优详情页 VM（09 B 节 ActorDetailScreen/ActorDetailVm 移植）。
//
//  状态：loading/error/actor:Row?/items/total/page(per=24)/sort/asc/tagId/tags(聚合)/
//  tagsLoading/tagsHasMore/fav。
//
//  契约（B 节逐条）：
//  - 每页 per = 24；Q.actor 的 total 是真值（COUNT 与 items 同口径，S15-07）。
//  - **merged_into 四处处理**：① 列表过滤（Q.actors SQL 内 WHERE，本 VM 无感）；
//    ② 详情解析 mainId = merged_into.ifEmpty { aid }（影片 count/items 按主号查）；
//    ③ 标签聚合 Q.actorTags/actorTagCount 同样先解析；④ 离线回退（S16-14）主号缺行退回
//    合并号行本身 —— 前三处在 Q 层/数据源内完成，VM 侧提供 mainIdOf 纯函数供
//    demo 数据源与测试复用（④ 留 P13 注释）。
//  - 标签聚合分页（B6）：TAG_LIMIT = 60；loadTags(offset, append) → actorTags(aid, offset, 60)；
//    append 按 tag id 去重合并；tagsHasMore = 本次返回条数 >= 60；loadMoreTags offset = 已显示条数；
//    失败 → 空列表 → UI 隐藏「标签」入口，不阻塞影片列表。
//  - 分页（B7）：hasMore = total <= 0 || items.count < total（total 异常为 0 也能继续加载）；
//    追加按 id 去重；触底 loadNext + ListNavTools 跳页 dvm.load(page)。
//  - 在飞请求保护（B9/S11-P6）：loadPage 发起前捕获 sort/asc/tagId 快照 + rid 竞态守卫。
//  - 收藏：favToggle("actor", aid, name) → Toast 已收藏/已取消收藏；
//    加载成功后 historyMark("actor", aid, name) 写历史；fav 初值 favIs("actor", aid)。
//  - demo 模式（仅 DEBUG）：DemoActorDetailDataSource 组装 DemoStore（聚合出演影片后本地
//    排序/标签过滤/分页；标签聚合由出演影片 tags CSV 聚合，c DESC + tag_id ASC 与
//    ActorTagSql.REMOTE_TAG_ORDER 口径一致）。
//

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol ActorDetailDataSource {
    /// 对齐 Q.actor：返回 actor/total/items/page（键名与 Android 逐字一致）；nil = 未找到该女优
    func actor(
        aid: String, page: Int, per: Int, sort: String, asc: Bool, tagId: String
    ) async throws -> [String: Any]?
    /// 标签聚合（Q.actorTags：失败 → 空列表，UI 隐藏标签入口）
    func actorTags(aid: String, offset: Int, limit: Int) async -> [Row]
}

/// 生产数据源（merged_into 解析/离线回落/探活全在 Q.actor/actorTags 内）
struct QActorDetailDataSource: ActorDetailDataSource {
    func actor(
        aid: String, page: Int, per: Int, sort: String, asc: Bool, tagId: String
    ) async throws -> [String: Any]? {
        try await Q.actor(
            aid: aid, page: page, per: per, sort: sort, asc: asc, tagId: tagId)
    }

    func actorTags(aid: String, offset: Int, limit: Int) async -> [Row] {
        await Q.actorTags(aid: aid, offset: offset, limit: limit)
    }
}

#if DEBUG

/// demo 数据源：同一协议组装 DemoStore（出演影片聚合 → 本地排序/标签过滤/分页；
/// 标签聚合由出演影片 tags CSV 聚合）。
struct DemoActorDetailDataSource: ActorDetailDataSource {
    func actor(
        aid: String, page: Int, per: Int, sort: String, asc: Bool, tagId: String
    ) async throws -> [String: Any]? {
        guard let a = DemoStore.shared.actor(aid: aid) else { return nil }
        // merged_into 解析（demo 无该列 → 原样；逻辑与生产 Q.actor.mainId 同口径）
        let mainId = ActorDetailVM.mainIdOf(aid: aid, row: a)
        // 聚合出演影片（demo actorMovies 每页 24，翻页拉全量后本地处理）
        var all: [Row] = []
        var p = 1
        while all.count < 2000 {
            let rows = DemoStore.shared.actorMovies(aid: mainId, page: p)
            if rows.isEmpty { break }
            all.append(contentsOf: rows)
            if rows.count < 24 { break }
            p += 1
        }
        if !tagId.isEmpty {
            all = all.filter { row in
                row.s("tags").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .contains(tagId)
            }
        }
        // 排序（Q.orderOf 口径：release_date/score 次级键 id；id 排序单列即稳定序）
        all.sort { lhs, rhs in
            let cmp: Bool
            switch sort {
            case "id":
                cmp = lhs.i("id") < rhs.i("id")
            case "score":
                if lhs.d("score") != rhs.d("score") {
                    cmp = lhs.d("score") < rhs.d("score")
                } else {
                    cmp = lhs.i("id") < rhs.i("id")
                }
            default:
                if lhs.s("release_date") != rhs.s("release_date") {
                    cmp = lhs.s("release_date") < rhs.s("release_date")
                } else {
                    cmp = lhs.i("id") < rhs.i("id")
                }
            }
            return asc ? cmp : !cmp
        }
        let start = (max(1, page) - 1) * per
        let items = Array(all.dropFirst(start).prefix(per))
        return [
            "actor": ActorDetailVM.rowOf(a),
            "total": Int64(all.count),
            "items": items,
            "page": page,
        ]
    }

    func actorTags(aid: String, offset: Int, limit: Int) async -> [Row] {
        guard let a = DemoStore.shared.actor(aid: aid) else { return [] }
        let mainId = ActorDetailVM.mainIdOf(aid: aid, row: a)
        // 聚合出演影片 tags CSV → 计数（c DESC + tag_id ASC，与 REMOTE_TAG_ORDER 一致）
        var count: [String: Int64] = [:]
        var p = 1
        while p <= 100 {
            let rows = DemoStore.shared.actorMovies(aid: mainId, page: p)
            if rows.isEmpty { break }
            for r in rows {
                for t in r.s("tags").split(separator: ",")
                    .map({ $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty {
                    count[t, default: 0] += 1
                }
            }
            if rows.count < 24 { break }
            p += 1
        }
        let rows = count
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { Row(["id": .string($0.key), "name": .string($0.key), "c": .int($0.value)]) }
        return Array(rows.dropFirst(offset).prefix(limit))
    }
}

#endif

// MARK: - 逐字文案（09 B 节）

enum ActorDetailCopy {

    static let navTitleFallback = "女优详情"
    static let favAccessibility = "收藏"
    static let backAccessibility = "返回"
    /// 接口返回空（actor == null）
    static let emptyNotFound = "未找到该女优"
    /// 出演影片空态
    static let emptyMovies = "该女优暂无影片数据"

    // InfoRow 7 标签（"$k: $v"，v 为空整行不显示）
    static let infoAlias = "别名"       // other_name
    static let infoVideos = "影片数"    // st.total（>0 才显示）
    static let infoBirthday = "生日"    // birthday
    static let infoHeight = "身高"      // height
    static let infoPopularity = "人气"  // popularity（>0 才显示）
    static let infoAvgScore = "均分"    // "%.2f" avg_score_all（>0 才显示）
    static let infoTwitter = "推特"     // twitter

    /// 出演影片区块标题（Bold 14）
    static func moviesTitle(_ total: Int64) -> String {
        "出演影片 (共 \(total) 部)"
    }

    // 排序 × 方向（B5 逐字）
    static let sortLabel = "排序"
    static let ascLabel = "顺序"
    static let sortOptions: [(label: String, value: String)] = [
        ("发布日期", "release_date"), ("收录顺序", "id"), ("评分", "score"),
    ]
    static let ascOptions: [(label: String, value: String)] = [
        ("倒序", "desc"), ("正序", "asc"),
    ]
    /// sort=="id" 时提示（tertiary，B5 逐字）
    static let idSortNote = "库内无更新时间列，已按收录顺序排序"

    // 标签筛选面板（B5）
    static let tagsEntry = "标签"
    static let tagsPanelTitle = "按标签筛选 (该女优影片聚合)"
    static let tagsAll = "全部"
    static let tagsLoadingMore = "加载中…"
    /// 全角括号
    static func tagsLoadMore(_ shown: Int) -> String {
        "加载更多标签（已显示 \(shown)）"
    }
    static let done = "完成"

    // 收藏 Toast（B7）
    static let toastFavOn = "已收藏"
    static let toastFavOff = "已取消收藏"
}

// MARK: - ActorDetailVM

@MainActor
final class ActorDetailVM: ObservableObject {

    /// 每页条数（B2 per = 24）
    static let per = 24
    /// 标签聚合页大小（B6：与远程聚合 LIMIT 一致）
    static let TAG_LIMIT = 60

    // MARK: 依赖（可注入）

    let source: ActorDetailDataSource
    let favStore: FavStoreProtocol
    var onToast: (String) -> Void

    init(
        source: ActorDetailDataSource? = nil,
        favStore: FavStoreProtocol? = nil,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoActorDetailDataSource() : QActorDetailDataSource())
        #else
        self.source = source ?? QActorDetailDataSource()
        #endif
        #if DEBUG
        self.favStore = favStore
            ?? (DemoDataSource.enabled() ? MemoryFavStore.shared : LocalFavStore())
        #else
        self.favStore = favStore ?? LocalFavStore()
        #endif
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    /// 页面默认构造
    static func makeDefault() -> ActorDetailVM { ActorDetailVM() }

    // MARK: 状态

    /// 当前女优 id
    private(set) var id = ""
    @Published var loading = false
    @Published var error: String? = nil
    /// 头部女优行（merged_into 别名号时显示别名行本身，影片挂主号下）
    @Published var actor: Row? = nil
    @Published var items: [Row] = []
    /// Q.actor 真值（COUNT 与 items 同口径）；离线兜底 0 时 hasMore 仍成立
    @Published var total: Int64 = 0
    @Published var page = 1
    @Published var sort = "release_date"
    /// false=倒序（默认）
    @Published var asc = false
    /// 单选标签（空 = 「全部」；再点同一标签取消）
    @Published var tagId = ""
    /// 标签聚合（id/name/c）
    @Published var tags: [Row] = []
    @Published var tagsLoading = false
    @Published var tagsHasMore = false
    @Published var fav = false

    private var reqId = 0
    /// 标签聚合已拉取标记（B6：独立拉取一次；失败 → 空列表 → UI 隐藏入口，不随翻页重拉）
    private var tagsLoaded = false

    /// 本地索引兜底 derived 标注（actor 行带 derived 时原样显示，B4）
    var derived: String { actor?.s("derived") ?? "" }

    // MARK: merged_into 解析（B8：详情解析/标签聚合入口；测试共用纯函数）

    /// mainId = merged_into.ifEmpty { aid }（影片 count/items/tags 均按主号查）
    nonisolated static func mainIdOf(aid: String, row: Row?) -> String {
        let merged = row?.s("merged_into") ?? ""
        return merged.isEmpty ? aid : merged
    }

    // MARK: [String: Any] ↔ Row / SQLValue（MovieDetailVM 转换复用）

    nonisolated static func rowOf(_ r: Row) -> [String: Any] { MovieDetailVM.rowOf(r) }
    nonisolated static func rowOf(_ d: [String: Any]) -> Row { MovieDetailVM.rowOf(d) }

    // MARK: 加载（B7/B9）

    /// bind：同 mid 且已有数据（或已报错/在载）→ 幂等；否则记录并 load(1)
    func bind(aid: String) async {
        if id == aid && (actor != nil || error != nil || loading) { return }
        id = aid
        await load(1)
    }

    /// load(page)：首查与跳页/筛选共用；append = page > 1
    func load(_ p: Int) async {
        let aid = id
        reqId += 1
        let rid = reqId
        // S11-P6 在飞请求保护：发起前捕获查询参数快照
        let sSort = sort
        let sAsc = asc
        let sTag = tagId
        loading = true
        error = nil
        do {
            let d = try await source.actor(
                aid: aid, page: p, per: Self.per, sort: sSort, asc: sAsc, tagId: sTag)
            guard rid == reqId else { return }
            apply(d, aid: aid, page: p, rid: rid, append: p > 1)
            // 收藏初值 + 加载成功后写历史（B7；与加载同序保证测试确定性）
            if actor != nil {
                let f = await favStore.favIs(kind: "actor", itemId: aid)
                guard rid == reqId else { return }
                fav = f
                await favStore.historyMark(
                    kind: "actor", itemId: aid, title: actor?.s("name") ?? "")
            }
            loading = false
            // 标签聚合独立拉取（首次；失败 → 空列表 → UI 隐藏标签入口）
            if !tagsLoaded {
                await loadTags()
            }
        } catch {
            guard rid == reqId else { return }
            loading = false
            self.error = ErrText.of(error)
        }
    }

    /// apply：append 按 id 去重；total 真值；加载成功后 historyMark + fav 初值
    private func apply(_ d: [String: Any]?, aid: String, page p: Int, rid: Int, append: Bool) {
        guard rid == reqId else { return }
        guard let d, let aMap = d["actor"] as? [String: Any] else {
            // nil = 未找到该女优（actor 保持 nil → 空态「未找到该女优」）
            return
        }
        actor = Self.rowOf(aMap)
        let fresh = d["items"] as? [Row] ?? []
        if append {
            var seen = Set(items.map { $0.s("id") })
            items += fresh.filter { seen.insert($0.s("id")).inserted }
        } else {
            items = fresh
        }
        if let t = BrowseVM.numOf(d, "total") { total = t }
        page = p
        loading = false
    }

    /// onDispose 重置（B2：离开页面 release 清空整行数据）
    func release() {
        id = ""
        loading = false
        error = nil
        actor = nil
        items = []
        total = 0
        page = 1
        sort = "release_date"
        asc = false
        tagId = ""
        tags = []
        tagsLoading = false
        tagsLoaded = false
        tagsHasMore = false
        fav = false
    }

    // MARK: 翻页（B7）

    /// hasMore = total <= 0 || items.count < total（total 异常为 0 时也要能继续加载）
    var hasMore: Bool {
        total <= 0 || items.count < Int(total)
    }

    /// 触底追加（追加、按 id 去重、保留进度）
    func loadNext() async {
        if loading { return }
        guard !items.isEmpty else { return }
        guard hasMore else { return }
        await load(page + 1)
    }

    /// 跳页（ListNavTools → dvm.load(page)）
    func goPage(_ p: Int) async {
        await load(max(1, p))
    }

    // MARK: 排序 × 方向 × 标签（B5：全部回第 1 页重新查询）

    func setSort(_ v: String) async {
        guard v != sort else { return }
        sort = v
        await load(1)
    }

    func setAsc(_ v: Bool) async {
        guard v != asc else { return }
        asc = v
        await load(1)
    }

    /// 标签点选：点选即查询，再点同一标签取消（回「全部」）
    func setTag(_ v: String) async {
        let next = (v == tagId) ? "" : v
        tagId = next
        await load(1)
    }

    // MARK: 标签聚合分页（B6）

    /// loadTags(offset=0)：TAG_LIMIT = 60；tagsHasMore = 本次返回条数 >= 60
    func loadTags() async {
        guard !tagsLoading else { return }
        tagsLoading = true
        tagsLoaded = true
        let rows = await source.actorTags(aid: id, offset: 0, limit: Self.TAG_LIMIT)
        tags = rows
        tagsHasMore = rows.count >= Self.TAG_LIMIT
        tagsLoading = false
    }

    /// loadMoreTags：offset = 已显示条数；append 按 tag id 去重合并
    func loadMoreTags() async {
        guard tagsHasMore, !tagsLoading else { return }
        tagsLoading = true
        let rows = await source.actorTags(aid: id, offset: tags.count, limit: Self.TAG_LIMIT)
        var seen = Set(tags.map { $0.s("id") })
        tags += rows.filter { seen.insert($0.s("id")).inserted }
        tagsHasMore = rows.count >= Self.TAG_LIMIT
        tagsLoading = false
    }

    // MARK: 收藏（B7）

    /// favToggle("actor", aid, name) → Toast 已收藏/已取消收藏
    func toggleFav() async {
        let now = await favStore.favToggle(
            kind: "actor", itemId: id, title: actor?.s("name") ?? "")
        fav = now
        onToast(now ? ActorDetailCopy.toastFavOn : ActorDetailCopy.toastFavOff)
    }
}
