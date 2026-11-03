import XCTest
import JDLVCore
@testable import JDLV

//
//  BrowseVMTests.swift —— BrowseVM 行为单测（14_vm_tests A.0/A.2 契约 + 08 C 节逐条）。
//
//  覆盖：normSort 白名单 / 缓存键含 asc / keyset 锚点写入与非 append 清空（NA-34）/
//  append 按 id 去重 / 500 软上限（NA-22）/ loadNext 守卫 / hasMore 满页推断（铁律 20）/
//  goPage PaginationGuard 钳制 + 跳页过深 Toast / applyFilters 反查恒倒序 /
//  rid 竞态丢弃旧响应 / total<0 不回退 / 异步计数 bcount / TTL 缓存命中与过期 /
//  stale 回退（SWR）/ RefreshResult 仅手动下拉 / filterCount + 反查摘要逐字 /
//  onDataEpoch 60s 冷却 / LookupVM 解码与独立 VM / demo 假数据源（DEBUG）。
//
//  时钟/缓存/数据源/Toast 全部可注入 → 无网络、无磁盘、无 AppServices 依赖。
//

final class BrowseVMTests: XCTestCase {

    // MARK: - 测试假件

    /// 假数据源（@MainActor：与 VM 同域，行为确定；按调用序返回响应/错误/延迟）
    @MainActor
    private final class MockSource: BrowseDataSource {
        private(set) var calls = 0
        /// 第 n 次调用的响应（缺省 → fallback）
        var responses: [[String: Any]] = []
        /// 第 n 次调用抛错（非 nil 时）
        var errors: [Error?] = []
        /// 第 n 次调用延迟 ms（rid 竞态测试用）
        var delays: [Int] = []
        var fallback: [String: Any] = [
            "items": [Row](), "total": Int64(-1), "approx": true, "derived": "", "page": 1,
        ]

        private(set) var seenFilters: [Filters] = []
        private(set) var seenSorts: [String] = []
        private(set) var seenAscs: [Bool] = []
        private(set) var seenAnchors: [[String]?] = []
        private(set) var seenPages: [Int] = []
        private(set) var countCalls = 0
        var countValue: Int64 = -1

        func browse(
            f: Filters, page: Int, per: Int, sort: String, asc: Bool, anchor: [String]?
        ) async throws -> [String: Any] {
            let idx = calls
            calls += 1
            seenFilters.append(f)
            seenSorts.append(sort)
            seenAscs.append(asc)
            seenAnchors.append(anchor)
            seenPages.append(page)
            if delays.count > idx, delays[idx] > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delays[idx]) * 1_000_000)
            }
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx] : fallback
        }

        func browseCount(f: Filters, sort: String) async -> Int64 {
            countCalls += 1
            return countValue
        }
    }

    /// 假缓存（可控时钟：TTL 命中/过期/stale 全覆盖）
    private final class MockCache: BrowseCacheStore {
        var store: [String: (payload: [String: Any], ts: Int64)] = [:]
        var now: Int64 = 1_730_000_000_000

        func get(_ key: String, ttlMinutes: Int) -> [String: Any]? {
            guard let e = store[key] else { return nil }
            if ttlMinutes > 0 && now - e.ts > Int64(ttlMinutes) * 60_000 { return nil }
            return e.payload
        }

        func put(_ key: String, _ payload: [String: Any]) {
            store[key] = (payload, now)
        }

        func stale(_ key: String) -> [String: Any]? {
            store[key]?.payload
        }
    }

    private struct MockTaxonomyLoader: BrowseTaxonomyLoader {
        var bundle = BrowseTaxonomyBundle(source: "remote")
        func load() async -> BrowseTaxonomyBundle { bundle }
    }

    private final class ToastBox {
        var list: [String] = []
    }

    // MARK: 构造器

    private func rows(_ ids: [String]) -> [Row] {
        ids.map {
            Row([
                "id": .string($0), "number": .string("ABP-\($0)"),
                "title": .string("t\($0)"), "release_date": .string("2024-01-01"),
            ])
        }
    }

    private func page(
        _ ids: [String], total: Int64 = -1, anchor: [String]? = nil,
        derived: String = "", approx: Bool = true
    ) -> [String: Any] {
        var d: [String: Any] = [
            "items": rows(ids), "total": total,
            "derived": derived, "approx": approx, "page": 1,
        ]
        if let a = anchor {
            d["anchor"] = a
        } else {
            d["anchor"] = NSNull()   // 对齐 Q.browse：无锚点 → null
        }
        return d
    }

    @MainActor
    private func makeVM(
        _ source: MockSource, _ cache: MockCache = MockCache(), _ toasts: ToastBox = ToastBox()
    ) -> BrowseVM {
        BrowseVM(
            source: source, cache: cache, taxonomyLoader: MockTaxonomyLoader(),
            marks: BrowseMarkSource.empty(),
            onToast: { toasts.list.append($0) })
    }

    // MARK: normSort（A.2）

    @MainActor
    func testNormSortMapping() {
        XCTAssertEqual(BrowseVM.normSort("want"), "want_watch_count")   // 旧档归一
        XCTAssertEqual(BrowseVM.normSort("release_date"), "release_date")
        XCTAssertEqual(BrowseVM.normSort("id"), "id")
        XCTAssertEqual(BrowseVM.normSort("score"), "score")
        XCTAssertEqual(BrowseVM.normSort("want_watch_count"), "want_watch_count")
        XCTAssertEqual(BrowseVM.normSort("bogus"), "release_date")      // 非白名单 → 默认
        XCTAssertEqual(BrowseVM.normSort(""), "release_date")
    }

    // MARK: 缓存键含 asc（S11-P2：正/倒序不互读缓存）

    @MainActor
    func testListCacheKeyFormatAndAsc() {
        let f = Filters(year: "2024", cnsub: true)
        let k1 = BrowseVM.listCacheKey(f: f, sort: "score", asc: true, per: 60, page: 3)
        XCTAssertEqual(k1, "browse:\(BrowseVM.filterKey(f)):score:true:60:3")
        XCTAssertFalse(k1.contains("+"))
        // 键含 asc：正/倒序不同键
        XCTAssertNotEqual(
            k1,
            BrowseVM.listCacheKey(f: f, sort: "score", asc: false, per: 60, page: 3))
        // f 变化 → 不同键
        XCTAssertNotEqual(
            k1,
            BrowseVM.listCacheKey(f: Filters(year: "2025", cnsub: true),
                                  sort: "score", asc: true, per: 60, page: 3))
        XCTAssertEqual(
            BrowseVM.countCacheKey(f: f, sort: "score"),
            "bcount:\(BrowseVM.filterKey(f)):score")
    }

    // MARK: keyset 锚点（响应 anchor 字段；缓存/新鲜统一写入）

    @MainActor
    func testFetchStoresKeysetAnchor() async {
        let src = MockSource()
        src.responses = [page(["m1", "m2", "m3"], anchor: ["2024-01-01", "m3"])]
        let vm = makeVM(src)
        vm.per = 3
        await vm.reload()
        XCTAssertEqual(vm.anchors[1], ["2024-01-01", "m3"])
        XCTAssertTrue(vm.hasMore)
        // loadNext → 第 2 页请求携带 anchors[1]
        src.responses.append(page(["m4"], anchor: nil))
        await vm.loadNext()
        XCTAssertEqual(vm.page, 2)
        XCTAssertEqual(src.seenAnchors.last ?? nil, ["2024-01-01", "m3"] as [String]?)
        XCTAssertEqual(src.seenPages.last, 2)
        // 第 2 页响应无 anchor → 锚点键移除（OFFSET 路径）
        XCTAssertNil(vm.anchors[2])
        // 满页推断：1 < 3 → 没有更多
        XCTAssertFalse(vm.hasMore)
    }

    // MARK: 非 append（筛选/排序/跳页）清空锚点（NA-34）

    @MainActor
    func testAnchorsClearedOnFilterChange() async {
        let src = MockSource()
        src.responses = [
            page(["m1"], anchor: ["k1"]),
            page(["m2"], anchor: ["k2"]),
            page(["m3"], anchor: nil),
        ]
        let vm = makeVM(src)
        vm.per = 1
        await vm.reload()
        await vm.loadNext()
        XCTAssertEqual(vm.anchors.count, 2)   // anchors[1]/anchors[2]
        await vm.setFilter { $0.year = "2024" }
        XCTAssertTrue(vm.anchors.isEmpty)
        XCTAssertEqual(vm.page, 1)
    }

    // MARK: append 按 id 去重

    @MainActor
    func testAppendDedupById() async {
        let src = MockSource()
        let first = (1...40).map { "m\($0)" }
        let second = Array(21...60).map { "m\($0)" }   // 20 重复 + 20 新增
        src.responses = [page(first), page(second)]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertEqual(vm.items?.count, 40)
        await vm.loadNext()
        XCTAssertEqual(vm.items?.count, 60)   // 去重后拼接
        XCTAssertEqual(src.seenPages.last, 2)
        XCTAssertEqual(vm.page, 2)
    }

    // MARK: 追加软上限 500（NA-22）

    @MainActor
    func testLoadNextSoftCap500() async {
        let src = MockSource()
        src.responses = [page(Array(0..<500).map { "m\($0)" })]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertEqual(vm.items?.count, 500)
        XCTAssertTrue(vm.hasMore)   // 满页仍推断有更多
        await vm.loadNext()
        XCTAssertEqual(src.calls, 1)   // 已加载 ≥500 → 不再追加（只能跳页）
        XCTAssertEqual(BrowseVM.MAX_MERGED_ITEMS, 500)
    }

    // MARK: loadNext 守卫

    @MainActor
    func testLoadNextGuards() async {
        let src = MockSource()
        let vm = makeVM(src)
        await vm.loadNext()   // items == nil（未首载）→ no-op
        XCTAssertEqual(src.calls, 0)
        src.responses = [page(Array(0..<10).map { "m\($0)" })]
        await vm.reload()
        XCTAssertFalse(vm.hasMore)   // 10 < 40
        await vm.loadNext()          // !hasMore → no-op
        XCTAssertEqual(src.calls, 1)
    }

    // MARK: hasMore 满页推断（铁律 20：total 未知也能翻页）

    @MainActor
    func testHasMoreFullPageInference() async {
        let src = MockSource()
        src.responses = [
            page(Array(0..<40).map { "m\($0)" }, total: -1),
            page(["x"], total: -1),
        ]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertTrue(vm.hasMore)   // total=-1 仍可翻页
        await vm.loadNext()
        XCTAssertFalse(vm.hasMore)   // 1 < 40
        XCTAssertEqual(vm.items?.count, 41)
        XCTAssertEqual(vm.total, 0)   // total=-1 = 未知 → 保持初值不回退
    }

    // MARK: goPage 钳制 + Toast（PaginationGuard）

    @MainActor
    func testGoPageClampToastKeepPage() async {
        let src = MockSource()
        let toasts = ToastBox()
        let vm = makeVM(src, MockCache(), toasts)
        vm.total = 5000
        await vm.goPage(9999)
        XCTAssertEqual(vm.page, 125)   // min(ceil(5000/40), 5000/40)
        XCTAssertEqual(toasts.list, ["跳页过深（最多约 125 页），请用滚动加载"])
        // keepPage：钳制后的页码直接进入重查（NA-01）
        XCTAssertEqual(src.seenPages.last, 125)
    }

    @MainActor
    func testGoPageUnknownTotalCapNoToast() async {
        let src = MockSource()
        let toasts = ToastBox()
        let vm = makeVM(src, MockCache(), toasts)
        // total 未知（0）→ 硬帽 125 页
        await vm.goPage(2)
        XCTAssertEqual(vm.page, 2)
        XCTAssertTrue(toasts.list.isEmpty)   // 未钳制 → 无 Toast
        await vm.goPage(9999)
        XCTAssertEqual(vm.page, 125)
        XCTAssertEqual(toasts.list, ["跳页过深（最多约 125 页），请用滚动加载"])
        // p<1 → 1（钳制但 p<=1 → 无 Toast）
        await vm.goPage(0)
        XCTAssertEqual(vm.page, 1)
        XCTAssertEqual(toasts.list.count, 1)
    }

    // MARK: applyFilters 反查入口（sortOverride 恒倒序）

    @MainActor
    func testApplyFiltersOverrideForcesDesc() async {
        let src = MockSource()
        let vm = makeVM(src)
        await vm.setSortAsc(true)
        XCTAssertEqual(vm.asc, true)
        await vm.applyFilters(Filters(year: "2024"), sortOverride: "score")
        XCTAssertEqual(vm.sort, "score")        // normSort 后覆盖
        XCTAssertFalse(vm.asc)                  // ⚠ 反查带排序恒倒序
        XCTAssertEqual(vm.f.year, "2024")
        XCTAssertEqual(vm.page, 1)
        XCTAssertEqual(src.seenSorts.last, "score")
        XCTAssertEqual(src.seenAscs.last, false)
    }

    @MainActor
    func testApplyFiltersNilKeepsSort() async {
        let src = MockSource()
        let vm = makeVM(src)
        await vm.setSort("score")
        XCTAssertEqual(vm.sort, "score")
        await vm.applyFilters(Filters(letter: "abp"))
        XCTAssertEqual(vm.sort, "score")        // 无 sortOverride → 保持当前排序
        XCTAssertEqual(vm.asc, false)
        XCTAssertEqual(vm.f.letter, "abp")
    }

    // MARK: rid 竞态守卫（旧响应一律丢弃）

    @MainActor
    func testRidDropsStaleResponse() async {
        let src = MockSource()
        src.delays = [150, 0]
        src.responses = [page(["a1", "a2"]), page(["b1"])]
        let vm = makeVM(src)
        let first = Task { await vm.reload() }
        try? await Task.sleep(nanoseconds: 30_000_000)   // 让请求 1 挂起
        await vm.applyFilters(Filters(year: "2024"))     // 请求 2（快）
        _ = await first.result                            // 等慢响应回来（应被丢弃）
        XCTAssertEqual(vm.items?.map { $0.s("id") }, ["b1"])
        XCTAssertEqual(vm.f.year, "2024")
        XCTAssertEqual(vm.page, 1)
        XCTAssertNil(vm.error)
    }

    // MARK: total<0 不回退已到达的计数

    @MainActor
    func testTotalNegativeDoesNotRegress() async {
        let src = MockSource()
        src.responses = [page(["m1"], total: 120), page(["m2"], total: -1)]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertEqual(vm.total, 120)
        await vm.loadNext()
        XCTAssertEqual(vm.total, 120)   // 第 2 页 total=-1 → 保留
    }

    // MARK: 首屏异步计数（bcount 缓存 + 失败 -1 不写）

    @MainActor
    func testAsyncCountFillsTotalAndCaches() async {
        let src = MockSource()
        let cache = MockCache()
        src.responses = [page(["m1"], total: -1)]
        src.countValue = 87
        let vm = makeVM(src, cache)
        await vm.reload()
        XCTAssertEqual(vm.total, 87)
        // 计数缓存键 bcount:{f}:{sort} 已落
        XCTAssertNotNil(cache.store[BrowseVM.countCacheKey(f: Filters(), sort: "release_date")])
        // 计数失败 -1 → 保持「已加载 N 条」（total 不被 -1 覆盖）
        src.countValue = -1
        cache.now += 6 * 60_000   // 计数 TTL 5 分钟过期
        await vm.applyFilters(Filters(year: "2024"))
        XCTAssertNil(cache.store[BrowseVM.countCacheKey(f: Filters(year: "2024"), sort: "release_date")])
        XCTAssertEqual(vm.total, 87)
    }

    // MARK: TTL 缓存命中 / 过期（键含 asc）

    @MainActor
    func testCacheHitWithinTtlThenExpiry() async {
        let src = MockSource()
        let cache = MockCache()
        src.responses = [page(["m1"])]
        let vm = makeVM(src, cache)
        await vm.reload()
        XCTAssertEqual(src.calls, 1)
        await vm.reload()   // 同键 TTL 内 → 命中缓存，不发查询
        XCTAssertEqual(src.calls, 1)
        XCTAssertEqual(vm.items?.count, 1)
        cache.now += 61 * 60_000   // filterTtl 默认 60 分钟
        await vm.reload()
        XCTAssertEqual(src.calls, 2)
    }

    @MainActor
    func testAscKeysCachedSeparately() async {
        let src = MockSource()
        let cache = MockCache()
        let vm = makeVM(src, cache)
        await vm.reload()               // asc=false → key1
        await vm.setSortAsc(true)       // asc=true → key2（不互读）
        XCTAssertEqual(src.calls, 2)
        XCTAssertEqual(src.seenAscs.last, true)
        let f = Filters()
        XCTAssertNotNil(cache.store[
            BrowseVM.listCacheKey(f: f, sort: "release_date", asc: false, per: 40, page: 1)])
        XCTAssertNotNil(cache.store[
            BrowseVM.listCacheKey(f: f, sort: "release_date", asc: true, per: 40, page: 1)])
    }

    // MARK: stale 回退（SWR：错误时上旧缓存，不写 error）

    @MainActor
    func testStaleFallbackOnError() async {
        let src = MockSource()
        src.errors = [QRuntimeError("远程库不可达：mock down")]
        let cache = MockCache()
        let vm = makeVM(src, cache)
        let key = BrowseVM.listCacheKey(f: Filters(), sort: "release_date", asc: false, per: 40, page: 1)
        cache.store[key] = (page(["old1"]), 0)   // 早已过期的旧缓存
        await vm.reload()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.items?.first?.s("id"), "old1")
        XCTAssertFalse(vm.loading)
    }

    // MARK: RefreshResult 仅手动下拉路径写入（C.6）

    @MainActor
    func testRefreshResultOnlyOnManualPull() async {
        let src = MockSource()
        let cache = MockCache()
        src.responses = [page(["m1", "m2", "m3", "m4"])]
        let vm = makeVM(src, cache)
        // 筛选变化不写
        await vm.setFilter { $0.year = "2024" }
        XCTAssertNil(vm.refreshChannel.value)
        // 手动下拉成功 → Done(n)（n = 合并后总条数）
        src.responses.append(page(["m1", "m2", "m3", "m4"]))
        cache.store.removeAll()   // 绕开 TTL 缓存命中，走实查
        await vm.refresh()
        if case .done(let n)? = vm.refreshChannel.value {
            XCTAssertEqual(n, 4)
            XCTAssertEqual(vm.refreshChannel.value?.toastText, "✓ 刷新完成 · 共 4 条")
        } else {
            XCTFail("refresh 应写 Done(4)")
        }
        vm.refreshChannel.consume()
        XCTAssertNil(vm.refreshChannel.value)
        // 手动下拉失败（无 stale）→ Fail(ErrText)
        src.errors = [nil, nil, QRuntimeError("mock down")]   // 第 3 次调用抛错
        cache.store.removeAll()
        await vm.refresh()
        if case .fail(let msg)? = vm.refreshChannel.value {
            XCTAssertTrue(msg.hasPrefix("查询失败："))   // ErrText 非连接级兜底
            XCTAssertEqual(vm.refreshChannel.value?.toastText,
                           "刷新失败：\(String(msg.prefix(40)))")
        } else {
            XCTFail("refresh 失败应写 Fail(ErrText)")
        }
        XCTAssertNotNil(vm.error)
    }

    // MARK: filterCount + 反查摘要拼接（A.2 逐字）

    @MainActor
    func testFilterCountAndLookupSummary() {
        let f = Filters(year: "2024", letter: "abp", tags: "101,202", magnet: true, cnsub: true)
        XCTAssertEqual(BrowseVM.lookupSummary(f), "反查：番号:abp · 年份:2024 · 标签×2 · 有磁力 · 中字")
        let vm = makeVM(MockSource())
        vm.f = f
        XCTAssertEqual(vm.filterCount, 5)   // year/letter/tags 3 文本 + magnet/cnsub 2 开关
        // 类别条目不带值；「可播」「单体」「月份」「系列」「导演」「发行商」顺序逐字
        let g = Filters(month: "3", canPlay: true, single: true,
                        seriesId: "s1", directorId: "d1", publisherId: "p1")
        XCTAssertEqual(BrowseVM.lookupSummary(g),
                       "反查：系列 · 导演 · 发行商 · 月份:3 · 可播 · 单体")
        vm.f = g
        XCTAssertEqual(vm.filterCount, 6)
        XCTAssertNil(BrowseVM.lookupSummary(Filters()))
        // 「片商」不带值；cnsub 摘要「中字」
        XCTAssertEqual(BrowseVM.lookupSummary(Filters(maker: "m1", cnsub: true)), "反查：片商 · 中字")
    }

    // MARK: onDataEpoch 60s 冷却（C.2 / RefreshPolicy）

    @MainActor
    func testOnDataEpochCooldown() async {
        let src = MockSource()
        let cache = MockCache()
        let vm = makeVM(src, cache)
        var now: Int64 = 1_000_000
        vm.nowMs = { now }
        await vm.bind(dataEpoch: 1)   // 首次进入：seenEpoch 记 1 + loadFilters + reload
        XCTAssertEqual(src.calls, 1)
        await vm.onDataEpoch(1)       // v == seenEpoch → no-op（进入页面不刷）
        XCTAssertEqual(src.calls, 1)
        cache.store.removeAll()
        await vm.onDataEpoch(2)       // 允许（从未自动刷过）→ 静默刷新
        XCTAssertEqual(src.calls, 2)
        cache.store.removeAll()
        await vm.onDataEpoch(3)       // 冷却内（<60s）→ 打点 skip
        XCTAssertEqual(src.calls, 2)
        now += 61_000
        cache.store.removeAll()
        await vm.onDataEpoch(4)       // 冷却已过（≥60s）→ 刷新
        XCTAssertEqual(src.calls, 3)
        XCTAssertNil(vm.refreshChannel.value)   // auto=true 静默：不写 refreshResult
    }

    // MARK: setter 归一（normalizePer / setSort）

    @MainActor
    func testSetSortAndPerNormalize() async {
        let src = MockSource()
        let vm = makeVM(src)
        await vm.setSort("want")
        XCTAssertEqual(vm.sort, "want_watch_count")
        await vm.setSort("nonsense")
        XCTAssertEqual(vm.sort, "release_date")
        await vm.setPer(45)
        XCTAssertEqual(vm.per, 40)
        await vm.setPer(70)
        XCTAssertEqual(vm.per, 60)   // 并列取较小档
        await vm.setPer(20)
        XCTAssertEqual(vm.per, 20)
        // setViewMode 仅改 state 不发查询
        let before = src.calls
        vm.setViewMode(2)
        XCTAssertEqual(vm.viewMode, 2)
        XCTAssertEqual(src.calls, before)
        // tagQuery/tagMode 仅改 state
        vm.setTagQuery("巨乳")
        vm.setTagMode("all")
        XCTAssertEqual(vm.tagQuery, "巨乳")
        XCTAssertEqual(vm.tagMode, "all")
        XCTAssertEqual(src.calls, before)
    }

    // MARK: LookupVM（10 §6：payload 解码 / 默认 label / 独立 VM 恒倒序）

    @MainActor
    func testLookupDecodeFailAndDefaultLabel() {
        XCTAssertNil(LookupVM(payload: "%%%not-base64%%%").spec)
        XCTAssertNil(LookupVM(payload: "").spec)
        // 合法 base64 但非 JSON
        XCTAssertNil(LookupVM(payload: "YWJjZGVmZ2hpamtsbW5vcA").spec)
        let lvm = LookupVM(payload: "%%%not-base64%%%")
        XCTAssertEqual(lvm.label, "反查")   // 兜底 label
    }

    @MainActor
    func testLookupApplyOnceSortDesc() async {
        let spec = LookupSpec(
            filters: Filters(year: "2024"), label: "片商：SOD create", sort: "score")
        let payload = LookupCodec.encode(spec)
        XCTAssertEqual(LookupVM(payload: payload).label, "片商：SOD create")
        let src = MockSource()
        src.responses = [page(["m1"])]
        let bvm = BrowseVM(
            source: src, cache: MockCache(), taxonomyLoader: MockTaxonomyLoader(),
            marks: BrowseMarkSource.empty(), onToast: { _ in })
        let lvm = LookupVM(payload: payload, browseVM: bvm)
        await lvm.applyOnce()
        XCTAssertEqual(bvm.sort, "score")
        XCTAssertFalse(bvm.asc)   // 反查带排序恒倒序
        XCTAssertEqual(bvm.f.year, "2024")
        XCTAssertEqual(bvm.page, 1)
        // applyOnce 恒一次：重复调用不重查
        let calls = src.calls
        await lvm.applyOnce()
        XCTAssertEqual(src.calls, calls)
    }

    // MARK: ProductionTaxonomyLoader 纯函数段（filters → bundle；letter 行对位）

    func testProductionTaxonomyBundleFromFilters() {
        let fm: [String: Any] = [
            "years": [Row(["year": .string("2024"), "c": .int(5)])],
            "letters": [Row(["letter": .string("abp"), "c": .int(7)])],
            "makers": [Row(["id": .string("m1"), "name": .string("SOD"), "c": .int(9)])],
            "tags": [["id": "101", "name": "巨乳", "c": Int64(0)]],
        ]
        let b = ProductionTaxonomyLoader.bundleFromFilters(fm, source: "assets")
        XCTAssertEqual(b.source, "assets")
        XCTAssertEqual(b.years.first?.s("year"), "2024")
        XCTAssertEqual(b.codes.first?.s("name"), "abp")   // letters letter/c → id/name/c
        XCTAssertEqual(b.codes.first?.i("c"), 7)
        XCTAssertEqual(b.makers.first?.s("id"), "m1")
        XCTAssertEqual(b.tags.first?.s("id"), "101")
        XCTAssertEqual(b.tags.first?.s("name"), "巨乳")
        XCTAssertEqual(b.tags.first?.i("c"), 0)
    }

    // MARK: loadFilters 应用 bundle

    @MainActor
    func testLoadFiltersAppliesBundle() async {
        let src = MockSource()
        let vm = makeVM(src)
        await vm.loadFilters()
        XCTAssertEqual(vm.filterSource, "remote")   // MockTaxonomyLoader 默认 remote
        XCTAssertGreaterThanOrEqual(vm.years.count, 0)
    }

    // MARK: demo 假数据源（仅 DEBUG；与生产同一 BrowseDataSource 协议）

    #if DEBUG
    @MainActor
    func testDemoSourceThroughVM() async {
        let vm = BrowseVM(
            source: DemoBrowseDataSource(), cache: MockCache(),
            taxonomyLoader: MockTaxonomyLoader(), marks: BrowseMarkSource.empty(),
            onToast: { _ in })
        await vm.reload()
        XCTAssertGreaterThanOrEqual(vm.items?.count ?? 0, 1)
        XCTAssertGreaterThan(vm.total, 0)   // demo total 真值
        XCTAssertFalse(vm.approx)
        XCTAssertTrue(vm.hasMore)           // 132 部 / 每页 40 → 首页满页 → 满页推断有更多
        // 反查口径：字头过滤走通（number LIKE 'a%'）
        await vm.applyFilters(Filters(letter: "a"))
        XCTAssertGreaterThanOrEqual(vm.items?.count ?? 0, 1)
        for m in vm.items ?? [] {
            XCTAssertTrue(m.s("number").lowercased().hasPrefix("a"))
        }
        // 布尔开关走通：中字
        await vm.applyFilters(Filters(cnsub: true))
        XCTAssertGreaterThanOrEqual(vm.items?.count ?? 0, 0)
    }

    @MainActor
    func testDemoTaxonomyLoader() async {
        let b = await DemoTaxonomyLoader().load()
        XCTAssertEqual(b.source, "remote")
        XCTAssertGreaterThanOrEqual(b.years.count, 1)
        XCTAssertLessThanOrEqual(b.years.count, 40)
        XCTAssertGreaterThanOrEqual(b.codes.count, 1)
        XCTAssertLessThanOrEqual(b.codes.count, 3000)
        XCTAssertGreaterThanOrEqual(b.makers.count, 1)
        XCTAssertLessThanOrEqual(b.makers.count, 500)
        XCTAssertGreaterThanOrEqual(b.tags.count, 1)
        XCTAssertLessThanOrEqual(b.tags.count, 500)
    }
    #endif
}
