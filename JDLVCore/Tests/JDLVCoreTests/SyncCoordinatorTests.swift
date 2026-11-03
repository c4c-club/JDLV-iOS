//
//  SyncCoordinatorTests.swift
//  JDLVCoreTests
//
//  P10 离线预热引擎 SyncCoordinator 单测。
//  对齐 Android: app/src/main/java/com/jdlv/mobile/core/sync/SyncCoordinator.kt（1053 行）
//  （提取对照: docs/_extract/05_sync.md §1, 状态机/游标键/数值逐字）。
//
//  形态: 内存假源（FakeWarmSource，模拟 head/same/tail/null/threads/actors keyset 语义）
//  + 临时目录 SQLite IdxDb。断点续传/重建/清理用新 SyncCoordinator 实例共用同一 IdxDb。
//  批间时延默认置 0（makeCo；显式非默认值保留）；速度/ETA 用注入时钟（TestClock）确定性验证；
//  暂停点用"门 + 后台 stopAndJoin"确定性钉住（批边界精确）；离线经 OfflineGate.mark（setUp 复位）。
//

import XCTest
@testable import JDLVCore

// MARK: - 假数据类型

/// 两个假源共用的测试门（open 前阻塞）。
/// parkedCount：当前停在门内的调用数 —— stopAtGate 用它等"批真正停进门"后再置 stop，
/// 否则 stopRequested 可能先于下一批启动 → 停点漂移到 head 末（停点不确定）。
private final class TestGate: @unchecked Sendable {
    private let lk = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var parked = 0

    var parkedCount: Int { lk.lock(); defer { lk.unlock() }; return parked }

    func wait() async {
        lk.lock()
        if opened { lk.unlock(); return }
        lk.unlock()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lk.lock()
            if opened { lk.unlock(); c.resume(); return }
            parked += 1
            waiters.append(c)
            lk.unlock()
        }
        lk.lock(); parked -= 1; lk.unlock()
    }

    func open() {
        lk.lock(); opened = true
        let ws = waiters; waiters = []
        lk.unlock()
        ws.forEach { $0.resume() }
    }
}

private struct FMovie { var id: String; var date: String }
private struct FThread { var tid: Int64; var title: String }
private struct FActor { var id: String; var name: String }

/// 内存假源：数组切片模拟 keyset 分页（date DESC/id DESC、tid DESC、id DESC）。
/// 支持: 调用计数 / 按方法阻塞门（Gate）/ 按方法注错 / 钩子（最小调用次数、可 once）。
private final class FakeWarmSource: WarmSource, @unchecked Sendable {

    struct Hook { var minCall: Int = 1; var once = false; var fn: () -> Void }

    var movies: [FMovie] = []      // 已按 date DESC（"" 排最后）、id DESC 排序
    var threads: [FThread] = []    // tid DESC
    var actors: [FActor] = []      // id DESC
    var linksBy: [String: [String]] = [:]
    var tagsBy: [String: [String]] = [:]
    var errors: [String: Error] = [:]
    var gates: [String: TestGate] = [:]
    var hooks: [String: Hook] = [:]

    private let lk = NSLock()
    private var counts: [String: Int] = [:]
    private var firedHooks: Set<String> = []

    func callCount(_ m: String) -> Int { lk.lock(); defer { lk.unlock() }; return counts[m] ?? 0 }

    private func begin(_ m: String) async throws {
        lk.lock()
        counts[m, default: 0] += 1
        let n = counts[m]!
        lk.unlock()
        if let g = gates[m] { await g.wait() }
        if let e = errors[m] { throw e }
        if let h = hooks[m], n >= h.minCall, !(h.once && firedHooks.contains(m)) {
            if h.once { lk.lock(); firedHooks.insert(m); lk.unlock() }
            h.fn()
        }
    }

    // MARK: 数据装载

    static func sortMovies(_ list: [FMovie]) -> [FMovie] {
        list.sorted { a, b in
            if a.date.isEmpty != b.date.isEmpty { return b.date.isEmpty }   // "" 排最后
            if a.date != b.date { return a.date > b.date }
            return a.id > b.id
        }
    }

    func setMovies(_ dates: [(String, Int)], startId: Int = 1) {
        var out: [FMovie] = []
        var id = startId
        for (d, n) in dates {
            for _ in 0..<n {
                out.append(FMovie(id: SyncCoordinatorTests.pad6(id), date: d))
                id += 1
            }
        }
        movies = Self.sortMovies(out)
    }

    func setThreads(_ n: Int, startTid: Int = 1000) {
        var out: [FThread] = []
        for i in 0..<n { out.append(FThread(tid: Int64(startTid - i), title: "TH\(startTid - i)")) }
        threads = out   // 已 tid DESC
    }

    func setActors(_ n: Int) {
        var out: [FActor] = []
        for i in stride(from: n, through: 1, by: -1) {
            out.append(FActor(id: String(format: "a%05d", i), name: "A\(i)"))
        }
        actors = out    // 已 id DESC
    }

    // MARK: 行物化

    private static func movieRows(_ list: ArraySlice<FMovie>) -> [Row] {
        list.map { m in
            Row([
                "id": .string(m.id),
                "number": .string("NM-\(m.id)"),
                "title": .string("T-\(m.id)"),
                "release_date": .string(m.date),
                "year": .string("2024"),
                "score": .double(7.5),
                "want_watch_count": .int(10),
                "magnets_count": .int(2),
                "number_letter": .string("N"),
            ])
        }
    }

    private static func threadRow(_ t: FThread) -> Row {
        Row([
            "tid": .string(String(t.tid)),
            "title": .string(t.title),
            "post_date": .string("2024-01-01"),
            "board": .string("b"),
            "board_name": .string("bn"),
            "type": .string("1"),
            "magnet_count": .int(1),
            "article_words": .int(100),
            "paywalled": .int(0),
        ])
    }

    // MARK: WarmSource

    func moviesHead(batch: Int) async throws -> [Row] {
        if let g = gates["moviesHead"] { await g.wait() }
        try await begin("moviesHead")
        return Self.movieRows(movies.prefix(batch))
    }

    func moviesSame(date: String, beforeId: String, batch: Int) async throws -> [Row] {
        if let g = gates["moviesSame"] { await g.wait() }
        try await begin("moviesSame")
        return Self.movieRows(movies.filter { $0.date == date && $0.id < beforeId }.prefix(batch))
    }

    func moviesTail(date: String, batch: Int) async throws -> [Row] {
        if let g = gates["moviesTail"] { await g.wait() }
        try await begin("moviesTail")
        return Self.movieRows(movies.filter { $0.date < date }.prefix(batch))
    }

    func moviesNullFirst(batch: Int) async throws -> [Row] {
        if let g = gates["moviesNullFirst"] { await g.wait() }
        try await begin("moviesNullFirst")
        return Self.movieRows(movies.filter { $0.date.isEmpty }.prefix(batch))
    }

    func moviesNullTail(beforeId: String, batch: Int) async throws -> [Row] {
        if let g = gates["moviesNullTail"] { await g.wait() }
        try await begin("moviesNullTail")
        return Self.movieRows(movies.filter { $0.date.isEmpty && $0.id < beforeId }.prefix(batch))
    }

    func threadsFirst(batch: Int) async throws -> [Row] {
        if let g = gates["threadsFirst"] { await g.wait() }
        try await begin("threadsFirst")
        return threads.prefix(batch).map { Self.threadRow($0) }
    }

    func threads(beforeTid: Int64, batch: Int) async throws -> [Row] {
        if let g = gates["threads"] { await g.wait() }
        try await begin("threadsKeyset")
        return threads.filter { $0.tid < beforeTid }.prefix(batch).map { Self.threadRow($0) }
    }

    func actors(beforeId: String, batch: Int) async throws -> [Row] {
        if let g = gates["actors"] { await g.wait() }
        try await begin(beforeId.isEmpty ? "actorsHead" : "actorsKeyset")
        let slice = beforeId.isEmpty ? actors.prefix(batch) : actors.filter { $0.id < beforeId }.prefix(batch)
        return slice.map { Row(["id": .string($0.id), "name": .string($0.name), "videos_count": .int(1)]) }
    }

    func links(movieIds: [String]) async throws -> [Row] {
        if let g = gates["links"] { await g.wait() }
        try await begin("links")
        var out: [Row] = []
        for id in movieIds {
            for a in linksBy[id] ?? [] {
                out.append(Row(["movie_id": .string(id), "actor_id": .string(a)]))
            }
        }
        return out
    }

    func tags(movieIds: [String]) async throws -> [Row] {
        if let g = gates["tags"] { await g.wait() }
        try await begin("tags")
        var out: [Row] = []
        for id in movieIds {
            for t in tagsBy[id] ?? [] {
                out.append(Row(["movie_id": .string(id), "tag_id": .string(t)]))
            }
        }
        return out
    }
}


/// 10 万行生成式假源（不物化数组）：日期 D001..D100（升序字符串），每日期 perDate 行，
/// 全序 = i 升序 ↔ (date DESC, id DESC)；id = M%06d(总行数 - i)。
private final class BigFakeSource: WarmSource, @unchecked Sendable {
    let totalMovies: Int
    let totalDates: Int
    let totalThreads: Int64
    var perDate: Int { totalMovies / totalDates }


    // 测试门：phase 名 → 门（open 前阻塞）
    final class Gate: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        private let lk = NSLock()
        private var opened = false
        func wait() async {
            lk.lock()
            let o = opened
            lk.unlock()
            if o { return }
            await Task.yield()
            _ = sem.wait(timeout: .now() + 5)
        }
        func open() {
            lk.lock(); opened = true; lk.unlock()
            sem.signal()
        }
    }

    var gates: [String: TestGate] = [:]

    init(totalMovies: Int = 100_000, totalDates: Int = 100, totalThreads: Int64 = 1_000) {
        self.totalMovies = totalMovies
        self.totalDates = totalDates
        self.totalThreads = totalThreads
    }

    private func dateStr(_ dn: Int) -> String { String(format: "D%03d", dn) }
    private func idStr(_ n: Int) -> String { String(format: "M%06d", n) }

    private func movieRow(_ i: Int) -> Row {
        let dn = totalDates - i / perDate
        let idn = totalMovies - i
        return Row([
            "id": .string(idStr(idn)),
            "number": .string("N\(idn)"),
            "title": .string("T\(idn)"),
            "release_date": .string(dateStr(dn)),
            "year": .string("2024"),
        ])
    }

    private func movieRows(_ range: Range<Int>) -> [Row] {
        range.map { movieRow($0) }
    }

    private func threadRow(_ tid: Int64) -> Row {
        Row([
            "tid": .string(String(tid)),
            "title": .string("TH\(tid)"),
            "post_date": .string("2024-01-01"),
            "board": .string("b"),
            "board_name": .string("bn"),
            "type": .string("1"),
            "magnet_count": .int(1),
            "article_words": .int(100),
            "paywalled": .int(0),
        ])
    }

    func moviesHead(batch: Int) async throws -> [Row] {
        if let g = gates["moviesHead"] { await g.wait() }
        return movieRows(0..<min(batch, totalMovies))
    }

    func moviesSame(date: String, beforeId: String, batch: Int) async throws -> [Row] {
        if let g = gates["moviesSame"] { await g.wait() }
        guard let dn = Int(date.dropFirst()), let idn = Int(beforeId.dropFirst()) else { return [] }
        let segStart = (totalDates - dn) * perDate
        let segEnd = min(segStart + perDate, totalMovies)
        let start = max(segStart, totalMovies - idn + 1)
        guard start < segEnd else { return [] }
        return movieRows(start..<min(start + batch, segEnd))
    }

    func moviesTail(date: String, batch: Int) async throws -> [Row] {
        if let g = gates["moviesTail"] { await g.wait() }
        guard let dn = Int(date.dropFirst()) else { return [] }
        let start = (totalDates - dn + 1) * perDate
        guard start < totalMovies else { return [] }
        return movieRows(start..<min(start + batch, totalMovies))
    }

    func moviesNullFirst(batch: Int) async throws -> [Row] {
        if let g = gates["moviesNullFirst"] { await g.wait() }
        return []
    }

    func moviesNullTail(beforeId: String, batch: Int) async throws -> [Row] {
        if let g = gates["moviesNullTail"] { await g.wait() }
        return []
    }

    func threadsFirst(batch: Int) async throws -> [Row] {
        if let g = gates["threadsFirst"] { await g.wait() }
        let hi = totalThreads
        let lo = max(1, hi - Int64(batch) + 1)
        return (lo...hi).reversed().map { threadRow($0) }
    }

    func threads(beforeTid: Int64, batch: Int) async throws -> [Row] {
        if let g = gates["threads"] { await g.wait() }
        let hi = beforeTid - 1
        guard hi >= 1 else { return [] }
        let lo = max(1, hi - Int64(batch) + 1)
        return (lo...hi).reversed().map { threadRow($0) }
    }

    func actors(beforeId: String, batch: Int) async throws -> [Row] {
        if let g = gates["actors"] { await g.wait() }
        return []
    }
    func links(movieIds: [String]) async throws -> [Row] { [] }
    func tags(movieIds: [String]) async throws -> [Row] { [] }
}

// MARK: - 测试

final class SyncCoordinatorTests: XCTestCase {

    private struct TestError: Error { let msg: String }

    /// 注入时钟
    private final class TestClock: @unchecked Sendable {
        var now: Int64
        init(_ now: Int64 = 1_000_000) { self.now = now }
        func tick(_ delta: Int64) { now += delta }
    }

    private final class SettingsBox {
        var value: WarmSettings
        init(_ v: WarmSettings) { value = v }
    }

    // MARK: 工具

    static func pad6(_ n: Int) -> String { String(format: "m%06d", n) }

    private func tmpDir(_ tag: String) -> String {
        let dir = NSTemporaryDirectory() + "jdlv-sync-" + tag + "-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mkIdx(_ tag: String) -> IdxDb {
        try! IdxDb(directory: tmpDir(tag))
    }

    /// 时延默认归零（显式设置过非默认值的保留，供确定性时序测试用）；shadow 可注入（clearAll 清影子库用）
    private func makeCo(
        idx: IdxDb, source: WarmSource, settings: WarmSettings = WarmSettings(),
        config: SyncConfig = SyncConfig(), clock: TestClock? = nil, shadow: ShadowDb? = nil
    ) -> SyncCoordinator {
        makeCo(idx: idx, source: source, box: SettingsBox(settings), config: config, clock: clock, shadow: shadow)
    }

    private func makeCo(
        idx: IdxDb, source: WarmSource, box: SettingsBox,
        config: SyncConfig = SyncConfig(), clock: TestClock? = nil, shadow: ShadowDb? = nil
    ) -> SyncCoordinator {
        var cfg = config
        if cfg.movieDelayMs == 150 { cfg.movieDelayMs = 0 }
        if cfg.threadDelayMs == 150 { cfg.threadDelayMs = 0 }
        if cfg.actorDelayMs == 200 { cfg.actorDelayMs = 0 }
        if let clock { cfg.clock = { clock.now } }
        return SyncCoordinator(idx: idx, source: source, settings: { box.value }, shadow: shadow, config: cfg)
    }

    @discardableResult
    private func waitUntil(_ timeoutMs: Int64 = 10_000, _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Perf.nowMs() + timeoutMs
        while Perf.nowMs() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return cond()
    }

    @discardableResult
    private func waitFinish(_ co: SyncCoordinator, timeoutMs: Int64 = 30_000) async -> Bool {
        await waitUntil(timeoutMs) { !co.isRunning() }
    }

    /// 确定性暂停：先等批真正停在校准门内，再发起 stopAndJoin（stopRequested 先置位），后放行
    /// → 精确停在批边界（当前批完成落库 + 游标持久化，下一批不启动，对齐 05_sync.md §1.6 循环条件退出）。
    /// 不等停靠直接 stop 会有竞态：stopRequested 先于下一批启动 → 循环在 head 后即退出（停点漂移）。
    private func stopAtGate(_ co: SyncCoordinator, _ gate: TestGate) async {
        await waitUntil { gate.parkedCount >= 1 }
        let stopTask = Task { await co.stopAndJoin() }
        try? await Task.sleep(nanoseconds: 30_000_000)   // 确保 stopRequested 已置位
        gate.open()
        await stopTask.value
    }

    /// 直接向 IdxDb 播种 n 行影片（日期 d%04d 与 id 同序递增 → 淘汰序 = id 升序）
    private func seedIdxMovies(_ idx: IdxDb, _ n: Int) {
        var rows: [Row] = []
        for i in 1...n {
            rows.append(Row([
                "id": .string(Self.pad6(i)),
                "release_date": .string(String(format: "d%04d", i)),
                "title": .string("T\(i)"),
            ]))
        }
        idx.upsertMovies(rows)
    }

    private func seedIdxThreads(_ idx: IdxDb, _ n: Int) {
        var rows: [Row] = []
        for i in 1...n {
            rows.append(Row(["tid": .string(String(i)), "title": .string("T\(i)")]))
        }
        idx.upsertThreads(rows)
    }

    private func exactCount(_ idx: IdxDb, _ table: String) -> Int64 {
        (try? idx.countOfExact(table: table)) ?? -1
    }

    override func setUp() {
        super.setUp()
        OfflineGate.reset()
    }

    private let defaultGateInput = WarmGateInput(
        foreground: true, idleMs: 10_000, enabled: true, running: false, wifi: true,
        onlineM: true, onlineT: true, doneM: false, doneT: false, doneA: true,
        actorsEnabled: true, now: 1_000_000, nextRunAt: 2_000_000)

    // MARK: - A. 状态机全循环与游标持久化

    /// 全相位循环（head→same→tail→null→done + threads/actors exhaust）与游标落库
    func test_fullRunAllPhasesAndDone() async {
        let idx = mkIdx("full")
        let src = FakeWarmSource()
        src.setMovies([("2024-03-01", 3), ("2024-02-01", 2), ("", 2)])
        src.setThreads(120)
        src.setActors(60)
        let co = makeCo(idx: idx, source: src)
        XCTAssertEqual(co.start(trigger: "test", force: true), .STARTED)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 7)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 120)
        XCTAssertEqual(try? idx.countActors(), 60)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("a_done", 0), 1)
        XCTAssertEqual(idx.metaGet("m_phase"), "done")
        XCTAssertEqual(idx.metaGet("m_date"), WarmCursor.NULL_DATE)
        XCTAssertEqual(co.state.note, "空闲 (24h 后自动增量)")
        XCTAssertEqual(co.state.phase, "done")
        XCTAssertFalse(co.state.paused)
        XCTAssertGreaterThan(co.nextRunAt, Perf.nowMs() + 24 * 3600_000 - 60_000)
        XCTAssertEqual(co.consecutiveFails, 0)
        idx.close()
    }

    /// 游标键逐字：11 个游标键 + 4 个统计键全部写入；stopAndJoin 状态对位
    func test_cursorKeysAllWrittenVerbatim() async {
        let idx = mkIdx("keys")
        let src = FakeWarmSource()
        src.setMovies([("x1", 30)])
        src.setThreads(30)
        src.setActors(15)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 10
        cfg.movieBatch = 10
        cfg.threadBatch = 10
        cfg.actorBatch = 5
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        // 三路并发，a_done 先落不代表 movies/threads 已扫完（m_done/t_done 只在各自 exhausted 写，
        // 05_sync.md §1.11/§1.13）→ 等三个 done 全部落库再 stop，保证 15 个键全部存在（否则竞态漏键）
        await waitUntil {
            idx.metaGetLong("m_done", 0) == 1
                && idx.metaGetLong("t_done", 0) == 1
                && idx.metaGetLong("a_done", 0) == 1
        }
        _ = await co.stopAndJoin()

        XCTAssertNotNil(idx.metaGet("m_phase"))
        XCTAssertNotNil(idx.metaGet("m_date"))
        XCTAssertNotNil(idx.metaGet("m_id"))
        XCTAssertNotNil(idx.metaGet("m_done"))
        XCTAssertNotNil(idx.metaGet("m_target"))
        XCTAssertNotNil(idx.metaGet("m_head_ts"))
        XCTAssertNotNil(idx.metaGet("t_tid"))
        XCTAssertNotNil(idx.metaGet("t_done"))
        XCTAssertNotNil(idx.metaGet("t_target"))
        XCTAssertNotNil(idx.metaGet("a_id"))
        XCTAssertNotNil(idx.metaGet("a_done"))
        XCTAssertNotNil(idx.metaGet("movies_n"))
        XCTAssertNotNil(idx.metaGet("movies_ts"))
        XCTAssertNotNil(idx.metaGet("threads_n"))
        XCTAssertNotNil(idx.metaGet("threads_ts"))
        XCTAssertEqual(co.state.note, "已暂停 (断点已保存, 可继续索引)")
        XCTAssertTrue(co.state.paused)
        XCTAssertFalse(co.state.running)
        idx.close()
    }

    /// head 批末行初始化游标：m_phase=same、m_date/m_id = head 最后一行
    func test_headInitializesCursorFromLastRow() async {
        let idx = mkIdx("headinit")
        let src = FakeWarmSource()
        src.setMovies([("2024-02-01", 2), ("2024-01-01", 2)])
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 3
        cfg.movieBatch = 2
        var snap: (String, String, String)?
        src.hooks["moviesSame"] = .init(minCall: 1, once: true) {
            snap = (idx.metaGet("m_phase") ?? "", idx.metaGet("m_date") ?? "", idx.metaGet("m_id") ?? "")
        }
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snap?.0, "same")
        XCTAssertEqual(snap?.1, "2024-01-01")
        XCTAssertEqual(snap?.2, Self.pad6(4))   // head 3 行 = [id2, id1, id4]，末行 id4
        XCTAssertEqual(exactCount(idx, "idx_movies"), 4)
        idx.close()
    }

    /// SAME 空批 → TAIL（同日期同 id）并持久化
    func test_sameEmptyBatchTransitionsToTail() async {
        let idx = mkIdx("same2tail")
        let src = FakeWarmSource()
        src.setMovies([("x1", 2)])
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 2
        var snap: (String, String, String)?
        src.hooks["moviesTail"] = .init(minCall: 1, once: true) {
            snap = (idx.metaGet("m_phase") ?? "", idx.metaGet("m_date") ?? "", idx.metaGet("m_id") ?? "")
        }
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snap?.0, "tail")
        XCTAssertEqual(snap?.1, "x1")
        XCTAssertEqual(snap?.2, Self.pad6(1))
        idx.close()
    }

    /// TAIL 空批 → NULL（哨兵 "__NULL__"）并持久化；NULL 段继续消耗
    func test_tailEmptyBatchTransitionsToNullSentinel() async {
        let idx = mkIdx("tail2null")
        let src = FakeWarmSource()
        src.setMovies([("x1", 1), ("", 2)])
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 10
        var snapPhase: String?
        src.hooks["moviesNullFirst"] = .init(minCall: 1, once: true) { snapPhase = idx.metaGet("m_phase") }
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snapPhase, "null")
        XCTAssertEqual(idx.metaGet("m_date"), WarmCursor.NULL_DATE)
        XCTAssertEqual(idx.metaGet("m_phase"), "done")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 3)
        idx.close()
    }

    /// NULL 段消耗后 exhausted → m_done=1（混合日期数据集全扫完）
    func test_nullExhaustionMarksDone() async {
        let idx = mkIdx("nullexh")
        let src = FakeWarmSource()
        src.setMovies([("x2", 2), ("x1", 2), ("", 3)])
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 2
        cfg.movieBatch = 2
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 7)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(idx.metaGet("m_phase"), "done")
        XCTAssertEqual(idx.metaGet("m_date"), WarmCursor.NULL_DATE)
        idx.close()
    }

    /// SAME 只推进 id（date 不变）；批后 m_id = 批末行
    func test_sameOnlyAdvancesId() async {
        let idx = mkIdx("sameadv")
        let src = FakeWarmSource()
        src.setMovies([("x1", 4)])
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 2
        cfg.movieBatch = 2
        var snap: (String, String, String)?
        src.hooks["moviesSame"] = .init(minCall: 2, once: true) {
            snap = (idx.metaGet("m_phase") ?? "", idx.metaGet("m_date") ?? "", idx.metaGet("m_id") ?? "")
        }
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snap?.0, "same")
        XCTAssertEqual(snap?.1, "x1")           // date 不变
        XCTAssertEqual(snap?.2, Self.pad6(1))   // 批 2 末行（ids 4,3 → 2,1）
        idx.close()
    }

    /// m_head_ts / movies_ts / threads_ts / movies_n / threads_n 均落库
    /// （05_sync.md §1.15：movies_n/movies_ts/threads_n/threads_ts 由"每批"=主循环批写入，
    ///   head 批只写 m_head_ts/t_tid —— 故 head 批置 1，让 same/keyset 批真正落统计键）
    func test_headTsAndTsKeysPersisted() async {
        let idx = mkIdx("ts")
        let src = FakeWarmSource()
        src.setMovies([("x1", 2)])
        src.setThreads(2)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 1
        cfg.threadBatch = 1
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertGreaterThan(idx.metaGetLong("m_head_ts", 0), 0)
        XCTAssertGreaterThan(idx.metaGetLong("movies_ts", 0), 0)
        XCTAssertGreaterThan(idx.metaGetLong("threads_ts", 0), 0)
        XCTAssertEqual(idx.metaGetLong("movies_n", -1), 2)
        XCTAssertEqual(idx.metaGetLong("threads_n", -1), 2)
        idx.close()
    }

    /// 落盘 0=不限：不限目标 m_target/t_target == 0（不落 MAX 哨兵）
    func test_targetsPersistedRawZeroForUnlimited() async {
        let idx = mkIdx("tgt0")
        let src = FakeWarmSource()
        src.setMovies([("x1", 1)])
        let co = makeCo(idx: idx, source: src)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(idx.metaGetLong("m_target", -1), 0)
        XCTAssertEqual(idx.metaGetLong("t_target", -1), 0)
        idx.close()
    }

    /// 显式上限落盘 raw 值 + 状态 targetMovies/targetThreads 对位 + 达标 done
    func test_targetPersistedExplicitLimit() async {
        let idx = mkIdx("tgtN")
        let src = FakeWarmSource()
        src.setMovies([("x1", 50)])
        src.setThreads(20)
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(limitJdb: 30, limitSht: 15))
        _ = co.start(trigger: "test", limitJdb: 30, limitSht: 15, force: true)
        await waitFinish(co)

        XCTAssertEqual(idx.metaGetLong("m_target", -1), 30)
        XCTAssertEqual(idx.metaGetLong("t_target", -1), 15)
        XCTAssertEqual(co.state.targetMovies, 30)
        XCTAssertEqual(co.state.targetThreads, 15)
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 1)
        XCTAssertEqual(idx.metaGetLong("t_done", -1), 1)
        idx.close()
    }

    /// 空源 + 本地空 → 三路直接 done（reason=empty 分支），finish 为 done
    func test_emptySourceMarksAllDoneImmediately() async {
        let idx = mkIdx("empty")
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("a_done", 0), 1)
        // 05_sync.md §1.11 head 空 + 本地空分支逐字：只写 m_done=1（curPhaseM 仅内存），不写 m_phase
        XCTAssertNil(idx.metaGet("m_phase"))
        XCTAssertEqual(co.state.note, "空闲 (24h 后自动增量)")
        XCTAssertEqual(src.callCount("moviesHead"), 1)   // head 只探一次，无下钻
        XCTAssertEqual(src.callCount("moviesSame"), 0)
        idx.close()
    }

    /// threads tid keyset 推进与 t_tid/threads_n 持久化
    func test_threadsCursorKeysetPersists() async {
        let idx = mkIdx("tcur")
        let src = FakeWarmSource()
        src.setThreads(250, startTid: 250)
        var cfg = SyncConfig()
        cfg.threadBatch = 10
        var snapTid: String?
        var snapN: Int64 = -1
        src.hooks["threadsKeyset"] = .init(minCall: 2, once: true) {
            snapTid = idx.metaGet("t_tid")
            snapN = idx.metaGetLong("threads_n", -1)
        }
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snapTid, "231")   // head 250..241 + keyset1 240..231
        XCTAssertEqual(snapN, 20)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 250)
        idx.close()
    }

    /// actors id keyset 推进与 a_id 持久化（actors 无目标/裁剪逻辑）
    func test_actorsCursorPersists() async {
        let idx = mkIdx("acur")
        let src = FakeWarmSource()
        src.setActors(40)
        var cfg = SyncConfig()
        cfg.actorBatch = 15
        var snapAid: String?
        src.hooks["actorsKeyset"] = .init(minCall: 1, once: true) { snapAid = idx.metaGet("a_id") }
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snapAid, "a00026")   // head 40..26 末行（批 15）
        XCTAssertEqual(idx.metaGetLong("a_done", 0), 1)
        XCTAssertEqual(try? idx.countActors(), 40)
        XCTAssertEqual(src.callCount("actorsHead"), 1)
        XCTAssertEqual(src.callCount("actorsKeyset"), 3)   // 25..11, 10..1, 空
        idx.close()
    }

    // MARK: - B. 断点续传（stopAndJoin → 新实例续跑）

    /// 精确停在批边界：head 50 + same 批 50 → count=100、m_id=批末行
    func test_stopAndJoinPreservesCursorAndPauses() async {
        let idx = mkIdx("pause1")
        let src = FakeWarmSource()
        src.setMovies([("x1", 400)])
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 50
        cfg.movieBatch = 50
        let gate = TestGate()
        src.gates["moviesSame"] = gate
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitUntil { exactCountHelper(idx, "idx_movies") >= 50 }
        await stopAtGate(co, gate)

        XCTAssertFalse(co.isRunning())
        XCTAssertEqual(co.state.note, "已暂停 (断点已保存, 可继续索引)")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 100)
        XCTAssertEqual(idx.metaGet("m_phase"), "same")
        XCTAssertEqual(idx.metaGet("m_date"), "x1")
        XCTAssertEqual(idx.metaGet("m_id"), Self.pad6(301))
        idx.close()
    }

    /// 新 SyncCoordinator 实例（同一 IdxDb）从持久化游标续跑至完成，计数精确无重复
    func test_newInstanceResumesFromCursorWithoutDuplication() async {
        let idx = mkIdx("pause2")
        let src = FakeWarmSource()
        src.setMovies([("x1", 400)])
        src.setThreads(40)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 50
        cfg.movieBatch = 50
        let gate = TestGate()
        src.gates["moviesSame"] = gate
        let co1 = makeCo(idx: idx, source: src, config: cfg)
        _ = co1.start(trigger: "test", force: true)
        await waitUntil { exactCountHelper(idx, "idx_movies") >= 50 }
        await stopAtGate(co1, gate)
        XCTAssertEqual(exactCount(idx, "idx_movies"), 100)
        XCTAssertEqual(idx.metaGet("m_id"), Self.pad6(301))

        let co2 = makeCo(idx: idx, source: src, config: cfg)
        XCTAssertEqual(co2.start(trigger: "resume", force: true), .STARTED)
        await waitFinish(co2)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 400)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 40)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        XCTAssertEqual(co2.lastTrigger, "resume")
        idx.close()
    }

    /// 暂停时刻的线程游标精确恢复（t_tid=81 处续跑，计数精确 120）
    func test_stopMidRunThreadsCursorResume() async {
        let idx = mkIdx("tpause")
        let src = FakeWarmSource()
        src.setThreads(120, startTid: 120)
        var cfg = SyncConfig()
        cfg.threadBatch = 20
        let gate = TestGate()
        src.gates["threadsKeyset"] = gate
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitUntil { exactCountHelper(idx, "idx_threads") >= 20 }
        await stopAtGate(co, gate)

        XCTAssertEqual(exactCount(idx, "idx_threads"), 40)   // head 20 + keyset1 20
        XCTAssertEqual(idx.metaGet("t_tid"), "81")

        let co2 = makeCo(idx: idx, source: src, config: cfg)
        _ = co2.start(trigger: "resume", force: true)
        await waitFinish(co2)

        XCTAssertEqual(exactCount(idx, "idx_threads"), 120)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        idx.close()
    }

    // MARK: - C. applyLimits 六分支

    /// 同值 + 未运行 → NO_CHANGE 且 resume 续跑
    func test_applyLimitsNoChangeResumesWhenIdle() async {
        let idx = mkIdx("alnc")
        let src = FakeWarmSource()
        src.setMovies([("x1", 10)])
        let box = SettingsBox(WarmSettings(limitJdb: 100, limitSht: 10))
        let co = makeCo(idx: idx, source: src, box: box)
        let r = co.applyLimits(prevM: 100, prevT: 10, nextM: 100, nextT: 10)
        XCTAssertEqual(r, .NO_CHANGE)
        await waitFinish(co)
        XCTAssertEqual(co.lastTrigger, "resume")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 10)
        idx.close()
    }

    /// 同值 + 运行中 → NO_CHANGE 且不打断当前轮（runId 不变、无重启）
    func test_applyLimitsNoChangeKeepsRunningRun() async {
        let idx = mkIdx("alncrun")
        let src = FakeWarmSource()
        src.setMovies([("x1", 50)])
        src.gates["moviesHead"] = .init()
        let box = SettingsBox(WarmSettings(limitJdb: 100, limitSht: 10))
        let co = makeCo(idx: idx, source: src, box: box)
        _ = co.start(trigger: "test", force: true)
        await waitUntil { src.callCount("moviesHead") >= 1 }
        let runIdBefore = co.lastRunId

        let r = co.applyLimits(prevM: 100, prevT: 10, nextM: 100, nextT: 10)
        XCTAssertEqual(r, .NO_CHANGE)
        XCTAssertTrue(co.isRunning())
        XCTAssertEqual(co.lastRunId, runIdBefore)   // 未重启

        src.gates["moviesHead"]?.open()
        await waitFinish(co)
        XCTAssertEqual(co.lastTrigger, "test")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 50)
        idx.close()
    }

    /// META_ONLY：改小但两侧均无需继续、无需裁剪 → 只写 meta、不裁剪、不重启、游标不动
    func test_applyLimitsMetaOnlyBranch() async {
        let idx = mkIdx("almeta")
        seedIdxMovies(idx, 90)
        seedIdxThreads(idx, 10)
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src)
        let r = co.applyLimits(prevM: 100, prevT: 10, nextM: 90, nextT: 10)
        XCTAssertEqual(r, .STARTED)
        await waitUntil { idx.metaGetLong("m_target", -1) == 90 && idx.metaGetLong("m_done", -1) == 1 }

        XCTAssertEqual(exactCount(idx, "idx_movies"), 90)   // 未裁剪（90 <= 90）
        XCTAssertEqual(idx.metaGetLong("t_target", -1), 10)
        XCTAssertEqual(idx.metaGetLong("t_done", -1), 1)    // done(10, 10)
        XCTAssertNil(idx.metaGet("m_phase"))                // 游标未动（无 prune）
        XCTAssertEqual(co.lastTrigger, "")                  // 无 restart
        idx.close()
    }

    /// PRUNE_ONLY：改小且另一侧收敛 → 裁剪（离线语义也执行）、游标重置边界、不重启
    func test_applyLimitsPruneOnlyBranch() async {
        let idx = mkIdx("alprune")
        seedIdxMovies(idx, 100)
        seedIdxThreads(idx, 10)
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src)
        _ = co.applyLimits(prevM: 100, prevT: 10, nextM: 50, nextT: 10)
        await waitUntil { exactCountHelper(idx, "idx_movies") == 50 }
        await waitUntil { idx.metaGet("m_id") == Self.pad6(51) }

        XCTAssertEqual(exactCount(idx, "idx_threads"), 10)
        XCTAssertEqual(idx.metaGetLong("m_target", -1), 50)
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 1)    // done(50, afterM=50)
        XCTAssertEqual(idx.metaGetLong("t_done", -1), 1)    // done(10, 10)
        XCTAssertEqual(idx.metaGet("m_phase"), "same")
        XCTAssertEqual(idx.metaGet("m_date"), "d0051")      // 保留窗口最旧行
        XCTAssertEqual(co.lastTrigger, "")                  // 无 restart
        idx.close()
    }

    /// PRUNE_AND_RESTART：改小且另一侧需继续 → 裁剪 + 在线重启续跑至达标
    func test_applyLimitsPruneAndRestartBranch() async {
        let idx = mkIdx("alpr")
        seedIdxMovies(idx, 100)
        let src = FakeWarmSource()   // 重启后源为空 → 轮首裁剪后直接达标
        let co = makeCo(idx: idx, source: src)
        _ = co.applyLimits(prevM: 100, prevT: 0, nextM: 50, nextT: 0)
        await waitUntil { co.lastTrigger == "limit" && !co.isRunning() }

        XCTAssertEqual(exactCount(idx, "idx_movies"), 50)
        XCTAssertEqual(idx.metaGet("m_phase"), "same")
        XCTAssertEqual(idx.metaGet("m_date"), "d0051")
        XCTAssertEqual(idx.metaGet("m_id"), Self.pad6(51))
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 1)
        XCTAssertEqual(idx.metaGetLong("t_done", -1), 1)    // sht 空源 → empty done
        XCTAssertEqual(co.state.note, "已达目标上限")
        XCTAssertEqual(co.lastTrigger, "limit")
        idx.close()
    }

    /// RESTART：改大（在线）→ 从游标续走直到扫完
    func test_applyLimitsRestartBranch() async {
        let idx = mkIdx("alrestart")
        seedIdxMovies(idx, 50)
        seedIdxThreads(idx, 10)
        let src = FakeWarmSource()
        src.setMovies([("e0001", 60)])
        src.setThreads(10, startTid: 10)   // 与本地播种重叠 → 重启后计数仍 10
        let co = makeCo(idx: idx, source: src)
        _ = co.applyLimits(prevM: 50, prevT: 0, nextM: 100, nextT: 100)
        await waitUntil { co.lastTrigger == "limit" && !co.isRunning() }

        XCTAssertEqual(co.lastTrigger, "limit")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 60)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 10)
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 1)
        XCTAssertEqual(co.state.note, "空闲 (24h 后自动增量)")
        idx.close()
    }

    /// DEFER_OFFLINE：需要继续但源离线 → 不重启、5min 退避、done 按决策写
    /// （note 依次写 "源离线，联网后自动续跑" → 被 refreshStats 按 paused 规则覆盖为 "已暂停"）
    func test_applyLimitsDeferOfflineBranch() async {
        let idx = mkIdx("aldefer")
        seedIdxMovies(idx, 50)
        seedIdxThreads(idx, 10)
        let src = FakeWarmSource()
        src.setMovies([("e0001", 60)])
        let co = makeCo(idx: idx, source: src)
        OfflineGate.mark("jdb", ttlMs: 60_000)
        _ = co.applyLimits(prevM: 50, prevT: 0, nextM: 100, nextT: 100)
        await waitUntil { co.nextRunAt > Perf.nowMs() + 4 * 60_000 }

        XCTAssertEqual(co.lastTrigger, "")                  // 不重启
        XCTAssertLessThan(co.nextRunAt, Perf.nowMs() + 6 * 60_000)
        XCTAssertTrue(co.state.paused)                      // stopAndJoin → refreshStats 规则
        XCTAssertEqual(exactCount(idx, "idx_movies"), 50)   // 本例无 prune，行数不变
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 0)    // done(100, 50)=false
        XCTAssertEqual(idx.metaGetLong("t_done", -1), 0)    // done(100, 10)=false
        OfflineGate.reset()
        idx.close()
    }

    /// writeMeta + 状态归一：0=不限 → 落盘 0 / state 0；RESTART 后跑完
    func test_applyLimitsWritesTargetsToMetaAndState() async {
        let idx = mkIdx("almeta2")
        seedIdxMovies(idx, 10)
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src)
        _ = co.applyLimits(prevM: 10, prevT: 5, nextM: 0, nextT: 0)
        await waitUntil { idx.metaGetLong("m_target", -1) == 0 && co.state.targetMovies == 0 }

        XCTAssertEqual(idx.metaGetLong("t_target", -1), 0)
        XCTAssertEqual(co.state.targetThreads, 0)
        await waitFinish(co)   // RESTART → 空源跑完
        XCTAssertEqual(exactCount(idx, "idx_movies"), 10)
        idx.close()
    }

    /// 裁剪失败（applyLimits）：Failed → done 覆盖 0 + lastError/5min 退避 + 事务回滚
    /// （note 依次写 "裁剪失败，5 分钟后重试" → 被 refreshStats 按 paused 规则覆盖为 "已暂停"）
    func test_applyLimitsPruneFailOverridesDone() async {
        let idx = mkIdx("alprfail")
        seedIdxMovies(idx, 100)
        seedIdxThreads(idx, 10)
        try? idx.db.exec("DROP TABLE idx_movie_tags")   // 令 pruneMovies 事务失败回滚
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src)
        _ = co.applyLimits(prevM: 100, prevT: 10, nextM: 50, nextT: 10)
        await waitUntil { co.nextRunAt > Perf.nowMs() + 4 * 60_000 }

        XCTAssertEqual(exactCount(idx, "idx_movies"), 100)  // 事务已回滚
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 0)    // 绝不误置已达目标
        XCTAssertNil(idx.metaGet("m_phase"))                // Failed → 不重置游标
        XCTAssertTrue(co.state.lastError.hasPrefix("裁剪失败:"))
        XCTAssertLessThan(co.nextRunAt, Perf.nowMs() + 6 * 60_000)
        idx.close()
    }

    // MARK: - D. 裁剪边界 / 孤儿清理 / Failed 退避

    /// 轮首裁剪：Success → 游标重置到保留窗口下边界；达标 → m_done=1（不再扫描）
    func test_pruneAtRoundStartResetsCursorToBoundary() async {
        let idx = mkIdx("prune1")
        seedIdxMovies(idx, 10)
        let src = FakeWarmSource()   // 空源：head 空 + 本地 10 → 走轮首决策
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        _ = co.start(trigger: "test", limitJdb: 5, force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 5)
        XCTAssertEqual(idx.metaGet("m_phase"), "same")
        XCTAssertEqual(idx.metaGet("m_date"), "d0006")
        XCTAssertEqual(idx.metaGet("m_id"), Self.pad6(6))
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(co.state.note, "已达目标上限")
        XCTAssertEqual(src.callCount("moviesHead"), 1)      // 只探一次，未再向下扫描
        XCTAssertEqual(src.callCount("moviesTail"), 0)
        idx.close()
    }

    /// 批后裁剪（S16-09 同构）：单批越过目标 → prune → target，游标落在边界
    func test_pruneMidLoopHitsTargetAndResetsBoundary() async {
        let idx = mkIdx("prune2")
        let src = FakeWarmSource()
        src.movies = FakeWarmSource.sortMovies(
            (1...8).map { FMovie(id: Self.pad6($0), date: String(format: "d%04d", $0)) })
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 4
        cfg.movieBatch = 4
        let co = makeCo(idx: idx, source: src, config: cfg)
        _ = co.start(trigger: "test", limitJdb: 6, force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 6)
        XCTAssertEqual(idx.metaGet("m_date"), "d0003")      // 删 d0001/d0002 → 边界 d0003
        XCTAssertEqual(idx.metaGet("m_id"), Self.pad6(3))
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(co.state.note, "已达目标上限")
        idx.close()
    }

    /// 裁剪顺带清理被删影片的 tags/links 孤儿关系（PruneSql 语句 5/6）+ 孤儿自检归零
    func test_pruneCleansOrphanRelations() async {
        let idx = mkIdx("prune3")
        seedIdxMovies(idx, 10)
        var links: [(movieId: String, actorId: String)] = []
        var tags: [(movieId: String, tagId: String)] = []
        for i in 1...10 {
            links.append((Self.pad6(i), "a\(i)"))
            tags.append((Self.pad6(i), "t\(i)"))
        }
        idx.upsertLinks(links)
        idx.upsertTags(tags)
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src,
                        settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false))
        _ = co.start(trigger: "test", limitJdb: 5, force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 5)
        XCTAssertEqual(exactCount(idx, "idx_movie_tags"), 5)      // 只剩保留行的关系
        XCTAssertEqual(exactCount(idx, "idx_movie_actors"), 5)
        let orph = idx.orphanReport()
        XCTAssertEqual(orph.tagsOrphans, 0)
        XCTAssertEqual(orph.actorOrphans, 0)
        idx.close()
    }

    /// 循环内裁剪 Failed：m_done=0 + 5min 退避 + 事务回滚（行数不变）+ 出错文案
    func test_pruneMoviesFailedInLoopBacksOff() async {
        let idx = mkIdx("prunefail")
        seedIdxMovies(idx, 10)
        try? idx.db.exec("DROP TABLE idx_movie_tags")
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        _ = co.start(trigger: "test", limitJdb: 5, force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 10)   // 回滚
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 0)     // 保持 0
        XCTAssertEqual(co.consecutiveFails, 1)
        XCTAssertTrue(co.state.note.hasPrefix("出错:"))
        XCTAssertTrue(co.state.note.contains("(5 分钟后重试)"))
        XCTAssertTrue(co.state.lastError.contains("裁剪失败(movies)"))
        XCTAssertGreaterThan(co.nextRunAt, Perf.nowMs() + 4 * 60_000)
        XCTAssertLessThan(co.nextRunAt, Perf.nowMs() + 6 * 60_000)
        idx.close()
    }

    // MARK: - E. 离线早退 / 全离线

    /// jdb 离线 → movies/actors 直接早退（不发查询、不写 done），threads 照常
    func test_offlineJdbSkipsMoviesAndActorsButRunsThreads() async {
        let idx = mkIdx("offjdb")
        let src = FakeWarmSource()
        src.setMovies([("x1", 10)])
        src.setActors(5)
        src.setThreads(30)
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: true))
        OfflineGate.mark("jdb", ttlMs: 60_000)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(src.callCount("moviesHead"), 0)
        XCTAssertEqual(src.callCount("actorsHead"), 0)
        XCTAssertGreaterThanOrEqual(src.callCount("threadsFirst"), 1)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 30)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 0)
        XCTAssertEqual(co.state.note, "空闲 (24h 后自动增量)")
        OfflineGate.reset()
        idx.close()
    }

    /// sht 离线 → threads 早退，movies 照常
    func test_offlineShtSkipsThreads() async {
        let idx = mkIdx("offsht")
        let src = FakeWarmSource()
        src.setMovies([("x1", 10)])
        src.setThreads(30)
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        OfflineGate.mark("sht", ttlMs: 60_000)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(src.callCount("threadsFirst"), 0)
        XCTAssertEqual(src.callCount("moviesHead"), 1)
        XCTAssertEqual(exactCount(idx, "idx_movies"), 10)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 0)
        OfflineGate.reset()
        idx.close()
    }

    /// 全离线 → reason=offline：note/phase/nextRunAt/consecutiveFails 对位、不写 done
    func test_allOfflineFinishReasonOffline() async {
        let idx = mkIdx("alloff")
        let src = FakeWarmSource()
        src.setMovies([("x1", 5)])
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        OfflineGate.mark("jdb", ttlMs: 60_000)
        OfflineGate.mark("sht", ttlMs: 60_000)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(co.state.note, "源离线，5 分钟后重试")
        XCTAssertEqual(co.state.phase, "idle")
        XCTAssertFalse(co.state.paused)
        XCTAssertGreaterThan(co.nextRunAt, Perf.nowMs() + 4 * 60_000)
        XCTAssertEqual(co.consecutiveFails, 0)              // 离线清零（不算失败）
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 0)
        OfflineGate.reset()
        idx.close()
    }

    // MARK: - F. 单飞 / 开关 / runId 双保险

    /// 单飞：运行中第二次 start → ALREADY_RUNNING
    func test_secondStartWhileRunningReturnsAlreadyRunning() async {
        let idx = mkIdx("sf")
        let src = FakeWarmSource()
        src.setMovies([("x1", 20)])
        src.gates["moviesHead"] = .init()
        let co = makeCo(idx: idx, source: src)
        XCTAssertEqual(co.start(trigger: "test", force: true), .STARTED)
        await waitUntil { src.callCount("moviesHead") >= 1 }

        XCTAssertEqual(co.start(trigger: "test2", force: true), .ALREADY_RUNNING)

        src.gates["moviesHead"]?.open()
        await waitFinish(co)
        XCTAssertEqual(co.lastTrigger, "test")
        idx.close()
    }

    /// 开关关 → DISABLED；force=true → STARTED
    func test_startDisabledAndForceSkipsSwitch() async {
        let idx = mkIdx("dis")
        let src = FakeWarmSource()
        src.setMovies([("x1", 5)])
        let box = SettingsBox(WarmSettings(enabled: false))
        let co = makeCo(idx: idx, source: src, box: box)
        XCTAssertEqual(co.start(trigger: "t", force: false), .DISABLED)
        XCTAssertFalse(co.isRunning())

        XCTAssertEqual(co.start(trigger: "t", force: true), .STARTED)
        await waitFinish(co)
        XCTAssertEqual(exactCount(idx, "idx_movies"), 5)
        idx.close()
    }

    /// resume = force=true：开关关闭也可续跑
    func test_resumeForcesEvenWhenDisabled() async {
        let idx = mkIdx("res")
        let src = FakeWarmSource()
        src.setMovies([("x1", 5)])
        let box = SettingsBox(WarmSettings(enabled: false))
        let co = makeCo(idx: idx, source: src, box: box)
        XCTAssertEqual(co.resume(), .STARTED)
        await waitFinish(co)
        XCTAssertEqual(co.lastTrigger, "resume")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 5)
        idx.close()
    }

    /// runId 双保险：批中 currentRunId 被外部改变 → 旧批不得写回（upsert 前检查 → return）
    func test_runIdGuardsOldBatchWrites() async {
        let idx = mkIdx("runid")
        let src = FakeWarmSource()
        src.setMovies([("x1", 6)])
        src.setThreads(4)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 2
        cfg.movieBatch = 2
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false), config: cfg)
        src.hooks["moviesSame"] = .init(minCall: 1) { [weak co] in co?.testOnlySetCurrentRunId(999) }
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 2)        // 只有 head 批落库
        XCTAssertEqual(idx.metaGet("m_id"), Self.pad6(5))       // 游标停在 head 末行
        XCTAssertEqual(exactCount(idx, "idx_threads"), 4)       // 其他两路不受影响
        XCTAssertEqual(co.state.note, "空闲 (24h 后自动增量)")
        idx.close()
    }

    // MARK: - G. 速度 / ETA / 节流

    /// 速度 = runRows*60000/max(1,elapsed)；ETA = remain*60/speed；结束后双双清零
    func test_speedAndEtaFormulas() async {
        let idx = mkIdx("speed")
        let clock = TestClock(1_000_000)
        let src = FakeWarmSource()
        src.setMovies([("x1", 2000)])
        var cfg = SyncConfig()
        cfg.pushThrottleMs = 0
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(limitJdb: 3000),
                        config: cfg, clock: clock)
        var calls = 0
        var snap = SyncState()
        weak var weakCo: SyncCoordinator?
        weakCo = co
        src.hooks["moviesSame"] = .init(minCall: 1) {
            calls += 1
            if calls == 2 { snap = weakCo?.state ?? SyncState() }   // 只取批 1 推送后的状态（>= 会同一3 的覆盖）
            clock.tick(60_000)
        }
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        // 批 1（same, 500 行）推送：runRows=1500, elapsed=60000 → speed=1500；remain=1500 → eta=60
        XCTAssertEqual(snap.speedPerMin, 1500)
        XCTAssertEqual(snap.etaSec, 60)
        XCTAssertEqual(snap.movies, 1500)
        XCTAssertEqual(co.state.speedPerMin, 0)   // finishRun 清零
        XCTAssertEqual(co.state.etaSec, 0)
        idx.close()
    }

    /// speed <= 10 → ETA 0
    func test_etaZeroWhenSpeedLow() async {
        let idx = mkIdx("slow")
        let clock = TestClock(1_000_000)
        let src = FakeWarmSource()
        src.setMovies([("x1", 2000)])
        var cfg = SyncConfig()
        cfg.pushThrottleMs = 0
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(limitJdb: 3000),
                        config: cfg, clock: clock)
        var calls = 0
        var snap = SyncState()
        weak var weakCo: SyncCoordinator?
        weakCo = co
        src.hooks["moviesSame"] = .init(minCall: 1) {
            calls += 1
            if calls == 2 { snap = weakCo?.state ?? SyncState() }
            clock.tick(36_000_000)   // 10 小时/批
        }
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snap.speedPerMin, 2)   // 1500*60000/36000000
        XCTAssertEqual(snap.etaSec, 0)
        idx.close()
    }

    /// 不限（targetMovies=0）→ ETA 0（即使速度很高）
    func test_etaZeroWhenNoTarget() async {
        let idx = mkIdx("etazero")
        let clock = TestClock(1_000_000)
        let src = FakeWarmSource()
        src.setMovies([("x1", 2000)])
        var cfg = SyncConfig()
        cfg.pushThrottleMs = 0
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(limitJdb: 0),
                        config: cfg, clock: clock)
        var calls = 0
        var snap = SyncState()
        weak var weakCo: SyncCoordinator?
        weakCo = co
        src.hooks["moviesSame"] = .init(minCall: 1) {
            calls += 1
            if calls == 2 { snap = weakCo?.state ?? SyncState() }
            clock.tick(60_000)
        }
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(snap.speedPerMin, 1500)
        XCTAssertEqual(snap.etaSec, 0)
        idx.close()
    }

    /// 进度推送节流 1s：窗口内批不更新状态（head 推送后 same1/same2 被节流，same3 恢复推送）
    func test_progressPushThrottleSkipsWithinOneSecond() async {
        let idx = mkIdx("throttle")
        let clock = TestClock(1_000_000)
        let src = FakeWarmSource()
        src.setMovies([("x1", 3000)])
        var cfg = SyncConfig()
        cfg.pushThrottleMs = 1_000
        cfg.movieHeadBatch = 1000
        cfg.movieBatch = 500
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(limitJdb: 3000),
                        config: cfg, clock: clock)
        var calls = 0
        var snapAt2 = SyncState()
        var snapAt4 = SyncState()
        weak var weakCo: SyncCoordinator?
        weakCo = co
        src.hooks["moviesSame"] = .init(minCall: 1) {
            calls += 1
            if calls == 2 { snapAt2 = weakCo?.state ?? SyncState() }
            if calls == 4 { snapAt4 = weakCo?.state ?? SyncState() }
            clock.tick(400)
        }
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        // head 在 T0 推送（speed=1000*60000/1）；same1(+400ms)/same2(+800ms) 距上推 <1s 被节流
        XCTAssertEqual(snapAt2.speedPerMin, 60_000_000)
        XCTAssertEqual(snapAt2.movies, 0)
        // same3(+1200ms) 恢复推送：runRows=2500, elapsed=1200 → 125000
        XCTAssertEqual(snapAt4.speedPerMin, 125_000)
        XCTAssertEqual(snapAt4.movies, 2500)
        idx.close()
    }

    // MARK: - H. finishRun 退避 / moreWork 续跑

    /// 达标（reason=target）+ 本轮有行 → note 已达目标上限、24h 增量、phase=paused 但 paused=false
    func test_finishTargetNoteAnd24hBackoff() async {
        let idx = mkIdx("t24")
        let src = FakeWarmSource()
        src.setMovies([("x1", 100)])
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        _ = co.start(trigger: "test", limitJdb: 100, force: true)
        await waitFinish(co)

        XCTAssertEqual(co.state.note, "已达目标上限")
        XCTAssertEqual(co.state.phase, "paused")
        XCTAssertFalse(co.state.paused)
        XCTAssertGreaterThan(co.nextRunAt, Perf.nowMs() + 24 * 3600_000 - 60_000)
        XCTAssertEqual(co.consecutiveFails, 0)
        idx.close()
    }

    /// 达标但本轮 0 行（S15-04 硬保险）→ 退避 5min 而非 24h，绝不 2s 重启
    func test_targetNoRowsBacksOffFiveMinutes() async {
        let idx = mkIdx("norows")
        seedIdxMovies(idx, 120)
        let src = FakeWarmSource()   // 空源
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        _ = co.start(trigger: "test", limitJdb: 100, force: true)
        await waitFinish(co)
        try? await Task.sleep(nanoseconds: 100_000_000)   // 若误 2s 重启也来不及；断言退避值

        XCTAssertEqual(exactCount(idx, "idx_movies"), 100)   // 轮首裁剪到 100
        XCTAssertEqual(co.state.note, "已达目标上限")
        XCTAssertGreaterThan(co.nextRunAt, Perf.nowMs() + 4 * 60_000)
        XCTAssertLessThan(co.nextRunAt, Perf.nowMs() + 6 * 60_000)
        XCTAssertNotEqual(co.lastTrigger, "auto-raise")
        idx.close()
    }

    /// 单次错误 → 5min 退避 + consecutiveFails=1 + note/phase/lastError 对位
    func test_errorBacksOffFiveMinutes() async {
        let idx = mkIdx("err1")
        let src = FakeWarmSource()
        src.errors["moviesHead"] = TestError(msg: "boom")
        src.setThreads(2)
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(co.consecutiveFails, 1)
        XCTAssertEqual(co.state.phase, "error")
        XCTAssertTrue(co.state.note.hasPrefix("出错:"))
        XCTAssertTrue(co.state.note.contains("(5 分钟后重试)"))
        XCTAssertFalse(co.state.lastError.isEmpty)
        XCTAssertGreaterThan(co.nextRunAt, Perf.nowMs() + 4 * 60_000)
        idx.close()
    }

    /// 连续 3 次错误 → nextRunAt = Long.MAX（停手等手动）、note 含连续失败
    func test_threeConsecutiveErrorsStopUntilManual() async {
        let idx = mkIdx("err3")
        let src = FakeWarmSource()
        src.errors["moviesHead"] = TestError(msg: "boom")
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        for _ in 0..<3 {
            _ = co.start(trigger: "test", force: true)
            await waitFinish(co)
        }

        XCTAssertEqual(co.consecutiveFails, 3)
        XCTAssertEqual(co.nextRunAt, Int64.max)
        XCTAssertTrue(co.state.note.contains("(连续失败, 等待手动继续)"))
        idx.close()
    }

    /// moreWork 续跑：target 达标后上限热更 + m_done 清零 → auto-raise 续跑到新目标后自然收敛
    func test_moreWorkAutoRaiseRestartsWithRaisedLimit() async {
        let idx = mkIdx("raise")
        let src = FakeWarmSource()
        src.setMovies([("x1", 150)])
        src.setThreads(2500, startTid: 2500)
        var cfg = SyncConfig()
        cfg.threadBatch = 1000
        cfg.threadDelayMs = 30          // 显式保留：让 movies 先达标收尾
        cfg.autoRaiseDelayMs = 50
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false), config: cfg)
        // threads 第 2 次查询时（movies 已达标收尾）：模拟"上限已改大 + 外部清 m_done"
        src.hooks["threadsKeyset"] = .init(minCall: 2, once: true) { [weak co] in
            idx.metaPutLong("m_done", 0)
            co?.testOnlySetPrefTargets(m: 200, t: 0)
        }
        _ = co.start(trigger: "test", limitJdb: 100, limitSht: 0, force: true)
        await waitUntil { co.lastTrigger == "auto-raise" }
        await waitFinish(co)

        XCTAssertEqual(co.lastTrigger, "auto-raise")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 150)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 2500)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        idx.close()
    }

    // MARK: - I. 门禁封装 probe / idleCheck

    /// probe：running/done*/nextRunAt 由实时值覆盖（pending → due → backoff → running）
    func test_probeOverridesDynamicFields() async {
        let idx = mkIdx("probe")
        let src = FakeWarmSource()
        src.setMovies([("x1", 5)])
        let co = makeCo(idx: idx, source: src)

        // 未运行 + 无 done → source-pending
        XCTAssertEqual(co.probe(input: defaultGateInput), "source-pending")
        XCTAssertTrue(co.probeShouldStart(input: defaultGateInput))

        // 三 done 置位 → 无待办且到期 → due
        idx.metaPutLong("m_done", 1)
        idx.metaPutLong("t_done", 1)
        idx.metaPutLong("a_done", 1)
        XCTAssertEqual(co.probe(input: defaultGateInput), "due")

        // 退避中 → backoff
        co.testOnlySetNextRunAt(Int64.max)
        XCTAssertEqual(co.probe(input: defaultGateInput), "backoff")
        XCTAssertFalse(co.probeShouldStart(input: defaultGateInput))
        co.testOnlySetNextRunAt(0)

        // 运行中 → running（覆盖 input.running=false）
        let g2 = TestGate()
        src.gates["moviesHead"] = g2
        _ = co.start(trigger: "t", force: true)
        await waitUntil { co.isRunning() }
        XCTAssertEqual(co.probe(input: defaultGateInput), "running")
        g2.open()
        src.gates["moviesHead"] = nil
        await waitFinish(co)
        idx.close()
    }

    /// idleCheck：source-pending → 自动起跑（trigger=auto）
    func test_idleCheckStartsAutoWhenSourcePending() async {
        let idx = mkIdx("idle1")
        let src = FakeWarmSource()
        src.setMovies([("x1", 5)])
        let co = makeCo(idx: idx, source: src)
        let why = co.idleCheck(input: defaultGateInput)
        XCTAssertEqual(why, "source-pending")
        await waitFinish(co)
        XCTAssertEqual(co.lastTrigger, "auto")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 5)
        idx.close()
    }

    /// idleCheck：退避中 → backoff 且不起跑
    func test_idleCheckBackoffDoesNotStart() async {
        let idx = mkIdx("idle2")
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src)
        idx.metaPutLong("m_done", 1)
        idx.metaPutLong("t_done", 1)
        idx.metaPutLong("a_done", 1)
        co.testOnlySetNextRunAt(Int64.max)
        let why = co.idleCheck(input: defaultGateInput)
        XCTAssertEqual(why, "backoff")
        XCTAssertFalse(co.isRunning())
        XCTAssertEqual(co.lastTrigger, "")
        idx.close()
    }

    // MARK: - J. links / tags 开关与写入

    /// shadowActorLinks=false / shadowTagIndex=false → 不发 links/tags 查询
    func test_linksTagsFlagsRespected() async {
        let idx = mkIdx("flags")
        let src = FakeWarmSource()
        src.setMovies([("x1", 10)])
        src.linksBy[Self.pad6(1)] = ["a1"]
        src.tagsBy[Self.pad6(1)] = ["t1"]
        let co = makeCo(idx: idx, source: src,
                        settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false))
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(src.callCount("links"), 0)
        XCTAssertEqual(src.callCount("tags"), 0)
        XCTAssertEqual(exactCount(idx, "idx_movie_actors"), 0)
        XCTAssertEqual(exactCount(idx, "idx_movie_tags"), 0)
        idx.close()
    }

    /// links/tags 随 movies 批顺带写入（IN 随批 ids）
    func test_linksTagsUpsertedAlongMovieBatches() async {
        let idx = mkIdx("lt")
        let src = FakeWarmSource()
        src.setMovies([("x1", 10)])
        src.linksBy[Self.pad6(1)] = ["a1", "a2"]
        src.linksBy[Self.pad6(2)] = ["a1"]
        src.tagsBy[Self.pad6(1)] = ["t1", "t2"]
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co)

        XCTAssertEqual(exactCount(idx, "idx_movie_actors"), 3)
        XCTAssertEqual(exactCount(idx, "idx_movie_tags"), 2)
        XCTAssertEqual(src.callCount("links"), 1)   // head 批已含全部 10 行（id DESC 末批含 m1/m2）
        idx.close()
    }

    // MARK: - K. rebuild / clearAll / 杂项

    /// rebuild：清库清游标 + done 归零 + force 重跑到新目标（trigger=rebuild）
    func test_rebuildClearsAndReruns() async {
        let idx = mkIdx("rebuild")
        seedIdxMovies(idx, 20)
        idx.metaPutLong("m_done", 1)
        idx.metaPut("m_phase", "done")
        let src = FakeWarmSource()
        src.setMovies([("x1", 50)])
        src.setThreads(10)
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false))
        await co.rebuild(limitJdb: 30)
        await waitFinish(co)

        XCTAssertEqual(co.lastTrigger, "rebuild")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 30)   // 裁到新目标
        XCTAssertEqual(exactCount(idx, "idx_threads"), 10)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertGreaterThan(idx.metaGetLong("m_head_ts", 0), 0)   // 游标已重建
        XCTAssertEqual(co.consecutiveFails, 0)
        idx.close()
    }

    /// clearAll：清影子库 + 索引库 + 游标（不自动重跑），状态归零
    func test_clearAllClearsIdxAndShadow() async {
        let idx = mkIdx("clear")
        seedIdxMovies(idx, 10)
        idx.metaPut("m_phase", "same")
        let shadow = try! ShadowDb(directory: tmpDir("clear-shadow"))
        try? shadow.upsertMovies([Row(["id": .string("s1"), "title": .string("S1")])])
        let src = FakeWarmSource()
        // 影子库必须注入协调器（05_sync.md §1.7：clearAll = 先 ShadowDb.clear() 再清 idx 库与游标）
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(actorIndex: false), shadow: shadow)
        await co.clearAll()

        XCTAssertEqual(exactCount(idx, "idx_movies"), 0)
        XCTAssertNil(idx.metaGet("m_phase"))
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 0)
        XCTAssertEqual((try? shadow.count("movies_shadow")) ?? -1, 0)
        XCTAssertEqual(co.state.note, "空闲")
        XCTAssertEqual(co.state.phase, "idle")
        XCTAssertFalse(co.isRunning())
        idx.close()
    }

    /// StartResult 枚举值锁定（NO_TARGET 为兼容保留、本文件内无返回点）
    func test_startResultEnumContainsNoTarget() {
        let r = StartResult.NO_TARGET
        var found = false
        switch r {
        case .STARTED, .ALREADY_RUNNING, .NO_TARGET, .DISABLED, .NO_CHANGE:
            found = (r == .NO_TARGET)
        }
        XCTAssertTrue(found)
    }

    /// refreshStats 口径：仅索引模式读 IdxDb 计数 + mode 文案 + 目标回写 + note 规则
    func test_refreshStatsIdxMode() async {
        let idx = mkIdx("stats")
        seedIdxMovies(idx, 7)
        seedIdxThreads(idx, 3)
        let src = FakeWarmSource()
        let co = makeCo(idx: idx, source: src, settings: WarmSettings(limitJdb: 100, limitSht: 50))
        co.refreshStats()

        XCTAssertEqual(co.state.movies, 7)
        XCTAssertEqual(co.state.threads, 3)
        XCTAssertEqual(co.state.targetMovies, 100)
        XCTAssertEqual(co.state.targetThreads, 50)
        XCTAssertEqual(co.state.mode, "仅索引")
        XCTAssertEqual(co.state.note, "空闲")
        XCTAssertEqual(co.state.phase, "idle")
        XCTAssertGreaterThanOrEqual(co.state.idxBytes, 0)
        idx.close()
    }

    // MARK: - L. 生产源 SQL 模板逐字锁定

    func test_warmDbSourceSqlTemplatesVerbatim() {
        let cols = WarmDbSource.MOVIE_BASE_COLS
        XCTAssertEqual(
            WarmDbSource.moviesHeadSql(cols),
            "SELECT \(cols) FROM movies m ORDER BY m.release_date DESC, m.id DESC LIMIT 1000")
        XCTAssertEqual(
            WarmDbSource.moviesSameSql(cols),
            "SELECT \(cols) FROM movies m WHERE m.release_date = ? AND m.id < ? ORDER BY m.id DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.moviesTailSql(cols),
            "SELECT \(cols) FROM movies m WHERE m.release_date < ? ORDER BY m.release_date DESC, m.id DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.moviesNullFirstSql(cols),
            "SELECT \(cols) FROM movies m WHERE (m.release_date IS NULL OR m.release_date = '') ORDER BY m.id DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.moviesNullTailSql(cols),
            "SELECT \(cols) FROM movies m WHERE (m.release_date IS NULL OR m.release_date = '') AND m.id < ? ORDER BY m.id DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.threadsFirstSql(table: "sht_threads", cols: "tid, title"),
            "SELECT tid, title FROM sht_threads ORDER BY tid DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.threadsKeysetSql(table: "sht_threads", cols: "tid, title"),
            "SELECT tid, title FROM sht_threads WHERE tid < ? ORDER BY tid DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.actorsHeadSql("id, name"),
            "SELECT id, name FROM actors ORDER BY id DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.actorsKeysetSql("id, name"),
            "SELECT id, name FROM actors WHERE id < ? ORDER BY id DESC LIMIT ?")
        XCTAssertEqual(
            WarmDbSource.linksSql(["a", "b"]),
            "SELECT movie_id, actor_id FROM movie_actors WHERE movie_id IN (?,?)")
        XCTAssertEqual(
            WarmDbSource.tagsSql(["a"]),
            "SELECT movie_id, tag_id FROM movie_tags WHERE movie_id IN (?)")
        XCTAssertEqual(
            WarmDbSource.MOVIE_BASE_COLS,
            "id, number, title, release_date, year, score, want_watch_count, magnets_count, number_letter")
        XCTAssertEqual(WarmDbSource.MOVIE_EXTRA_COLS, ["maker_id", "series_id", "director_id", "publisher_id"])
        XCTAssertEqual(
            WarmDbSource.THREAD_COLS_ALL,
            ["tid", "title", "post_date", "board", "board_name", "type",
             "magnet_count", "article_words", "paywalled"])
        _ = WarmDbSourceFactory()   // 工厂返回生产实现
    }

    // MARK: - M. 10 万行假 fixture（SQLite IdxDb）：跑完 / 暂停续跑 / 重建 / 清理

    func test_bigFixture100kRunToDone() async {
        let idx = mkIdx("big1")
        let src = BigFakeSource(totalMovies: 100_000, totalDates: 100, totalThreads: 1_000)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 1000
        cfg.movieBatch = 1000
        let co = makeCo(idx: idx, source: src,
                        settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false),
                        config: cfg)
        _ = co.start(trigger: "test", force: true)
        await waitFinish(co, timeoutMs: 180_000)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 100_000)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 1_000)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(idx.metaGetLong("t_done", 0), 1)
        XCTAssertEqual(idx.metaGet("m_phase"), "done")
        XCTAssertEqual(co.state.note, "空闲 (24h 后自动增量)")
        idx.close()
    }

    /// 暂停（精确钉在 D100 尾段后的第一个 tail 批）→ 新实例续跑：总数精确 10 万
    func test_bigFixturePauseAndResume() async {
        let idx = mkIdx("big2")
        let src = BigFakeSource(totalMovies: 100_000, totalDates: 100, totalThreads: 500)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 1000
        cfg.movieBatch = 1000
        let gate = TestGate()
        src.gates["moviesTail"] = gate
        let co1 = makeCo(idx: idx, source: src,
                         settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false),
                         config: cfg)
        _ = co1.start(trigger: "test", force: true)
        await waitUntil { exactCountHelper(idx, "idx_movies") >= 1000 }
        await stopAtGate(co1, gate)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 2000)   // head(D100) + tail(D099)
        XCTAssertEqual(idx.metaGet("m_phase"), "same")        // tail 批末行落入新日期 → SAME
        XCTAssertEqual(idx.metaGet("m_date"), "D099")
        XCTAssertEqual(idx.metaGet("m_id"), "M098001")

        let co2 = makeCo(idx: idx, source: src,
                         settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false),
                         config: cfg)
        XCTAssertEqual(co2.start(trigger: "resume", force: true), .STARTED)
        await waitFinish(co2, timeoutMs: 180_000)

        XCTAssertEqual(exactCount(idx, "idx_movies"), 100_000)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 500)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        idx.close()
    }

    /// 重建：先跑一段 → rebuild(50_000) 清库重跑并裁到新目标 → clearAll 清空
    func test_bigFixtureRebuildAndClearAll() async {
        let idx = mkIdx("big3")
        let src = BigFakeSource(totalMovies: 100_000, totalDates: 100, totalThreads: 200)
        var cfg = SyncConfig()
        cfg.movieHeadBatch = 1000
        cfg.movieBatch = 1000
        let gate = TestGate()
        src.gates["moviesTail"] = gate
        let co1 = makeCo(idx: idx, source: src,
                         settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false),
                         config: cfg)
        _ = co1.start(trigger: "test", force: true)
        await waitUntil { exactCountHelper(idx, "idx_movies") >= 1000 }
        await stopAtGate(co1, gate)
        XCTAssertEqual(exactCount(idx, "idx_movies"), 2000)

        let co2 = makeCo(idx: idx, source: src,
                         settings: WarmSettings(actorIndex: false, actorLinks: false, tagIndex: false),
                         config: cfg)
        await co2.rebuild(limitJdb: 50_000)
        await waitFinish(co2, timeoutMs: 180_000)

        XCTAssertEqual(co2.lastTrigger, "rebuild")
        XCTAssertEqual(exactCount(idx, "idx_movies"), 50_000)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 200)
        XCTAssertEqual(idx.metaGetLong("m_done", 0), 1)
        XCTAssertEqual(co2.state.note, "已达目标上限")

        await co2.clearAll()
        XCTAssertEqual(exactCount(idx, "idx_movies"), 0)
        XCTAssertEqual(exactCount(idx, "idx_threads"), 0)
        XCTAssertNil(idx.metaGet("m_phase"))
        XCTAssertEqual(idx.metaGetLong("m_done", -1), 0)
        XCTAssertEqual(exactCount(idx, "idx_movie_tags"), 0)
        idx.close()
    }
}

// MARK: - 测试辅助（文件级函数，供逃逸闭包稳定捕获）

private func exactCountHelper(_ idx: IdxDb, _ table: String) -> Int64 {
    (try? idx.countOfExact(table: table)) ?? -1
}
