import Foundation

//
//  Indexer —— 影子/索引写入单点。
//  对齐 Android app/src/main/java/com/jdlv/mobile/core/cache/Indexer.kt
//  （提取对照: docs/_extract/06_store.md §8, 模式/语义逐字）。
//
//  职责（逐字注释精神）:
//  - 被动填充: 任何列表 / 详情 / 搜索结果「返回即 upsert」（幂等, 失败静默 —— 绝不影响主查询流程）;
//    绝不主动全量拉取（主动预热是 SyncCoordinator 的事, 且只拉"最近 N 条"）。
//  - 写入目标 IdxDb（键表+标题原文, 不建 FTS）:
//    · 列表页 upsertMovies/upsertThreads → 只写 IdxDb;
//    · fullMode（Android shadowMode == 0 "完整影子"旧模式）时兼容双写 ShadowDb（无 FTS）;
//    · 详情 upsertMovieDetail/upsertThreadDetail 仍写 ShadowDb（详情缓存, 含 magnets_local,
//      LRU 5000 行容量保护）+ 同时写 IdxDb（打开过的可本地检索）+ 关系 replace;
//  - enabled 语义不变（shadowEnabled 控制; iOS 由 App 层注入 prefs 值）。
//
//  与 Android 的差异（刻意）:
//  - Android 用 CoroutineScope fire-and-forget Async 入口; iOS P5 为同步 API（调用方自行落后台队列）。
//  - fullMode 依赖的 prefs（shadowMode）不在 P5 范围 → App 层注入布尔值, 默认 false。
//
public final class Indexer {

    private let lock = NSLock()
    private var _enabled = false

    /// 被动落盘开关（Android: MainVm 启动/设置变更赋 prefs.shadowEnabled）
    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    /// Android fullMode() = prefs.shadowMode == 0（"完整影子"旧模式: 列表写入兼容双写 ShadowDb）。
    /// iOS prefs 不在 P5 范围 → App 层注入; 默认 false（只写 IdxDb）。
    public var fullMode: Bool = false

    public let idxDb: IdxDb?
    public let shadowDb: ShadowDb?

    /// Indexer 自身 ok/fail 打点（ShadowDb 侧失败上抛被这里吞掉; IdxDb 侧打点在其 stats 内）
    public let stats = IdxWriteStats()

    public init(idxDb: IdxDb?, shadowDb: ShadowDb?) {
        self.idxDb = idxDb
        self.shadowDb = shadowDb
    }

    // MARK: - 列表被动落盘（总是写 IdxDb; fullMode 时兼容双写 ShadowDb）

    /// 影片列表/搜索结果返回即 upsert（幂等, 整个列表一次事务）。
    public func upsertMovieRows(_ rows: [Row]) {
        guard enabled else { return }
        idxDb?.upsertMovies(rows)
        if fullMode { tryShadow("indexer.upsertMovies") { try $0.upsertMovies(rows) } }
    }

    public func upsertMovieRow(_ row: Row) {
        upsertMovieRows([row])
    }

    /// 帖子列表返回即 upsert。
    public func upsertThreadRows(_ rows: [Row]) {
        guard enabled else { return }
        idxDb?.upsertThreads(rows)
        if fullMode { tryShadow("indexer.upsertThreads") { try $0.upsertThreads(rows) } }
    }

    public func upsertThreadRow(_ row: Row) {
        upsertThreadRows([row])
    }

    /// 女优列表页返回即 upsert。
    public func upsertActorRows(_ rows: [Row]) {
        guard enabled else { return }
        idxDb?.upsertActors(rows)
        if fullMode { tryShadow("indexer.upsertActors") { try $0.upsertActors(rows) } }
    }

    // MARK: - 详情落盘（ShadowDb 全字段 + IdxDb 键行 + 关系 replace）

    /// 影片详情（远程成功路径）: 详情是「全量快照」—— 关系必须 replace（先删后插）,
    /// 否则远程删掉的旧标签/旧女优会永久留在本地。只在详情成功路径调用。
    public func upsertMovieDetail(
        _ row: Row, tags: [Row], actors: [Row], magnets: [Row]
    ) {
        guard enabled else { return }
        tryShadow("indexer.upsertMovieDetail") {
            try $0.upsertMovieDetail(row, tags: tags, actors: actors, magnets: magnets)
        }
        idxDb?.upsertMovies([row])
        let mid = row.isNull("id") ? "" : row.s("id")
        let tagIds = tags
            .compactMap { $0.isNull("tag_id") ? nil : $0.s("tag_id") }
            .filter { !$0.isEmpty }                      // 空 id 剔除
        let actorIds = actors
            .compactMap { $0.isNull("actor_id") ? nil : $0.s("actor_id") }
            .filter { !$0.isEmpty }
        idxDb?.replaceMovieTags(movieId: mid, tagIds: tagIds)
        idxDb?.replaceMovieActors(movieId: mid, actorIds: actorIds)
    }

    /// 帖子详情（远程成功路径）。
    public func upsertThreadDetail(_ row: Row, magnets: [Row]) {
        guard enabled else { return }
        tryShadow("indexer.upsertThreadDetail") {
            try $0.upsertThreadDetail(row, magnets: magnets)
        }
        idxDb?.upsertThreads([row])
    }

    // MARK: - 内部

    /// ShadowDb 写失败静默（打点不抛 —— 绝不影响主查询流程）。
    private func tryShadow(_ op: String, _ body: (ShadowDb) throws -> Void) {
        guard let shadowDb else { return }
        do {
            try body(shadowDb)
            stats.ok()
        } catch {
            _ = stats.fail(op: op, error: error)
        }
    }
}
