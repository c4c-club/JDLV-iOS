import Foundation
import JDLVCore

//
//  MovieDetailVM.swift —— 影片详情页 VM（08 B 节 MovieDetailScreen + B.10 MovieDetailVm 移植）。
//
//  状态（B.10 / 任务 A 逐项）：loading/error/movie:Row?/tags/actors(♀ 分区在上)/
//  magnets/previews/relatedArticles/covBackfilled/fav/read/id。
//
//  契约：
//  - bind(mid)：同一 mid 且已有数据（或已报错/在载）→ 幂等返回；否则记录并 load()。
//  - load()：loading=true → 数据源取详情 → 写 movie/tags/actors/magnets/previews →
//    fav/history 初值 → **进入详情即记已读**（historyMark，B.10）→ 相关资讯（失败静默）→
//    影子兜底在线回填封面（covBackfilled）。
//  - 竞态 rid：reqId 自增；apply/catch 先校验 rid != reqId → 整体丢弃（旧响应一律不写状态）。
//  - 离线最小详情三级（B.9）：Q.movie 内部已实现（远程 → movieLocal 影子/索引 → 探活回落 →
//    抛错）；VM 侧只消费 nil（空态「远程库未收录该影片」）与异常（ErrText）。
//    TODO(P13)：ShadowDb.movieById 打开过的全字段详情回落当前在 Q.movieLocal 内恒 nil，
//    接线后无需改本 VM（三级回落语义在 Q 层）。
//  - 收藏/已读走 FavStoreProtocol 注入：生产 LocalStore（BrowseMarks 单例宿主）、
//    demo 模式写内存（MemoryFavStore）、测试注入假件。
//  - 灯箱 gallery = [封面] + 剧照（过滤空 URL，同组连续翻页）；封面 → index 0；
//    剧照第 i 张 → cover 非空 ? 1 + i : i（B.3 galleryIndexOfPreview）。
//  - 反查行（B.4 JumpLines）：片商/系列/导演/发行商/年份 5 行 + 标签行；缺值「—」不可点；
//    payload = LookupCodec.encode(LookupSpec(filters, label))，label = 「{标签}：{值}」全角冒号。
//  - demo 模式（仅 DEBUG）：DemoMovieDetailDataSource 组装 DemoStore（tags CSV /
//    确定性合成 actors/magnets/previews；列名与真实库一致）。
//

// MARK: - 收藏/已读存储协议（Core LocalStore 注入；demo 写内存）

protocol FavStoreProtocol {
    func favIs(kind: String, itemId: String) async -> Bool
    func favToggle(kind: String, itemId: String, title: String) async -> Bool
    func historyIs(kind: String, itemId: String) async -> Bool
    func historyMark(kind: String, itemId: String, title: String) async
}

/// 生产：Core LocalStore（jdlv_local.db；A-1 同口径）
/// R4 P6：不再持 LocalStore / 不在 init 打开 SQLite —— 每次操作经 BrowseMarks.open()
/// 后台打开（once Task 复用），SQL 全部走 LocalStoreActor 串行后台，绝不 MainActor。
struct LocalFavStore: FavStoreProtocol {

    func favIs(kind: String, itemId: String) async -> Bool {
        guard let a = await BrowseMarks.open() else { return false }
        return (try? await a.favIs(kind: kind, id: itemId)) ?? false
    }

    func favToggle(kind: String, itemId: String, title: String) async -> Bool {
        guard let a = await BrowseMarks.open() else { return false }
        return (try? await a.favToggle(kind: kind, id: itemId, title: title)) ?? false
    }

    func historyIs(kind: String, itemId: String) async -> Bool {
        guard let a = await BrowseMarks.open() else { return false }
        return (try? await a.historyIs(kind: kind, id: itemId)) ?? false
    }

    func historyMark(kind: String, itemId: String, title: String) async {
        guard let a = await BrowseMarks.open() else { return }
        _ = try? await a.historyMark(kind: kind, id: itemId, title: title)
    }
}

/// demo / 测试：进程内存态（demo 模式全链路会话内持久；测试各建实例）
final class MemoryFavStore: FavStoreProtocol {
    static let shared = MemoryFavStore()

    private(set) var favs = Set<String>()
    private(set) var reads = Set<String>()

    func favIs(kind: String, itemId: String) async -> Bool {
        favs.contains("\(kind)|\(itemId)")
    }

    func favToggle(kind: String, itemId: String, title: String) async -> Bool {
        let k = "\(kind)|\(itemId)"
        if favs.contains(k) {
            favs.remove(k)
            return false
        }
        favs.insert(k)
        return true
    }

    func historyIs(kind: String, itemId: String) async -> Bool {
        reads.contains("\(kind)|\(itemId)")
    }

    func historyMark(kind: String, itemId: String, title: String) async {
        reads.insert("\(kind)|\(itemId)")
    }
}

// MARK: - 数据源协议（生产 Q / demo DemoStore 同一协议注入）

protocol MovieDetailDataSource {
    /// 对齐 Q.movie：基础行标量键 + tags([Row])/actors([[String: Any]])/magnets([Row])/
    /// previews([String]) 嵌套键（键名与 Android 逐字一致）；nil = 远程库未收录
    func movie(mid: String) async throws -> [String: Any]?
    /// 相关资讯（Q.movieArticles：失败静默空列表 → 整块隐藏）
    func movieArticles(mid: String) async -> [Row]
    /// 影子兜底在线回填封面（id → cover_url；仅 cover_url 非空回传）
    func movieCovers(ids: [String]) async -> [String: String]
}

/// 生产数据源（离线三级回落/探活/markOffline 全在 Q.movie 内）
struct QMovieDetailDataSource: MovieDetailDataSource {
    func movie(mid: String) async throws -> [String: Any]? {
        try await Q.movie(mid: mid)
    }

    func movieArticles(mid: String) async -> [Row] {
        await Q.movieArticles(mid: mid)
    }

    func movieCovers(ids: [String]) async -> [String: String] {
        await Q.movieCovers(ids: ids)
    }
}

#if DEBUG

/// demo 数据源：同一协议组装 DemoStore（movies.tags CSV → tags；actors/magnets/previews
/// 按 id 确定性合成 —— demo 库无 movie_actors 之外的明细查询 API，合成规则与
/// DemoStore.insertActors 的 id/name/gender 口径一致，点演员卡可跳女优详情）。
struct DemoMovieDetailDataSource: MovieDetailDataSource {
    func movie(mid: String) async throws -> [String: Any]? {
        guard let m = DemoStore.shared.movie(mid: mid) else { return nil }
        var base: [String: Any] = m.map.reduce(into: [:]) {
            $0[$1.key] = MovieDetailVM.anyOf($1.value)
        }
        // tags：movies.tags CSV（tag_id = tag_name，与 demo taxonomy 口径闭环）
        let tagRows: [Row] = m.s("tags").split(separator: ",")
            .map { Row(["tag_id": .string(String($0)), "tag_name": .string(String($0))]) }
        // actors：确定性合成 1~3 人（FNV-1a(mid) 定位，女前男后由 VM.sortActors 统一处理）
        var actorRows: [Row] = []
        var seenActors = Set<String>()
        for k in 0..<3 {
            let j = Self.actorIndexOf(movieId: mid, k: k)
            let actorId = String(200_000 + j)
            guard seenActors.insert(actorId).inserted else { continue }
            let gender: Int64 = (j % 9 == 8) ? 1 : 0
            let name = (gender == 1 ? "演示男优 " : "演示女优 ")
                + String(format: "%03d", j + 1)
            actorRows.append(Row([
                "actor_id": .string(actorId), "actor_name": .string(name), "gender": .int(gender),
            ]))
        }
        // magnets：magnets_count>0 → 确定性合成 ≤3 条（hash/name/size/cnsub/hd/files_count）
        var mags: [Row] = []
        if m.i("magnets_count") > 0 {
            let n = min(3, max(1, Int(m.i("magnets_count"))))
            for k in 0..<n {
                let h = Self.fnv1a("\(mid)#m\(k)")
                mags.append(Row([
                    "hash": .string(String(format: "%016llx%08x", h, UInt32(truncatingIfNeeded: h >> 24))),
                    "name": .string("\(m.s("number"))-\(k + 1).mp4"),
                    "size": .string(String(700 + Int(h % 3000))),
                    "cnsub": .bool(k == 0),
                    "hd": .bool(k == 1),
                    "files_count": .int(Int64(1 + k * 4)),
                    "created_at": .string(""),
                ]))
            }
        }
        // previews：确定性 4 张（PosterImage demo 模式渲染 TestImages 色块，不发网络请求）
        let previews = (0..<4).map { "https://demo.jdlv.local/preview/\(mid)-\($0).jpg" }
        base["tags"] = tagRows
        base["actors"] = actorRows.map { MovieDetailVM.rowOf($0) }
        base["magnets"] = mags
        base["previews"] = previews
        return base
    }

    func movieArticles(mid: String) async -> [Row] {
        // 演示：取前 2 条资讯作为相关资讯（id/title/category_name/released_at 列齐备）
        Array(DemoStore.shared.articles(page: 1, categoryId: "", q: "").prefix(2))
    }

    func movieCovers(ids: [String]) async -> [String: String] { [:] }

    /// 与 DemoStore.insertActors 的确定性 actors 表对位（id=200000+j，j∈[0, 72)）
    static func actorIndexOf(movieId: String, k: Int) -> Int {
        let h = fnv1a(movieId)
        return Int((h &+ UInt64(k) &* 0x9E37_79B9_7F4A_7C15) % UInt64(DemoStore.actorCount))
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3
        }
        return h
    }
}

#endif

// MARK: - 图片 URL 归一（09 E10 Img 对位；重写/冷却在 PosterImage 内完成）

enum MovieImg {
    /// Img.movieCover(coverUrl, id)：cover 非空 → url(raw)；空 → /covers/{id 前 2 位小写}/{id}.jpg
    /// （id trim 后 length < 3 → ""，S10 取证口径）
    static func movieCover(_ coverUrl: String, _ id: String) -> String {
        if !coverUrl.isEmpty { return CdnRewrite.jdbImgUrl(coverUrl) }
        let t = id.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return "" }
        return CdnRewrite.jdbImgUrl("/covers/\(String(t.prefix(2)).lowercased())/\(t).jpg")
    }

    /// Img.preview(u)：TestImages 优先（PosterImage 内），否则 url() 重建图床
    static func preview(_ u: String) -> String {
        u.isEmpty ? "" : CdnRewrite.jdbImgUrl(u)
    }

    /// Img.actorAvatar(url)：库内 /avatars/ 形态直出；无 → 空串 → 静态占位
    static func actorAvatar(_ u: String) -> String {
        u.isEmpty ? "" : CdnRewrite.jdbImgUrl(u)
    }
}

// MARK: - 逐字文案（08 B 节；含全/半角标点差异，勿规范化）

enum MovieDetailCopy {

    static let navTitleFallback = "影片详情"
    /// B.0 右侧收藏按钮（FavButton accessibilityLabel）
    static let favAccessibility = "收藏"
    static let backAccessibility = "返回"
    /// B.1 分支 3：加载成功但无此片
    static let emptyNotCollected = "远程库未收录该影片"

    // InfoRow（"{k}: {v}" 半角冒号+空格；值为空整行不渲染）
    static let infoScore = "评分"
    static let infoRelease = "发行"
    static let infoDuration = "时长"
    static let infoWant = "想看"
    static let infoWatched = "看过"
    /// 评分值："{score} ({reviews_count}人)" 半角括号
    static func scoreValue(score: String, reviews: Int64) -> String {
        "\(score) (\(reviews)人)"
    }
    /// has_cnsub → 单独一行 Meta「✓ 中文字幕」（tertiary 色）
    static let cnsubLine = "✓ 中文字幕"

    // 反查行 JumpLines（标签全角冒号拼在值前；缺值「—」不可点）
    static let jumpMaker = "片商："
    static let jumpSeries = "系列："
    static let jumpDirector = "导演："
    static let jumpPublisher = "发行商："
    static let jumpYear = "年份："
    static let jumpTagPrefix = "标签："
    static let missingValue = "—"

    // 已读按钮（⚠ 半角括号+空格）
    static let readButtonRead = "✓ 已读 (点击复制番号)"
    static let readButtonUnread = "标记已读"
    static let toastCopied = "已复制"
    static let toastMarkedRead = "已标记已读"

    // 演员（B.5：♀粉 ♂蓝，符号后一个空格；gender==1 男 ♂）
    static let actorsTitle = "演员"
    static let femaleSign = "♀ "
    static let maleSign = "♂ "

    // 剧照（⚠ 全角逗号在"张"后、半角逗号在"滑动"后）
    static func previewsTitle(_ n: Int) -> String {
        "剧照 (\(n) 张, 左右滑动, 点击放大)"
    }

    // 磁力卡（B.7）
    static func magnetsTitle(_ n: Int) -> String {
        "磁力 (共 \(n) 条, 单击复制)"
    }
    static let magnetsEmptyRemote = "远程库暂无该影片的磁力数据"
    /// derived 含「离线」时空态文案
    static let magnetsEmptyOffline = "离线暂无磁力，联网后自动补全"
    /// 角标后缀：{fmtSize}{ · 中字 若 cnsub}
    static let magnetCnsubSuffix = " · 中字"
    /// 次行 files_count>0 时追加（take(46) 后直接 join，中间无空格）
    static func magnetFilesSuffix(_ n: Int64) -> String {
        "· \(n) 个文件"
    }
    static let toastMagnetCopied = "已复制磁力链接"

    // 相关资讯（B.8）
    static let articlesTitle = "相关资讯"

    // 收藏 Toast（B.0）
    static let toastFavOn = "已收藏"
    static let toastFavOff = "已取消收藏"
}

// MARK: - 反查行链接模型（label/value/payload；payload nil = 缺值不可点）

struct MovieJumpLink: Equatable {
    /// 「片商：」等（全角冒号结尾）
    let label: String
    /// 展示值（name 优先，缺省 id；年份 = release_date 前 4 位）
    let value: String
    /// LookupCodec.encode(LookupSpec) 结果；nil = 不可点
    let payload: String?

    /// 反查顶栏 label：「{标签}：{值}」
    var lookupLabel: String { label + value }
}

// MARK: - MovieDetailVM（B.10）

@MainActor
final class MovieDetailVM: ObservableObject {

    // MARK: 依赖（可注入）

    let source: MovieDetailDataSource
    let favStore: FavStoreProtocol
    /// 全局 Toast 通道（AppServices.showToast；测试注入收集器）
    var onToast: (String) -> Void

    init(
        source: MovieDetailDataSource? = nil,
        favStore: FavStoreProtocol? = nil,
        onToast: ((String) -> Void)? = nil
    ) {
        #if DEBUG
        self.source = source
            ?? (DemoDataSource.enabled() ? DemoMovieDetailDataSource() : QMovieDetailDataSource())
        #else
        self.source = source ?? QMovieDetailDataSource()
        #endif
        #if DEBUG
        self.favStore = favStore
            ?? (DemoDataSource.enabled() ? MemoryFavStore.shared : LocalFavStore())
        #else
        self.favStore = favStore ?? LocalFavStore()
        #endif
        self.onToast = onToast ?? { AppServices.shared.showToast($0) }
    }

    /// 页面默认构造（demo 全链路 / 生产同签名）
    static func makeDefault() -> MovieDetailVM {
        MovieDetailVM()
    }

    // MARK: 状态

    /// 当前影片 id（bind 记录；幂等判定键）
    private(set) var id = ""
    @Published var loading = false
    @Published var error: String? = nil
    /// 基础行（标量列；嵌套明细拆到下方四个状态）
    @Published var movie: Row? = nil
    @Published var tags: [Row] = []
    /// ♀ 分区在上（gender==1 男沉底，同组保持 movie_actors 原序 —— B.5）
    @Published var actors: [Row] = []
    @Published var magnets: [Row] = []
    @Published var previews: [String] = []
    @Published var relatedArticles: [Row] = []
    /// 影子兜底在线回填封面已完成（Q.movieCovers 单 id 复用）
    @Published var covBackfilled = false
    @Published var fav = false
    @Published var read = false

    private var reqId = 0

    /// derived（磁力区空态分支用：含「离线」→ 离线文案）
    var derived: String { movie?.s("derived") ?? "" }

    // MARK: 生命周期

    /// bind：同一 mid 且已加载数据（或已报错/在载）→ 幂等返回；否则记录并 load()
    func bind(mid: String) async {
        if id == mid && (movie != nil || error != nil || loading) { return }
        id = mid
        await load()
    }

    /// load：置 loading → 取详情 → 写状态 → fav/read 初值 → 进入详情即记已读 →
    /// 相关资讯 → 影子兜底回填封面
    func load() async {
        let mid = id
        reqId += 1
        let rid = reqId
        loading = true
        error = nil
        do {
            // Q.movie 三级回落（远程 → movieLocal 影子/索引 → 探活 → 抛错）在数据源内完成
            let m = try await source.movie(mid: mid)
            guard rid == reqId else { return }
            applyMovie(m)
            let f = await favStore.favIs(kind: "movie", itemId: mid)
            let r = await favStore.historyIs(kind: "movie", itemId: mid)
            guard rid == reqId else { return }
            fav = f
            read = r
            // B.10：进入详情即记已读（浏览页卡片小圆点随之点亮）
            if m != nil {
                await favStore.historyMark(kind: "movie", itemId: mid, title: movie?.s("number") ?? "")
                if rid == reqId { read = true }
            }
            loading = false
            await loadArticles(mid: mid, rid: rid)
            await backfillCoverIfNeeded(rid: rid)
        } catch {
            guard rid == reqId else { return }
            loading = false
            // TODO(P13)：ShadowDb 全字段详情回落当前在 Q.movieLocal 内恒 nil —— 接线后
            // 三级回落语义保持不变（Q 层），本 VM 只消费最终异常。
            self.error = ErrText.of(error)
        }
    }

    /// onDispose 重置（B.10 release：释放整行大对象；再次进入 bind 自动重载）
    func release() {
        id = ""
        loading = false
        error = nil
        movie = nil
        tags = []
        actors = []
        magnets = []
        previews = []
        relatedArticles = []
        covBackfilled = false
        fav = false
        read = false
    }

    // MARK: apply（rid 守卫后拆嵌套明细）

    private func applyMovie(_ m: [String: Any]?) {
        guard let m else {
            movie = nil
            tags = []
            actors = []
            magnets = []
            previews = []
            return
        }
        var r = Row()
        for (k, v) in m where k != "tags" && k != "actors" && k != "magnets" && k != "previews" {
            r[k] = Self.sqlValueOf(v)
        }
        movie = r
        tags = m["tags"] as? [Row] ?? (m["tags"] as? [[String: Any]] ?? []).map(Self.rowOf)
        let actorRows: [Row] =
            m["actors"] as? [Row] ?? (m["actors"] as? [[String: Any]] ?? []).map(Self.rowOf)
        actors = Self.sortActors(actorRows)
        magnets = m["magnets"] as? [Row] ?? (m["magnets"] as? [[String: Any]] ?? []).map(Self.rowOf)
        previews = (m["previews"] as? [String] ?? []).filter { !$0.isEmpty }
    }

    /// ♀ 分区在上：稳定分区（gender==1 男 → 沉底，同组保持原序；gender 缺失当女 —— B.5）
    static func sortActors(_ rows: [Row]) -> [Row] {
        rows.filter { $0.i("gender") != 1 } + rows.filter { $0.i("gender") == 1 }
    }

    /// 相关资讯：失败静默空列表 → 整块隐藏（B.8）
    private func loadArticles(mid: String, rid: Int) async {
        let rows = await source.movieArticles(mid: mid)
        guard rid == reqId else { return }
        relatedArticles = rows
    }

    /// 影子兜底在线回填封面：derived 含「本地缓存」且未回填 → Q.movieCovers([mid]) 回填
    private func backfillCoverIfNeeded(rid: Int) async {
        guard rid == reqId, !covBackfilled, let m = movie else { return }
        guard m.s("derived").contains("本地缓存") else { return }
        let mid = m.s("id")
        guard !mid.isEmpty else { return }
        let covs = await source.movieCovers(ids: [mid])
        guard rid == reqId else { return }
        if let u = covs[mid], !u.isEmpty {
            movie?["cover_url"] = SQLValue.string(u)
            covBackfilled = true
        }
    }

    // MARK: 收藏 / 已读

    /// toggleFav：favToggle("movie", mid, number) → 状态更新 + Toast（B.0 逐字）
    func toggleFav() async {
        let now = await favStore.favToggle(
            kind: "movie", itemId: id, title: movie?.s("number") ?? "")
        fav = now
        onToast(now ? MovieDetailCopy.toastFavOn : MovieDetailCopy.toastFavOff)
    }

    /// markRead：historyMark("movie", mid, number) → read=true（B.10）
    func markRead() async {
        await favStore.historyMark(kind: "movie", itemId: id, title: movie?.s("number") ?? "")
        read = true
    }

    /// 已读按钮点击（View 先把番号写入 UIPasteboard，再调本方法 —— B.4：
    /// 已读 → Toast「已复制」；未读 → Toast「已标记已读」并 markRead()）
    func onReadButtonPressed() async {
        if read {
            onToast(MovieDetailCopy.toastCopied)
        } else {
            onToast(MovieDetailCopy.toastMarkedRead)
            await markRead()
        }
    }

    /// 磁力卡整卡点击（View 先复制完整磁力链接到 UIPasteboard，再调本方法 —— B.7 Toast）
    func onMagnetCopied() {
        onToast(MovieDetailCopy.toastMagnetCopied)
    }

    // MARK: 灯箱 gallery 组装（B.3：[封面] + 剧照，过滤空 URL，同组连续翻页）

    var gallery: [String] {
        var g: [String] = []
        let cov = MovieImg.movieCover(movie?.s("cover_url") ?? "", id)
        if !cov.isEmpty { g.append(cov) }
        g.append(contentsOf: previews.map { MovieImg.preview($0) }.filter { !$0.isEmpty })
        return g
    }

    /// 封面非空才可点（打开 index 0）
    var coverTappable: Bool {
        !MovieImg.movieCover(movie?.s("cover_url") ?? "", id).isEmpty
    }

    /// 剧照第 i 张的灯箱索引（封面占 index 0）
    func galleryIndexOfPreview(_ i: Int) -> Int {
        (coverTappable ? 1 : 0) + i
    }

    // MARK: 磁力卡字段（B.7；VM/页面/测试共用纯函数）

    /// 完整磁力链接（复制内容）
    static func magnetLink(_ mag: Row) -> String {
        "magnet:?xt=urn:btih:" + mag.s("hash")
    }

    /// 角标：{fmtSize(size)}{「 · 中字」若 cnsub}（如 1.2 GB · 中字）
    static func magnetBadge(_ mag: Row) -> String {
        Fmt.fmtSize(mag.s("size")) + (mag.b("cnsub") ? MovieDetailCopy.magnetCnsubSuffix : "")
    }

    /// 次行：name 前 46 字 +（files_count>0 时）「· N 个文件」（take(46) 后直接 join，无空格）
    static func magnetSecondLine(_ mag: Row) -> String {
        var s = String(mag.s("name").prefix(46))
        let files = mag.i("files_count")
        if files > 0 {
            s += MovieDetailCopy.magnetFilesSuffix(files)
        }
        return s
    }

    /// 次行是否渲染（name 与 files_count 至少一项非空）
    static func magnetHasSecondLine(_ mag: Row) -> Bool {
        !mag.s("name").isEmpty || mag.i("files_count") > 0
    }

    // MARK: 反查行（B.4 JumpLines；payload 往返由 LookupCodec 保证）

    /// 五行反查（顺序逐字：片商/系列/导演/发行商/年份；缺值「—」不可点）
    static func jumpLinks(m: Row) -> [MovieJumpLink] {
        var links: [MovieJumpLink] = []

        func add(_ label: String, name: String, idValue: String, filter: (String) -> Filters) {
            guard !name.isEmpty || !idValue.isEmpty else {
                links.append(MovieJumpLink(label: label, value: MovieDetailCopy.missingValue,
                                           payload: nil))
                return
            }
            let v = name.isEmpty ? idValue : name
            let payload = LookupCodec.encode(
                LookupSpec(filters: filter(idValue), label: label + v))
            links.append(MovieJumpLink(label: label, value: v, payload: payload))
        }

        // 1 片商：maker_name（为空显示 maker_id）→ Filters(maker = maker_id)
        add(MovieDetailCopy.jumpMaker, name: m.s("maker_name"), idValue: m.s("maker_id")) {
            Filters(maker: $0)
        }
        // 2 系列：series_name / series_id → Filters(seriesId)
        add(MovieDetailCopy.jumpSeries, name: m.s("series_name"), idValue: m.s("series_id")) {
            Filters(seriesId: $0)
        }
        // 3 导演：director_name / director_id → Filters(directorId)
        add(MovieDetailCopy.jumpDirector, name: m.s("director_name"), idValue: m.s("director_id")) {
            Filters(directorId: $0)
        }
        // 4 发行商：publisher_name / publisher_id → Filters(publisherId)
        add(MovieDetailCopy.jumpPublisher, name: m.s("publisher_name"),
            idValue: m.s("publisher_id")) {
            Filters(publisherId: $0)
        }
        // 5 年份：release_date 前 4 位 → Filters(year)；无发行日期整行缺值
        let rd = m.s("release_date")
        if rd.count >= 4 {
            let y = String(rd.prefix(4))
            links.append(MovieJumpLink(
                label: MovieDetailCopy.jumpYear, value: y,
                payload: LookupCodec.encode(
                    LookupSpec(filters: Filters(year: y), label: MovieDetailCopy.jumpYear + y))))
        } else {
            links.append(MovieJumpLink(
                label: MovieDetailCopy.jumpYear, value: MovieDetailCopy.missingValue, payload: nil))
        }
        return links
    }

    /// 标签行：tag_id 为空的条目跳过；payload = LookupSpec(Filters(tags = tag_id), "标签：{name}")
    static func tagLinks(tags: [Row]) -> [(name: String, payload: String)] {
        tags.compactMap { t in
            let tid = t.s("tag_id")
            guard !tid.isEmpty else { return nil }
            let name = t.s("tag_name")
            let payload = LookupCodec.encode(
                LookupSpec(filters: Filters(tags: tid), label: MovieDetailCopy.jumpTagPrefix + name))
            return (name: name, payload: payload)
        }
    }

    // MARK: [String: Any] ↔ Row / SQLValue 转换（Q.jrow 为 internal，此处等价实现）

    nonisolated static func rowOf(_ r: Row) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in r.map { out[k] = anyOf(v) }
        return out
    }

    nonisolated static func rowOf(_ d: [String: Any]) -> Row {
        var r = Row()
        for (k, v) in d { r[k] = Self.sqlValueOf(v) }
        return r
    }

    /// SQLValue → Any（null → NSNull）
    nonisolated static func anyOf(_ v: SQLValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .data(let d): return d
        case .bool(let b): return b
        }
    }

    /// Any → SQLValue（Any? 桥接：NSNull/nil → .null；数值/字符串/布尔逐一尝试）
    nonisolated static func sqlValueOf(_ v: Any) -> SQLValue {
        switch v {
        case is NSNull:
            return .null
        case let s as String:
            return .string(s)
        case let b as Bool:
            return .bool(b)
        case let i as Int64:
            return .int(i)
        case let i as Int:
            return .int(Int64(i))
        case let d as Double:
            return .double(d)
        case let d as Data:
            return .data(d)
        default:
            return .string(String(describing: v))
        }
    }
}
