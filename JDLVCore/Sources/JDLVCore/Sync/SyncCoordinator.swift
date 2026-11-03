import Foundation

//
//  SyncCoordinator —— 离线预热引擎（P10）。
//  对齐 Android app/src/main/java/com/jdlv/mobile/core/sync/SyncCoordinator.kt（1053 行）
//  （提取对照: docs/_extract/05_sync.md §1/§7, 状态机 SQL / 游标键 / 数值逐字）。
//
//  要点（全部照搬 Android）:
//  - movies 状态机 head(1000) → same(500) → tail(500) → null(500) → done；threads tid keyset 1000；
//    actors id keyset 500（无目标/裁剪逻辑）；links/tags IN(...) 随 movies 批顺带。
//  - 每批: runId 检查 → IdxDb.upsert* → links/tags → WarmCursor.advance → 游标持久化
//    （idx_meta 键逐字: m_phase/m_date/m_id/m_done/m_target/m_head_ts、t_tid/t_done/t_target、
//    a_id/a_done、movies_n/movies_ts/threads_n/threads_ts）。upsert 成功后才前进。
//  - 单飞: NSLock.try() 拿不到 → ALREADY_RUNNING；stopAndJoin 等 runMutex 释放。
//  - runId 双保险: 三路在每次 upsert 前检查 currentRunId != runId → return（旧批不得写回）。
//  - TargetPlanPolicy.plan 轮首+批后决策；PruneSql 裁剪（Failed → m_done=0 + 5min 退避）；
//    finishRun: 24h 增量 / 5min 退避 / 3 连败 Long.max 停手 / moreWork → 2s auto-raise。
//  - 速度 = runRows*60000/max(1,elapsed)；ETA = remain*60/speed（speed>10 且 target>0）。
//  - applyLimits 全分支接 LimitTransition.decide（NO_CHANGE/META_ONLY/PRUNE_ONLY/
//    PRUNE_AND_RESTART/RESTART/DEFER_OFFLINE），裁剪离线也执行。
//  - 门禁: probe(input:) 封装 WarmGate（动态字段 running/done*/nextRunAt 由本类填）。
//
//  与 Android 的差异（刻意）:
//  - object 单例 → 注入式 final class（IdxDb/WarmSource/设置提供器/ShadowDb/Indexer 均注入），
//    Android 的 Prefs 读取 → WarmSettings 快照提供器；isLanNetwork()（WiFi/以太网）由 App 层
//    作为 WarmGateInput.wifi 传入（本文件不做系统网络探测）。
//  - idleCheck 的 30s 定时循环不在 Core（App 层驱动）；本类提供 idleCheck(input:) 单次巡检。
//  - Android Log.w（links/tags 失败只记日志）→ Perf.mark；Log.d → Perf.mark。
//  - 源列探测（Db.cols）移入 WarmDbSource（协议只暴露查询），惰性探测一次并缓存。
//

// MARK: - StartResult / SyncState / WarmSettings / SyncConfig

/// start 系列返回值（逐字；NO_TARGET 在 Android 本文件内从未被返回，仅为兼容保留）。
public enum StartResult: Equatable {
    case STARTED
    case ALREADY_RUNNING
    case NO_TARGET
    case DISABLED
    case NO_CHANGE
}

/// 预热状态快照（字段与默认值逐字对齐 Android SyncState）。
public struct SyncState: Equatable {
    public var running: Bool = false
    public var paused: Bool = false
    public var phase: String = "idle"       // idle/head/tail/same/null/threads/actors/done/error
    public var movies: Int64 = 0
    public var threads: Int64 = 0
    public var actors: Int64 = 0
    public var links: Int64 = 0
    public var actorTotal: Int64 = 0
    public var targetMovies: Int64 = 0      // 0 = 不限
    public var targetThreads: Int64 = 0
    public var speedPerMin: Int = 0
    public var etaSec: Int64 = 0
    public var idxBytes: Int64 = 0
    public var detailBytes: Int64 = 0
    public var lastError: String = ""
    public var lastRunAt: Int64 = 0
    public var nextRunAt: Int64 = 0
    public var note: String = ""
    public var mode: String = ""

    public init() {}
}

/// 预热所需设置快照（App 层从 prefs 组装；Android 对位字段见注释）。
public struct WarmSettings {
    /// shadowEnabled（总开关）
    public var enabled: Bool
    /// shadowMode == 1（仅索引）
    public var idxMode: Bool
    /// shadowLimitJdb（落盘 0=不限）
    public var limitJdb: Int
    /// shadowLimitSht
    public var limitSht: Int
    /// shadowActorIndex
    public var actorIndex: Bool
    /// shadowActorLinks
    public var actorLinks: Bool
    /// shadowTagIndex（默认开）
    public var tagIndex: Bool

    public init(
        enabled: Bool = true, idxMode: Bool = true,
        limitJdb: Int = 0, limitSht: Int = 0,
        actorIndex: Bool = true, actorLinks: Bool = true, tagIndex: Bool = true
    ) {
        self.enabled = enabled
        self.idxMode = idxMode
        self.limitJdb = limitJdb
        self.limitSht = limitSht
        self.actorIndex = actorIndex
        self.actorLinks = actorLinks
        self.tagIndex = tagIndex
    }
}

/// 引擎常数/时限（默认值 = Android 逐字常量；测试可缩小时延/注入时钟与离线判定）。
public struct SyncConfig {
    /// movies head 批 1000
    public var movieHeadBatch: Int = 1000
    /// movies 批 500（SAME/NULL/TAIL）
    public var movieBatch: Int = 500
    /// threads head/批 1000
    public var threadBatch: Int = 1000
    /// actors head/批 500
    public var actorBatch: Int = 500
    /// 循环 guard 上限: movies/threads 200_000
    public var movieLoopGuard: Int = 200_000
    public var threadLoopGuard: Int = 200_000
    /// actors 100_000
    public var actorLoopGuard: Int = 100_000
    /// 批间 delay: movies 150ms / threads 150ms / actors 200ms
    public var movieDelayMs: Int64 = 150
    public var threadDelayMs: Int64 = 150
    public var actorDelayMs: Int64 = 200
    /// auto-raise 重启延迟 2_000 ms（finishRun moreWork）
    public var autoRaiseDelayMs: Int64 = 2_000
    public var autoRaiseEnabled: Bool = true
    /// 进度推送节流 1_000 ms
    public var pushThrottleMs: Int64 = 1_000
    /// 体积刷新节流 30_000 ms
    public var volThrottleMs: Int64 = 30_000
    /// 时钟（System.currentTimeMillis 对位；测试注入）
    public var clock: () -> Int64 = { Perf.nowMs() }
    /// 离线判定（Android Db.offlineJdb/offlineSht 对位；测试经 OfflineGate 控制）
    public var offlineJdb: () -> Bool = { Db.offlineJdb }
    public var offlineSht: () -> Bool = { Db.offlineSht }

    public init() {}
}

// MARK: - WarmSource（查询抽象；生产包 Db.query，测试注入内存假源）

/// 预热查询源（Android 侧为 SyncCoordinator 内直接 Db.query；iOS 抽成协议便于测试注入）。
public protocol WarmSource {
    /// SELECT $cols FROM movies m ORDER BY m.release_date DESC, m.id DESC LIMIT 1000
    func moviesHead(batch: Int) async throws -> [Row]
    /// SELECT ... WHERE m.release_date = ? AND m.id < ? ORDER BY m.id DESC LIMIT ?（500）
    func moviesSame(date: String, beforeId: String, batch: Int) async throws -> [Row]
    /// SELECT ... WHERE m.release_date < ? ORDER BY m.release_date DESC, m.id DESC LIMIT ?（500）
    func moviesTail(date: String, batch: Int) async throws -> [Row]
    /// SELECT ... WHERE (m.release_date IS NULL OR m.release_date = '') ORDER BY m.id DESC LIMIT ?（500）
    func moviesNullFirst(batch: Int) async throws -> [Row]
    /// SELECT ... WHERE (…IS NULL OR …='') AND m.id < ? ORDER BY m.id DESC LIMIT ?（500）
    func moviesNullTail(beforeId: String, batch: Int) async throws -> [Row]
    /// SELECT $cols FROM $tt ORDER BY tid DESC LIMIT ?（1000）
    func threadsFirst(batch: Int) async throws -> [Row]
    /// SELECT $cols FROM $tt WHERE tid < ? ORDER BY tid DESC LIMIT ?（1000）
    func threads(beforeTid: Int64, batch: Int) async throws -> [Row]
    /// SELECT $cols FROM actors [WHERE id < ?] ORDER BY id DESC LIMIT ?（500）
    func actors(beforeId: String, batch: Int) async throws -> [Row]
    /// SELECT movie_id, actor_id FROM movie_actors WHERE movie_id IN (...)
    func links(movieIds: [String]) async throws -> [Row]
    /// SELECT movie_id, tag_id FROM movie_tags WHERE movie_id IN (...)
    func tags(movieIds: [String]) async throws -> [Row]
}

// MARK: - 生产源（shadow.warm 模板 SQL 逐字；jdb=movies/actors，sht=threads 表名经 Db.tableOf）

/// 生产 WarmSource：模板 SQL 逐字对齐 Android warmMovies/warmThreads/warmActors。
/// 列探测（Db.cols）失败按"全有"容错（Android runCatching.getOrDefault(emptySet()) 同语义）。
public final class WarmDbSource: WarmSource {

    public init() {}

    // MARK: SQL 模板（逐字；public/internal 供测试锁定文案）

    public static let MOVIE_BASE_COLS =
        "id, number, title, release_date, year, score, want_watch_count, magnets_count, number_letter"
    public static let MOVIE_EXTRA_COLS = ["maker_id", "series_id", "director_id", "publisher_id"]
    public static let THREAD_COLS_ALL = [
        "tid", "title", "post_date", "board", "board_name", "type",
        "magnet_count", "article_words", "paywalled",
    ]
    public static let ACTOR_COLS_ALL = [
        "id", "name", "name_zht", "avatar_url", "videos_count", "gender",
        "popularity", "avg_score_all", "avg_score_solo", "debut", "merged_into",
    ]

    public static func moviesHeadSql(_ cols: String) -> String {
        "SELECT \(cols) FROM movies m ORDER BY m.release_date DESC, m.id DESC LIMIT 1000"
    }

    public static func moviesSameSql(_ cols: String) -> String {
        "SELECT \(cols) FROM movies m WHERE m.release_date = ? AND m.id < ? ORDER BY m.id DESC LIMIT ?"
    }

    public static func moviesTailSql(_ cols: String) -> String {
        "SELECT \(cols) FROM movies m WHERE m.release_date < ? ORDER BY m.release_date DESC, m.id DESC LIMIT ?"
    }

    public static func moviesNullFirstSql(_ cols: String) -> String {
        "SELECT \(cols) FROM movies m WHERE (m.release_date IS NULL OR m.release_date = '') ORDER BY m.id DESC LIMIT ?"
    }

    public static func moviesNullTailSql(_ cols: String) -> String {
        "SELECT \(cols) FROM movies m WHERE (m.release_date IS NULL OR m.release_date = '') AND m.id < ? ORDER BY m.id DESC LIMIT ?"
    }

    public static func threadsFirstSql(table: String, cols: String) -> String {
        "SELECT \(cols) FROM \(table) ORDER BY tid DESC LIMIT ?"
    }

    public static func threadsKeysetSql(table: String, cols: String) -> String {
        "SELECT \(cols) FROM \(table) WHERE tid < ? ORDER BY tid DESC LIMIT ?"
    }

    public static func actorsHeadSql(_ cols: String) -> String {
        "SELECT \(cols) FROM actors ORDER BY id DESC LIMIT ?"
    }

    public static func actorsKeysetSql(_ cols: String) -> String {
        "SELECT \(cols) FROM actors WHERE id < ? ORDER BY id DESC LIMIT ?"
    }

    public static func linksSql(_ ids: [String]) -> String {
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        return "SELECT movie_id, actor_id FROM movie_actors WHERE movie_id IN (\(ph))"
    }

    public static func tagsSql(_ ids: [String]) -> String {
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        return "SELECT movie_id, tag_id FROM movie_tags WHERE movie_id IN (\(ph))"
    }

    // MARK: 列清单（惰性探测一次并缓存）

    private var _movieCols: String?
    private var _threadCols: [String: String] = [:]
    private var _actorCols: String?
    private let colsLock = NSLock()

    private func movieCols() async -> String {
        colsLock.lock()
        if let c = _movieCols { colsLock.unlock(); return c }
        colsLock.unlock()
        let have = (try? await Db.cols("jdb", "movies")) ?? Set<String>()
        let extra = Self.MOVIE_EXTRA_COLS.filter { have.isEmpty || have.contains($0) }
        let c = Self.MOVIE_BASE_COLS + (extra.isEmpty ? "" : ", " + extra.joined(separator: ", "))
        colsLock.lock(); _movieCols = c; colsLock.unlock()
        return c
    }

    private func threadCols(table: String) async -> String {
        colsLock.lock()
        if let c = _threadCols[table] { colsLock.unlock(); return c }
        colsLock.unlock()
        let have = (try? await Db.cols("sht", table)) ?? Set<String>()
        let c = Self.THREAD_COLS_ALL
            .filter { $0 == "tid" || have.isEmpty || have.contains($0) }
            .joined(separator: ", ")
        colsLock.lock(); _threadCols[table] = c; colsLock.unlock()
        return c
    }

    private func actorCols() async -> String {
        colsLock.lock()
        if let c = _actorCols { colsLock.unlock(); return c }
        colsLock.unlock()
        let have = (try? await Db.cols("jdb", "actors")) ?? Set<String>()
        let c = Self.ACTOR_COLS_ALL
            .filter { $0 == "id" || $0 == "name" || have.isEmpty || have.contains($0) }
            .joined(separator: ", ")
        colsLock.lock(); _actorCols = c; colsLock.unlock()
        return c
    }

    // MARK: WarmSource

    public func moviesHead(batch: Int) async throws -> [Row] {
        _ = batch   // head 模板 LIMIT 内联 1000（Android 逐字），batch 恒为 1000
        let cols = await movieCols()
        return try await Db.query("jdb", Self.moviesHeadSql(cols))
    }

    public func moviesSame(date: String, beforeId: String, batch: Int) async throws -> [Row] {
        let cols = await movieCols()
        return try await Db.query(
            "jdb", Self.moviesSameSql(cols),
            [SQLValue?.some(.string(date)), .some(.string(beforeId)), .some(.int(Int64(batch)))])
    }

    public func moviesTail(date: String, batch: Int) async throws -> [Row] {
        let cols = await movieCols()
        return try await Db.query(
            "jdb", Self.moviesTailSql(cols),
            [SQLValue?.some(.string(date)), .some(.int(Int64(batch)))])
    }

    public func moviesNullFirst(batch: Int) async throws -> [Row] {
        let cols = await movieCols()
        return try await Db.query(
            "jdb", Self.moviesNullFirstSql(cols), [SQLValue?.some(.int(Int64(batch)))])
    }

    public func moviesNullTail(beforeId: String, batch: Int) async throws -> [Row] {
        let cols = await movieCols()
        return try await Db.query(
            "jdb", Self.moviesNullTailSql(cols),
            [SQLValue?.some(.string(beforeId)), .some(.int(Int64(batch)))])
    }

    public func threadsFirst(batch: Int) async throws -> [Row] {
        let tt = await Db.tableOf("sht", "threads")
        let cols = await threadCols(table: tt)
        return try await Db.query(
            "sht", Self.threadsFirstSql(table: tt, cols: cols),
            [SQLValue?.some(.int(Int64(batch)))])
    }

    public func threads(beforeTid: Int64, batch: Int) async throws -> [Row] {
        let tt = await Db.tableOf("sht", "threads")
        let cols = await threadCols(table: tt)
        return try await Db.query(
            "sht", Self.threadsKeysetSql(table: tt, cols: cols),
            [SQLValue?.some(.string(String(beforeTid))), .some(.int(Int64(batch)))])
    }

    public func actors(beforeId: String, batch: Int) async throws -> [Row] {
        let cols = await actorCols()
        if beforeId.isEmpty {
            return try await Db.query("jdb", Self.actorsHeadSql(cols), [SQLValue?.some(.int(Int64(batch)))])
        }
        return try await Db.query(
            "jdb", Self.actorsKeysetSql(cols),
            [SQLValue?.some(.string(beforeId)), .some(.int(Int64(batch)))])
    }

    public func links(movieIds: [String]) async throws -> [Row] {
        try await Db.query("jdb", Self.linksSql(movieIds), movieIds.map { SQLValue?.some(.string($0)) })
    }

    public func tags(movieIds: [String]) async throws -> [Row] {
        try await Db.query("jdb", Self.tagsSql(movieIds), movieIds.map { SQLValue?.some(.string($0)) })
    }
}

/// 生产源工厂（对位 Android SyncCoordinator 内直接 Db.query 的入口）。
public func WarmDbSourceFactory() -> WarmSource {
    WarmDbSource()
}

// MARK: - SyncCoordinator

public final class SyncCoordinator: @unchecked Sendable {

    /// 不限哨兵（Long.MAX_VALUE / 2 对位；LimitMath.targetOf(0) 同值）
    static let UNLIM = Int64.max / 2
    /// TAIL 兜底哨兵日期（Android 内联字面量 "9999-12-31"）
    static let TAIL_SENTINEL_DATE = "9999-12-31"
    /// 退避/周期常量（ms，逐字）
    static let BACKOFF_5MIN: Int64 = 5 * 60_000

    // MARK: 依赖

    public let idx: IdxDb
    private let source: WarmSource
    private let settingsProvider: () -> WarmSettings
    private let shadow: ShadowDb?
    private let indexer: Indexer?
    public let config: SyncConfig

    // MARK: 锁与运行期状态（@Volatile 对位）

    private let runMutex = NSLock()          // 单飞：持有整轮运行
    private let limitMutex = NSLock()        // applyLimits 串行
    private let ctlLock = NSLock()
    private var _currentRunId: Int64 = 0
    private var _stopRequested = false
    private var _nextRunAt: Int64 = 0
    private var _consecutiveFails = 0
    private var _runTargetHit = false
    private var _pruneFailMsg = ""
    private var _srcOfflineM = false
    private var _srcOfflineT = false
    private var _srcOfflineA = false
    private var _prefTargetM = 0
    private var _prefTargetT = 0
    private var _targetsLoaded = false
    private var _jobActive = false
    private var _runRows: Int64 = 0
    private var _runStartMs: Int64 = 0
    private var _lastPush: Int64 = 0
    private var _lastVolMs: Int64 = 0
    private var _curPhaseM = ""
    private var _curPhaseT = ""
    private var _curPhaseA = ""

    private let stateLock = NSLock()
    private var _state = SyncState()

    private var warmJob: Task<Void, Never>?

    // 测试 seam（@testable 注入/断言用）
    internal private(set) var lastTrigger: String = ""
    internal private(set) var lastRunId: Int64 = 0

    // MARK: init

    public init(
        idx: IdxDb,
        source: WarmSource,
        settings: @escaping () -> WarmSettings,
        shadow: ShadowDb? = nil,
        indexer: Indexer? = nil,
        config: SyncConfig = SyncConfig()
    ) {
        self.idx = idx
        self.source = source
        self.settingsProvider = settings
        self.shadow = shadow
        self.indexer = indexer
        self.config = config
    }

    // MARK: - 基础读取

    private func now() -> Int64 { config.clock() }

    public var state: SyncState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private func updateState(_ m: (inout SyncState) -> Void) {
        stateLock.lock(); m(&_state); stateLock.unlock()
    }

    public func isRunning() -> Bool {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _jobActive
    }

    public var nextRunAt: Int64 {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _nextRunAt
    }

    public var consecutiveFails: Int {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _consecutiveFails
    }

    private var prefTargetMValue: Int {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _prefTargetM
    }

    private var prefTargetTValue: Int {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _prefTargetT
    }

    private var currentRunIdValue: Int64 {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _currentRunId
    }

    private var stopRequestedValue: Bool {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _stopRequested
    }

    private var runRowsValue: Int64 {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _runRows
    }

    private var runStartMsValue: Int64 {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _runStartMs
    }

    private var pruneFailMsgValue: String {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _pruneFailMsg
    }

    private var runTargetHitValue: Bool {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _runTargetHit
    }

    private var srcOfflineMValue: Bool {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _srcOfflineM
    }

    private var srcOfflineTValue: Bool {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _srcOfflineT
    }

    private var srcOfflineAValue: Bool {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return _srcOfflineA
    }

    private var curPhaseSnapshot: (m: String, t: String, a: String) {
        ctlLock.lock(); defer { ctlLock.unlock() }
        return (_curPhaseM, _curPhaseT, _curPhaseA)
    }

    private func setStopRequested(_ v: Bool) { ctlLock.lock(); _stopRequested = v; ctlLock.unlock() }
    private func setNextRunAt(_ v: Int64) { ctlLock.lock(); _nextRunAt = v; ctlLock.unlock() }
    private func setRunTargetHit(_ v: Bool) { ctlLock.lock(); _runTargetHit = v; ctlLock.unlock() }
    private func setPruneFailMsg(_ v: String) { ctlLock.lock(); _pruneFailMsg = v; ctlLock.unlock() }
    private func setSrcOfflineM(_ v: Bool) { ctlLock.lock(); _srcOfflineM = v; ctlLock.unlock() }
    private func setSrcOfflineT(_ v: Bool) { ctlLock.lock(); _srcOfflineT = v; ctlLock.unlock() }
    private func setSrcOfflineA(_ v: Bool) { ctlLock.lock(); _srcOfflineA = v; ctlLock.unlock() }
    private func setJobActive(_ v: Bool) { ctlLock.lock(); _jobActive = v; ctlLock.unlock() }
    private func setCurPhaseM(_ v: String) { ctlLock.lock(); _curPhaseM = v; ctlLock.unlock() }
    private func setCurPhaseT(_ v: String) { ctlLock.lock(); _curPhaseT = v; ctlLock.unlock() }
    private func setCurPhaseA(_ v: String) { ctlLock.lock(); _curPhaseA = v; ctlLock.unlock() }
    private func setPrefTargets(m: Int, t: Int) {
        ctlLock.lock(); _prefTargetM = m; _prefTargetT = t; ctlLock.unlock()
    }

    /// 测试 seam：模拟 applyLimits 对 prefTarget 的热更通道（不停止当前轮）
    internal func testOnlySetPrefTargets(m: Int, t: Int) {
        setPrefTargets(m: m, t: t)
    }

    /// 测试 seam：模拟"另一协程已 start/rebuild 使旧 runId 失效"
    internal func testOnlySetCurrentRunId(_ v: Int64) {
        ctlLock.lock(); _currentRunId = v; ctlLock.unlock()
    }

    /// 测试 seam
    internal func testOnlySetNextRunAt(_ v: Int64) {
        setNextRunAt(v)
    }

    private func delayMs(_ ms: Int64) async {
        guard ms > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    // MARK: - start / resume / stop / stopAndJoin

    /// 单飞起跑。force=true 跳过 shadowEnabled（设置页开关/手动/resume/rebuild）。
    /// limitJdb/limitSht 显式覆盖本次目标（0=不限），优先于设置提供器。
    @discardableResult
    public func start(
        trigger: String = "manual", limitJdb: Int? = nil, limitSht: Int? = nil, force: Bool = false
    ) -> StartResult {
        let s = settingsProvider()
        if !force && !s.enabled { return .DISABLED }
        guard runMutex.try() else { return .ALREADY_RUNNING }
        setStopRequested(false)
        let runId = now()
        setJobActive(true)
        ctlLock.lock(); _currentRunId = runId; ctlLock.unlock()
        indexer?.enabled = true
        lastTrigger = trigger
        lastRunId = runId
        warmJob = Task { [weak self] in
            guard let self else { return }
            defer {
                self.setJobActive(false)
                self.runMutex.unlock()
            }
            await self.runWarm(runId, trigger, limitJdb, limitSht)
        }
        return .STARTED
    }

    /// 开关关闭也可手动续跑 = start("resume", force=true)。
    @discardableResult
    public func resume(limitJdb: Int? = nil, limitSht: Int? = nil) -> StartResult {
        start(trigger: "resume", limitJdb: limitJdb, limitSht: limitSht, force: true)
    }

    /// 兼容旧调用点：异步 stop。
    public func stop() {
        Task { await self.stopAndJoin() }
    }

    /// 置 stopRequested → join → 等 runMutex 释放（持有者 finally unlock）→ 状态置已暂停。
    public func stopAndJoin() async {
        setStopRequested(true)
        if let job = warmJob {
            _ = await job.result
        }
        // 等 runMutex 释放, 保证清理/重建不与写入并发
        runMutex.lock()
        runMutex.unlock()
        updateState {
            $0.running = false
            $0.paused = true
            $0.note = "已暂停 (断点已保存, 可继续索引)"
        }
    }

    // MARK: - rebuild / clearAll

    /// 清空索引库 + 游标并 force 重跑。
    public func rebuild(limitJdb: Int? = nil, limitSht: Int? = nil) async {
        await stopAndJoin()
        // 使旧 runId 失效
        ctlLock.lock(); _currentRunId = now(); ctlLock.unlock()
        idx.clearAll()
        idx.clearCursor()
        idx.metaPutLong("m_done", 0)
        idx.metaPutLong("t_done", 0)
        idx.metaPutLong("a_done", 0)
        ctlLock.lock(); _consecutiveFails = 0; _nextRunAt = 0; ctlLock.unlock()
        resetStateAfterClear()
        _ = start(trigger: "rebuild", limitJdb: limitJdb, limitSht: limitSht, force: true)
        refreshStats()
    }

    /// 清空影子库（若有）+ 索引库与游标（不自动重跑）。
    public func clearAll() async {
        await stopAndJoin()
        try? shadow?.clear()
        ctlLock.lock(); _currentRunId = now(); ctlLock.unlock()
        idx.clearAll()
        idx.clearCursor()
        idx.metaPutLong("m_done", 0)
        idx.metaPutLong("t_done", 0)
        idx.metaPutLong("a_done", 0)
        ctlLock.lock(); _consecutiveFails = 0; _nextRunAt = 0; ctlLock.unlock()
        resetStateAfterClear()
        refreshStats()
    }

    private func resetStateAfterClear() {
        updateState {
            $0.movies = 0; $0.threads = 0; $0.actors = 0; $0.links = 0; $0.actorTotal = 0
            $0.phase = "idle"; $0.paused = false; $0.lastError = ""
            $0.speedPerMin = 0; $0.etaSec = 0; $0.note = "空闲"
        }
    }

    // MARK: - 巡检门禁（WarmGate 封装）

    /// 门禁封装：running/doneM/doneT/doneA/nextRunAt 由本类实时值覆盖，其余取 input。
    public func probe(input: WarmGateInput) -> String {
        let i = preparedGateInput(input)
        return WarmGate.reason(i)
    }

    public func probeShouldStart(input: WarmGateInput) -> Bool {
        WarmGate.shouldStart(preparedGateInput(input))
    }

    /// 巡检一次（Android idleCheck 单次对位）：打点 + shouldStart 且未运行时 start("auto")。
    @discardableResult
    public func idleCheck(input: WarmGateInput) -> String {
        let i = preparedGateInput(input)
        let why = WarmGate.reason(i)
        Perf.mark("shadow.idle", "reason=\(why)")
        if WarmGate.shouldStart(i) && !isRunning() {
            Perf.mark("shadow.auto", "reason=\(why)")
            _ = start(trigger: "auto")
        }
        return why
    }

    private func preparedGateInput(_ input: WarmGateInput) -> WarmGateInput {
        var i = input
        i.running = isRunning()
        i.doneM = idx.metaGetLong("m_done", 0) == 1
        i.doneT = idx.metaGetLong("t_done", 0) == 1
        i.doneA = idx.metaGetLong("a_done", 0) == 1
        i.nextRunAt = nextRunAt
        return i
    }

    // MARK: - applyLimits（上限热更新）

    /// 显式 old→new 版本（主入口）。
    @discardableResult
    public func applyLimits(prevM: Int, prevT: Int, nextM: Int, nextT: Int) -> StartResult {
        setPrefTargets(m: nextM, t: nextT)
        ctlLock.lock(); _targetsLoaded = true; ctlLock.unlock()
        updateState {
            $0.targetMovies = nextM <= 0 ? 0 : Int64(nextM)
            $0.targetThreads = nextT <= 0 ? 0 : Int64(nextT)
        }
        Perf.mark("shadow.target", "source=applyLimits m=\(prevM)->\(nextM) t=\(prevT)->\(nextT)")
        if prevM == nextM && prevT == nextT {
            if !isRunning() { _ = resume() }
            return .NO_CHANGE
        }
        let wasRunning = isRunning()
        Task { [weak self] in
            await self?.applyLimitsBody(prevM, prevT, nextM, nextT, wasRunning)
        }
        return .STARTED
    }

    /// 兼容旧调用点：old 值取 ensureTargetsFromPrefs 归一后的 prefTarget。
    @discardableResult
    public func applyLimits(nextM: Int, nextT: Int) -> StartResult {
        ensureTargetsFromPrefs()
        return applyLimits(prevM: prefTargetMValue, prevT: prefTargetTValue, nextM: nextM, nextT: nextT)
    }

    /// S16-03：首次用 LimitMath.normalizeStored 初始化 prefTarget（避免 0 被当旧值）。
    private func ensureTargetsFromPrefs() {
        ctlLock.lock()
        if _targetsLoaded { ctlLock.unlock(); return }
        ctlLock.unlock()
        let s = settingsProvider()
        setPrefTargets(m: LimitMath.normalizeStored(s.limitJdb), t: LimitMath.normalizeStored(s.limitSht))
        ctlLock.lock(); _targetsLoaded = true; ctlLock.unlock()
    }

    private func applyLimitsBody(_ prevM: Int, _ prevT: Int, _ nextM: Int, _ nextT: Int, _ wasRunning: Bool) async {
        limitMutex.lock()
        defer { limitMutex.unlock() }
        await stopAndJoin()
        var failM: String?
        var failT: String?
        let countM = (try? idx.countOfExact(table: "idx_movies")) ?? 0
        let countT = (try? idx.countOfExact(table: "idx_threads")) ?? 0
        let d = LimitTransition.decide(
            prevM, prevT, nextM, nextT, countM, countT, wasRunning,
            !config.offlineJdb(), !config.offlineSht())
        Perf.mark("shadow.target", "decide \(d.reason)")
        if d.writeMeta {
            idx.metaPutLong("m_target", Int64(nextM))
            idx.metaPutLong("t_target", Int64(nextT))
        }
        if d.pruneM {
            switch idx.pruneMovies(limit: Int64(nextM)) {
            case .success(_, let bd, let bid):
                resetMovieCursorMeta(bd, bid)
            case .noop:
                break
            case .failed(let cause):
                failM = cause
                Perf.mark("idx.prune.fail", "src=movies target=\(nextM) cause=\(cause)")
            }
        }
        if d.pruneT {
            switch idx.pruneThreads(limit: Int64(nextT)) {
            case .success(_, _, let bid):
                idx.metaPut("t_tid", bid ?? "")
            case .noop:
                break
            case .failed(let cause):
                failT = cause
                Perf.mark("idx.prune.fail", "src=threads target=\(nextT) cause=\(cause)")
            }
        }
        idx.metaPutLong("m_done", (failM == nil && d.nextDoneM) ? 1 : 0)
        idx.metaPutLong("t_done", (failT == nil && d.nextDoneT) ? 1 : 0)
        let fails = [failM, failT].compactMap { $0 }
        if !fails.isEmpty {
            // 裁剪失败 → nextRunAt = now + 5min
            setNextRunAt(now() + Self.BACKOFF_5MIN)
            updateState {
                $0.lastError = String(("裁剪失败: " + fails.joined(separator: " | ")).prefix(120))
                $0.note = "裁剪失败，5 分钟后重试"
                $0.nextRunAt = self.nextRunAt
            }
        } else if d.action == .DEFER_OFFLINE {
            // DEFER_OFFLINE → nextRunAt = now + 5min
            setNextRunAt(now() + Self.BACKOFF_5MIN)
            updateState {
                $0.note = "源离线，联网后自动续跑"
                $0.nextRunAt = self.nextRunAt
            }
        }
        if d.restart && fails.isEmpty {
            _ = start(trigger: "limit", limitJdb: nextM, limitSht: nextT, force: true)
        }
        refreshStats()
    }

    /// applyLimits 裁剪后的 movies 游标重置（只写 meta，不动内存游标）。
    private func resetMovieCursorMeta(_ boundaryDate: String?, _ boundaryId: String?) {
        if let date = boundaryDate, !date.isEmpty {
            idx.metaPut("m_phase", "same")
            idx.metaPut("m_date", date)
            idx.metaPut("m_id", boundaryId ?? "")
        } else {
            idx.metaPut("m_phase", "null")
            idx.metaPut("m_date", "")
            idx.metaPut("m_id", "")
        }
    }

    // MARK: - refreshStats

    public func refreshStats() {
        let s = settingsProvider()
        let idxMode = s.idxMode
        var movies: Int64 = 0
        var threads: Int64 = 0
        if idxMode {
            movies = (try? idx.countOf(table: "idx_movies")) ?? 0
            threads = (try? idx.countOf(table: "idx_threads")) ?? 0
        } else if let shadow {
            if let m = try? shadow.count("movies_shadow") { movies = m }
            if let t = try? shadow.count("threads_shadow") { threads = t }
        }
        let actors = (try? idx.countActorsActive()) ?? 0
        let actorTotal = (try? idx.countActors()) ?? 0
        let idxBytes = idx.usageBytes(fast: true)
        let detailBytes = shadow?.usageBytes() ?? 0
        let tm = LimitMath.targetOf(s.limitJdb)
        let tt = LimitMath.targetOf(s.limitSht)
        let targetMovies: Int64 = tm == Self.UNLIM ? 0 : tm
        let targetThreads: Int64 = tt == Self.UNLIM ? 0 : tt
        let mode = idxMode ? "仅索引" : "完整影子"
        let running = isRunning()
        let paused = state.paused
        updateState { st in
            st.movies = movies
            st.threads = threads
            st.actors = actors
            st.actorTotal = actorTotal
            st.idxBytes = idxBytes
            st.detailBytes = detailBytes
            st.targetMovies = targetMovies
            st.targetThreads = targetThreads
            st.mode = mode
            st.nextRunAt = self.nextRunAt
            if running {
                if st.note.isEmpty { st.note = "预热中…" }
            } else if paused {
                st.note = "已暂停"
            } else if st.note.hasPrefix("已达目标") {
                // 不覆盖
            } else {
                st.note = "空闲"
            }
        }
    }

    // MARK: - runWarm 主运行体（三路并发）

    private func runWarm(_ runId: Int64, _ trigger: String, _ limitJdb: Int?, _ limitSht: Int?) async {
        let s = settingsProvider()
        let rawM = limitJdb ?? s.limitJdb          // 0 = 不限
        let rawT = limitSht ?? s.limitSht
        setPrefTargets(m: rawM, t: rawT)           // 本轮目标写入热更新状态
        ctlLock.lock(); _targetsLoaded = true; ctlLock.unlock()
        // Android: val targetM/T = LimitMath.targetOf(rawM/T)（三路内部各自换算，此处仅对位语义）
        let wantActors = s.actorIndex
        let wantLinks = s.actorLinks
        let wantTags = s.tagIndex

        let runStartMs = now()
        ctlLock.lock()
        _runRows = 0
        _runStartMs = runStartMs
        _lastPush = 0
        _lastVolMs = 0
        _runTargetHit = false
        _pruneFailMsg = ""
        _srcOfflineM = false
        _srcOfflineT = false
        _srcOfflineA = false
        _curPhaseM = ""
        _curPhaseT = ""
        _curPhaseA = ""
        ctlLock.unlock()
        updateState {
            $0.running = true
            $0.paused = false
            $0.phase = "head"
            $0.targetMovies = rawM <= 0 ? 0 : Int64(rawM)
            $0.targetThreads = rawT <= 0 ? 0 : Int64(rawT)
            $0.lastError = ""
            $0.lastRunAt = runStartMs
            $0.note = "预热中…"
        }
        Perf.mark("shadow.run", "start trigger=\(trigger) targetM=\(rawM) targetT=\(rawT) " +
            "targetA=\(wantActors ? "all" : "off") runId=\(runId)")

        let errors = PathErrors()
        await withTaskGroup(of: Void.self, returning: Void.self) { group in
            group.addTask {
                let e = await self.warmMovies(runId, wantLinks, wantTags)
                errors.set(0, e)
            }
            group.addTask {
                let e = await self.warmThreads(runId)
                errors.set(1, e)
            }
            if wantActors {
                group.addTask {
                    let e = await self.warmActors(runId)
                    errors.set(2, e)
                }
            }
            await group.waitForAll()
        }

        let errM = errors.get(0)
        let errT = errors.get(1)
        let errA = errors.get(2)
        let allOffline = srcOfflineMValue && srcOfflineTValue && (!wantActors || srcOfflineAValue)
        let pf = pruneFailMsgValue
        let reason: String
        if stopRequestedValue {
            reason = "stopped"
        } else if !pf.isEmpty || !errM.isEmpty || !errT.isEmpty || !errA.isEmpty {
            reason = "error"
        } else if allOffline {
            reason = "offline"
        } else if runTargetHitValue {
            reason = "target"
        } else {
            reason = "done"
        }
        await finishRun(runId, reason, errM, errT, errA)
    }

    // MARK: - finishRun（24h 增量 / 5min 退避 / 3 次停手 / moreWork 续跑）

    private func finishRun(_ runId: Int64, _ reason: String, _ errM: String, _ errT: String, _ errA: String) async {
        _ = runId
        var err = [errM, errT, errA].first { !$0.isEmpty } ?? ""
        if err.isEmpty { err = pruneFailMsgValue }   // 裁剪失败也进 error 文案（Android state 已写 lastError）

        let nowMs = now()
        if reason == "error" {
            ctlLock.lock(); _consecutiveFails += 1; let fails = _consecutiveFails; ctlLock.unlock()
            setNextRunAt(fails >= 3 ? Int64.max : nowMs + Self.BACKOFF_5MIN)
        } else if reason == "offline" {
            // 源离线不是失败；不写 done，5 分钟后允许再试
            ctlLock.lock(); _consecutiveFails = 0; ctlLock.unlock()
            setNextRunAt(nowMs + Self.BACKOFF_5MIN)
        } else {
            // 默认 24h; reason=target 时在下方按最新目标复查
            ctlLock.lock(); _consecutiveFails = 0; ctlLock.unlock()
            setNextRunAt(nowMs + 24 * 3600_000)
        }

        // 计数快照
        let cntM = (try? idx.countOf(table: "idx_movies")) ?? 0
        let cntT = (try? idx.countOf(table: "idx_threads")) ?? 0
        let actA = (try? idx.countActorsActive()) ?? 0
        let totA = (try? idx.countActors()) ?? 0
        let cntL = (try? idx.countOf(table: "idx_movie_actors")) ?? 0
        let bytes = idx.usageBytes(fast: true)

        // 孤儿自检（不影响业务判定）
        let o = idx.orphanReport()
        Perf.mark("idx.orphan", "tags=\(o.tagsOrphans) actors=\(o.actorOrphans) moviesNoRel=\(o.moviesNoRelation)")

        var autoRaise = false
        if reason == "target" {
            let limM = prefTargetMValue
            let limT = prefTargetTValue
            let doneM = idx.metaGetLong("m_done", 0) == 1
            let doneT = idx.metaGetLong("t_done", 0) == 1
            let rowsThisRun = runRowsValue
            let more = TargetPlanPolicy.moreWork(
                limM: limM, limT: limT, cntM: cntM, cntT: cntT,
                doneM: doneM, doneT: doneT,
                onlineM: !config.offlineJdb(), onlineT: !config.offlineSht(),
                rowsThisRun: rowsThisRun)
            if rowsThisRun <= 0 {
                // ★ S15-04 硬保险: 本轮 0 行 → 绝不 2s 重启
                setNextRunAt(now() + Self.BACKOFF_5MIN)
                Perf.mark("shadow.run", "target no-rows → backoff 5min")
            } else if more {
                // 改大/不限 → 2s 后自动续跑
                setNextRunAt(0)
                autoRaise = true
            } else {
                // target settle (no more work), 维持 24h
            }
        }

        let ms = now() - runStartMsValue
        let fails = consecutiveFails
        var endExtra = "end reason=\(reason) m=\(cntM) t=\(cntT) a=\(actA) links=\(cntL) ms=\(ms)"
        if !err.isEmpty { endExtra += " err=\(String(err.prefix(90)))" }
        Perf.mark("shadow.run", endExtra)

        let note: String
        switch reason {
        case "done": note = "空闲 (24h 后自动增量)"
        case "target": note = "已达目标上限"
        case "stopped": note = "已暂停 (断点已保存, 可继续索引)"
        case "offline": note = "源离线，5 分钟后重试"
        default:
            note = "出错: \(String(err.prefix(60)))" +
                (fails >= 3 ? " (连续失败, 等待手动继续)" : " (5 分钟后重试)")
        }
        let phase: String
        switch reason {
        case "done": phase = "done"
        case "error": phase = "error"
        case "offline": phase = "idle"
        default: phase = "paused"
        }
        updateState {
            $0.running = false
            $0.paused = (reason == "stopped")
            $0.phase = phase
            $0.movies = cntM
            $0.threads = cntT
            $0.actors = actA
            $0.actorTotal = totA
            $0.links = cntL
            $0.idxBytes = bytes
            $0.speedPerMin = 0
            $0.etaSec = 0
            $0.lastError = reason == "error" ? err : ""
            $0.nextRunAt = self.nextRunAt
            $0.note = note
        }

        if autoRaise && config.autoRaiseEnabled {
            let delay = config.autoRaiseDelayMs
            Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                }
                _ = self?.start(trigger: "auto-raise", force: true)
            }
        }
    }

    // MARK: - 进度 / 速度 / ETA

    /// 三路并发调用；单次原子 update。totalM/totalT = -1 表示该库本轮无新值（保持现值）。
    private func progress(rows: Int64, totalM: Int64, totalT: Int64) {
        ctlLock.lock()
        _runRows += rows
        ctlLock.unlock()

        let nowMs = now()
        var doVol = false
        ctlLock.lock()
        if nowMs - _lastVolMs > config.volThrottleMs {
            _lastVolMs = nowMs
            doVol = true
        }
        ctlLock.unlock()
        var idxB: Int64 = 0
        var detB: Int64 = 0
        if doVol {
            idxB = idx.usageBytes(fast: true)
            detB = shadow?.usageBytes() ?? 0
        }

        // 速度（行/分钟）
        let startMs = runStartMsValue
        let rowsTotal = runRowsValue
        let speed: Int = startMs > 0
            ? Int(rowsTotal * 60_000 / max(1, nowMs - startMs))
            : 0

        // 推送节流 1s
        ctlLock.lock()
        if nowMs - _lastPush < config.pushThrottleMs {
            ctlLock.unlock()
            return
        }
        _lastPush = nowMs
        ctlLock.unlock()

        let phases = curPhaseSnapshot
        var composed: [String] = []
        if !phases.m.isEmpty && phases.m != "done" { composed.append("m:\(phases.m)") }
        if !phases.t.isEmpty && phases.t != "done" { composed.append("t") }
        if !phases.a.isEmpty && phases.a != "done" { composed.append("a") }
        let phaseStr = composed.joined(separator: "+")

        updateState { snap in
            if totalM >= 0 { snap.movies = totalM }
            if totalT >= 0 { snap.threads = totalT }
            if doVol {
                snap.idxBytes = idxB
                snap.detailBytes = detB
            }
            snap.speedPerMin = speed
            if !phaseStr.isEmpty { snap.phase = phaseStr }
            snap.etaSec = speed > 10 && snap.targetMovies > 0
                ? max(0, snap.targetMovies - snap.movies) * 60 / Int64(speed)
                : 0
        }
    }

    /// Perf "shadow.batch" 格式逐字: "src=$src phase=$phase n=$n cursor=${cursor.take(40)} ms=$ms total=$total"
    private func batchMark(_ src: String, _ phase: String, _ n: Int, _ cursor: String, _ ms: Int64, _ total: Int64) {
        Perf.mark("shadow.batch",
            "src=\(src) phase=\(phase) n=\(n) cursor=\(String(cursor.prefix(40))) ms=\(now() - ms) total=\(total)")
    }

    // MARK: - warmMovies（head/same/tail/null/done 状态机）

    private func warmMovies(_ runId: Int64, _ wantLinks: Bool, _ wantTags: Bool) async -> String {
        let offline = config.offlineJdb()
        setSrcOfflineM(offline)
        if offline { return "" }
        do {
            var rawTarget = prefTargetMValue
            var target = LimitMath.targetOf(rawTarget)
            var cur = MovieCursor(
                phase: WarmCursor.phaseOf(idx.metaGet("m_phase")),
                date: idx.metaGet("m_date") ?? "",
                id: idx.metaGet("m_id") ?? "")
            idx.metaPutLong("m_target", Int64(rawTarget))
            let total0 = try idx.countOf(table: "idx_movies")

            // ---- HEAD 态（每轮都跑，S15-03）----
            let b0 = now()
            let headRows = try await source.moviesHead(batch: config.movieHeadBatch)
            if try headRows.isEmpty && idx.countOfExact(table: "idx_movies") == 0 {
                // 源为空/不可达且本地无数据 → done（防 finishRun 自旋）
                idx.metaPutLong("m_done", 1)
                setCurPhaseM("done")
                Perf.mark("shadow.run", "src=movies reason=empty")
                return ""
            }
            if !headRows.isEmpty {
                if currentRunIdValue != runId { return "" }
                idx.upsertMovies(headRows)
                if wantLinks { await linksFor(runId, headRows) }
                if wantTags { await tagsFor(runId, headRows) }
                if cur.date.isEmpty {
                    // 用 head 最后一行初始化游标
                    let last = headRows[headRows.count - 1]
                    cur = MovieCursor(phase: .same, date: last.s("release_date"), id: last.s("id"))
                }
                idx.metaPutLong("m_head_ts", now())
                idx.metaPut("m_phase", WarmCursor.phaseStr(cur.phase))
                idx.metaPut("m_date", cur.date)
                idx.metaPut("m_id", cur.id)
                setCurPhaseM("head")
                batchMark("movies", "head", headRows.count, "\(cur.date)|\(cur.id)", b0, total0)
                progress(rows: Int64(headRows.count), totalM: total0, totalT: -1)
            }

            var total = try idx.countOf(table: "idx_movies")

            // ---- 旧 done 清理（防卡死）----
            var doneFlag = idx.metaGetLong("m_done", 0)
            if doneFlag == 1 && (target == Self.UNLIM || total < target) {
                doneFlag = 0
                idx.metaPutLong("m_done", 0)
                if cur.phase == .done {
                    cur = MovieCursor(phase: .same, date: cur.date, id: cur.id)
                }
            }

            // ---- 达标/裁剪/续跑决策（轮首，S16-09）----
            let plan = TargetPlanPolicy.plan(target: rawTarget, total: total, done: doneFlag == 1, exhausted: false)
            if plan.shouldPrune && rawTarget > 0 {
                switch idx.pruneMovies(limit: Int64(rawTarget)) {
                case .success(_, let bd, let bid):
                    resetCursor(&cur, bd, bid)
                case .noop:
                    break
                case .failed(let cause):
                    return moviePruneFailed(cause, rawTarget)
                }
            }
            if !plan.continueScan {
                idx.metaPutLong("m_done", 1)
                setCurPhaseM("done")
                setRunTargetHit(true)
                Perf.mark("shadow.run", "src=movies reason=target count=\(total) target=\(rawTarget)")
                return ""
            }
            if cur.date.isEmpty {
                cur = MovieCursor(phase: .tail, date: Self.TAIL_SENTINEL_DATE, id: cur.id)
            }

            // ---- 主循环 ----
            var guardCount = 0
            while !stopRequestedValue && !Task.isCancelled && !config.offlineJdb()
                && guardCount < config.movieLoopGuard {
                guardCount += 1
                let b = now()

                // 每批开头读 prefTargetM 热更新（S14-P4）
                let curM = prefTargetMValue
                if curM != rawTarget {
                    Perf.mark("shadow.target", "source=loop m=\(rawTarget)->\(curM)")
                    rawTarget = curM
                    target = LimitMath.targetOf(curM)
                    updateState { $0.targetMovies = curM <= 0 ? 0 : Int64(curM) }
                }

                // NULL 相位两个子句 + else 兜底 TAIL 查询（Kotlin when 逐字语义）
                let rows: [Row]
                switch cur.phase {
                case .same:
                    if cur.date.isEmpty || cur.date == WarmCursor.NULL_DATE {
                        rows = []
                    } else {
                        rows = try await source.moviesSame(date: cur.date, beforeId: cur.id, batch: config.movieBatch)
                    }
                case .null:
                    if cur.id.isEmpty {
                        rows = try await source.moviesNullFirst(batch: config.movieBatch)
                    } else {
                        rows = try await source.moviesNullTail(beforeId: cur.id, batch: config.movieBatch)
                    }
                default:
                    rows = try await source.moviesTail(date: cur.date, batch: config.movieBatch)
                }

                if rows.isEmpty {
                    guard let next = WarmCursor.nextWhenEmpty(cur) else {
                        // NULL 态空批（源扫完 exhausted）
                        idx.metaPutLong("m_done", 1)
                        idx.metaPut("m_phase", "done")
                        setCurPhaseM("done")
                        Perf.mark("shadow.run", "src=movies reason=exhausted total=\(total)")
                        return ""
                    }
                    cur = next
                    idx.metaPut("m_phase", WarmCursor.phaseStr(cur.phase))
                    idx.metaPut("m_date", cur.date)
                    idx.metaPut("m_id", cur.id)
                    continue
                }

                // ---- 每批写入/持久化（有行分支，逐字顺序）----
                if currentRunIdValue != runId { return "" }
                idx.upsertMovies(rows)
                if wantLinks { await linksFor(runId, rows) }
                if wantTags { await tagsFor(runId, rows) }
                let last = rows[rows.count - 1]
                cur = WarmCursor.advance(cur, lastDate: last.s("release_date"), lastId: last.s("id"))
                total = try idx.countOf(table: "idx_movies")
                idx.metaPut("m_phase", WarmCursor.phaseStr(cur.phase))
                idx.metaPut("m_date", cur.date)
                idx.metaPut("m_id", cur.id)
                idx.metaPut("movies_n", String(total))
                idx.metaPut("movies_ts", String(now()))
                let phaseStr = WarmCursor.phaseStr(cur.phase)
                setCurPhaseM(phaseStr)
                batchMark("movies", phaseStr, rows.count, "\(cur.date)|\(cur.id)", b, total)
                progress(rows: Int64(rows.count), totalM: total, totalT: -1)

                // ---- 批后决策（S16-09，与轮首同构）----
                let loopPlan = TargetPlanPolicy.plan(target: rawTarget, total: total, done: false, exhausted: false)
                if loopPlan.shouldPrune && rawTarget > 0 {
                    switch idx.pruneMovies(limit: Int64(rawTarget)) {
                    case .success(_, let bd, let bid):
                        resetCursor(&cur, bd, bid)
                    case .noop:
                        break
                    case .failed(let cause):
                        return moviePruneFailed(cause, rawTarget)
                    }
                }
                if !loopPlan.continueScan {
                    idx.metaPutLong("m_done", 1)
                    setRunTargetHit(true)
                    Perf.mark("shadow.run", "src=movies reason=target total=\(total)")
                    return ""
                }
                // UNLIM 外部停止检查
                if target == Self.UNLIM && idx.metaGetLong("m_done", 0) == 1 {
                    Perf.mark("shadow.run", "src=movies reason=external-stop total=\(total)")
                    return ""
                }
                await delayMs(config.movieDelayMs)
            }
            return ""
        } catch is CancellationError {
            return ""
        } catch {
            return String(ErrText.of(error).prefix(120))
        }
    }

    /// prune Failed（轮首/批后共用）：m_done=0 + 5min 退避 + error 相位 → return。
    private func moviePruneFailed(_ cause: String, _ rawTarget: Int) -> String {
        let msg = "裁剪失败(movies): \(cause)"
        setPruneFailMsg(msg)
        idx.metaPutLong("m_done", 0)
        let t = now() + Self.BACKOFF_5MIN
        setNextRunAt(t)
        updateState {
            $0.lastError = String(msg.prefix(120))
            $0.nextRunAt = t
        }
        Perf.mark("idx.prune.fail", "src=movies target=\(rawTarget) cause=\(cause)")
        setCurPhaseM("error")
        return ""
    }

    /// warmMovies 内部版游标重置（S15-02）：任何 prune 之后把游标移到保留窗口下边界=最旧保留行。
    private func resetCursor(_ cur: inout MovieCursor, _ boundaryDate: String?, _ boundaryId: String?) {
        if let date = boundaryDate, !date.isEmpty {
            cur = MovieCursor(phase: .same, date: date, id: boundaryId ?? "")
            idx.metaPut("m_phase", "same")
            idx.metaPut("m_date", date)
            idx.metaPut("m_id", boundaryId ?? "")
        } else {
            cur = MovieCursor(phase: .null, date: "", id: "")
            idx.metaPut("m_phase", "null")
            idx.metaPut("m_date", "")
            idx.metaPut("m_id", "")
        }
    }

    // MARK: - links / tags（随 movies 批顺带，无 keyset；失败只记日志不阻塞）

    private func linksFor(_ runId: Int64, _ rows: [Row]) async {
        let ids = rows.map { $0.s("id") }.filter { !$0.isEmpty }
        if ids.isEmpty { return }
        do {
            let linkRows = try await source.links(movieIds: ids)
            if currentRunIdValue != runId { return }
            let pairs = linkRows.compactMap { r -> (movieId: String, actorId: String)? in
                let m = r.s("movie_id")
                let a = r.s("actor_id")
                if m.isEmpty || a.isEmpty { return nil }
                return (m, a)
            }
            idx.upsertLinks(pairs)
        } catch {
            Perf.mark("shadow.batch", "links error: \(String(ErrText.short(error).prefix(80)))")
        }
    }

    private func tagsFor(_ runId: Int64, _ rows: [Row]) async {
        let ids = rows.map { $0.s("id") }.filter { !$0.isEmpty }
        if ids.isEmpty { return }
        do {
            let tagRows = try await source.tags(movieIds: ids)
            if currentRunIdValue != runId { return }
            let pairs = tagRows.compactMap { r -> (movieId: String, tagId: String)? in
                let m = r.s("movie_id")
                let t = r.s("tag_id")
                if m.isEmpty || t.isEmpty { return nil }
                return (m, t)
            }
            idx.upsertTags(pairs)
            if !tagRows.isEmpty {
                let total = (try? idx.countOf(table: "idx_movie_tags")) ?? 0
                Perf.mark("shadow.batch", "src=tags n=\(tagRows.count) total=\(total)")
            }
        } catch {
            Perf.mark("shadow.batch", "tags error: \(String(ErrText.short(error).prefix(80)))")
        }
    }

    // MARK: - warmThreads（tid keyset，PK，每批 1000）

    private func warmThreads(_ runId: Int64) async -> String {
        let offline = config.offlineSht()
        setSrcOfflineT(offline)
        if offline { return "" }
        do {
            var rawTarget = prefTargetTValue
            var target = LimitMath.targetOf(rawTarget)
            var tId: Int64? = idx.metaGet("t_tid").flatMap { Int64($0) }
            idx.metaPutLong("t_target", Int64(rawTarget))
            let total0 = try idx.countOf(table: "idx_threads")

            // ---- head（每轮都跑，tid DESC = 最新帖）----
            let b0 = now()
            let headRows = try await source.threadsFirst(batch: config.threadBatch)
            if try headRows.isEmpty && idx.countOfExact(table: "idx_threads") == 0 {
                idx.metaPutLong("t_done", 1)
                setCurPhaseT("done")
                Perf.mark("shadow.run", "src=threads reason=empty")
                return ""
            }
            if !headRows.isEmpty {
                if currentRunIdValue != runId { return "" }
                idx.upsertThreads(headRows)
                if tId == nil {
                    tId = Int64(headRows[headRows.count - 1].s("tid"))
                }
                idx.metaPut("t_tid", tId.map { String($0) } ?? "")
                setCurPhaseT("head")
                batchMark("threads", "head", headRows.count, tId.map { String($0) } ?? "", b0, total0)
                progress(rows: Int64(headRows.count), totalM: -1, totalT: total0)
            }

            var total = try idx.countOf(table: "idx_threads")

            // ---- 旧 done 清理 ----
            var doneFlag = idx.metaGetLong("t_done", 0)
            if doneFlag == 1 && (target == Self.UNLIM || total < target) {
                doneFlag = 0
                idx.metaPutLong("t_done", 0)
            }

            // ---- 轮首决策 ----
            let plan = TargetPlanPolicy.plan(target: rawTarget, total: total, done: doneFlag == 1, exhausted: false)
            if plan.shouldPrune && rawTarget > 0 {
                switch idx.pruneThreads(limit: Int64(rawTarget)) {
                case .success(_, _, let bid):
                    tId = bid.flatMap { Int64($0) }
                    idx.metaPut("t_tid", bid ?? "")
                case .noop:
                    break
                case .failed(let cause):
                    return threadPruneFailed(cause, rawTarget)
                }
            }
            if !plan.continueScan {
                idx.metaPutLong("t_done", 1)
                setCurPhaseT("done")
                setRunTargetHit(true)
                Perf.mark("shadow.run", "src=threads reason=target count=\(total) target=\(rawTarget)")
                return ""
            }

            // ---- 主循环（threads 无 NULL 段）----
            var guardCount = 0
            while !stopRequestedValue && !Task.isCancelled && !config.offlineSht()
                && guardCount < config.threadLoopGuard {
                guardCount += 1
                let b = now()

                let curT = prefTargetTValue
                if curT != rawTarget {
                    Perf.mark("shadow.target", "source=loop t=\(rawTarget)->\(curT)")
                    rawTarget = curT
                    target = LimitMath.targetOf(curT)
                    updateState { $0.targetThreads = curT <= 0 ? 0 : Int64(curT) }
                }

                let rows: [Row]
                if let tid = tId {
                    rows = try await source.threads(beforeTid: tid, batch: config.threadBatch)
                } else {
                    rows = try await source.threadsFirst(batch: config.threadBatch)
                }

                if rows.isEmpty {
                    idx.metaPutLong("t_done", 1)
                    setCurPhaseT("done")
                    Perf.mark("shadow.run", "src=threads reason=exhausted total=\(total)")
                    return ""
                }
                if currentRunIdValue != runId { return "" }
                idx.upsertThreads(rows)
                tId = Int64(rows[rows.count - 1].s("tid"))
                total = try idx.countOf(table: "idx_threads")
                idx.metaPut("t_tid", tId.map { String($0) } ?? "")
                idx.metaPut("threads_n", String(total))
                idx.metaPut("threads_ts", String(now()))
                setCurPhaseT("tid")
                batchMark("threads", "tid", rows.count, tId.map { String($0) } ?? "", b, total)
                progress(rows: Int64(rows.count), totalM: -1, totalT: total)

                // 批后决策
                let loopPlan = TargetPlanPolicy.plan(target: rawTarget, total: total, done: false, exhausted: false)
                if loopPlan.shouldPrune && rawTarget > 0 {
                    switch idx.pruneThreads(limit: Int64(rawTarget)) {
                    case .success(_, _, let bid):
                        tId = bid.flatMap { Int64($0) }
                        idx.metaPut("t_tid", bid ?? "")
                    case .noop:
                        break
                    case .failed(let cause):
                        return threadPruneFailed(cause, rawTarget)
                    }
                }
                if !loopPlan.continueScan {
                    idx.metaPutLong("t_done", 1)
                    setRunTargetHit(true)
                    Perf.mark("shadow.run", "src=threads reason=target total=\(total)")
                    return ""
                }
                if target == Self.UNLIM && idx.metaGetLong("t_done", 0) == 1 {
                    Perf.mark("shadow.run", "src=threads reason=external-stop total=\(total)")
                    return ""
                }
                await delayMs(config.threadDelayMs)
            }
            return ""
        } catch is CancellationError {
            return ""
        } catch {
            return String(ErrText.of(error).prefix(120))
        }
    }

    private func threadPruneFailed(_ cause: String, _ rawTarget: Int) -> String {
        let msg = "裁剪失败(threads): \(cause)"
        setPruneFailMsg(msg)
        idx.metaPutLong("t_done", 0)
        let t = now() + Self.BACKOFF_5MIN
        setNextRunAt(t)
        updateState {
            $0.lastError = String(msg.prefix(120))
            $0.nextRunAt = t
        }
        Perf.mark("idx.prune.fail", "src=threads target=\(rawTarget) cause=\(cause)")
        setCurPhaseT("error")
        return ""
    }

    // MARK: - warmActors（id keyset，每批 500，避免 videos_count filesort；无目标/裁剪逻辑）

    private func warmActors(_ runId: Int64) async -> String {
        let offline = config.offlineJdb()
        setSrcOfflineA(offline)
        if offline { return "" }
        do {
            var aId = idx.metaGet("a_id") ?? ""

            // ---- head（每轮都跑，id DESC = 最新女优；a_done 不阻止 head）----
            let headRows = try await source.actors(beforeId: "", batch: config.actorBatch)
            if !headRows.isEmpty {
                if currentRunIdValue != runId { return "" }
                idx.upsertActors(headRows)
                if aId.isEmpty {
                    aId = headRows[headRows.count - 1].s("id")
                }
                idx.metaPut("a_id", aId)
                setCurPhaseA("head")
                progress(rows: Int64(headRows.count), totalM: -1, totalT: -1)
            }

            // ---- 主循环 ----
            var guardCount = 0
            while !stopRequestedValue && !Task.isCancelled && !config.offlineJdb()
                && guardCount < config.actorLoopGuard {
                guardCount += 1
                let b = now()
                let rows: [Row]
                if aId.isEmpty {
                    rows = try await source.actors(beforeId: "", batch: config.actorBatch)
                } else {
                    rows = try await source.actors(beforeId: aId, batch: config.actorBatch)
                }
                if rows.isEmpty {
                    idx.metaPutLong("a_done", 1)
                    setCurPhaseA("done")
                    let total = (try? idx.countActors()) ?? 0
                    Perf.mark("shadow.run", "src=actors reason=exhausted total=\(total)")
                    return ""
                }
                if currentRunIdValue != runId { return "" }
                idx.upsertActors(rows)
                aId = rows[rows.count - 1].s("id")
                let total = try idx.countActors()
                idx.metaPut("a_id", aId)
                setCurPhaseA("id")
                batchMark("actors", "id", rows.count, aId, b, total)
                progress(rows: Int64(rows.count), totalM: -1, totalT: -1)
                await delayMs(config.actorDelayMs)
            }
            return ""
        } catch is CancellationError {
            return ""
        } catch {
            return String(ErrText.of(error).prefix(120))
        }
    }
}

// MARK: - 三路错误收集（线程安全小盒）

private final class PathErrors: @unchecked Sendable {
    private let lk = NSLock()
    private var vals = ["", "", ""]

    func set(_ idx: Int, _ v: String) {
        lk.lock()
        if vals[idx].isEmpty { vals[idx] = v }
        lk.unlock()
    }

    func get(_ idx: Int) -> String {
        lk.lock(); defer { lk.unlock() }
        return vals[idx]
    }
}
