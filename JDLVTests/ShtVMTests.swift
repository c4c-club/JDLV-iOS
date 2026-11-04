import XCTest
import JDLVCore
@testable import JDLV

//
//  ShtVMTests.swift —— ShtVM 行为单测（14_vm_tests A.0/A.4 契约 + 09 C 节逐条）。
//
//  覆盖：缓存键含 semantic（A-19）/ 模式互斥（NA-06）/ 锚点三态（有/无 fuzzy|semantic/
//  append 也写 P5.3）/ goPage 清锚点 / append 按 tid 去重 / 500 软上限 / hasMore 满页推断 /
//  TTL 缓存命中不发网络 / rid 竞态丢弃 / 语义错误不进 stale / 其他异常 stale 回退 /
//  covers 非 append 替换 + append 合并（NA-22）/ covers 行内兜底（P3.8）/ 分类延后
//  （S11-P6：先列表后分类）/ loadCats force 跳缓存 / 首屏异步计数 / total<0 不回退 /
//  search 不 trim / 导出文件组装（C4 逐字格式）/ 导出 0 条 → nil / 语义未导入 Toast。
//
//  时钟/缓存/数据源/Toast/导出目录全部可注入 → 无网络、无磁盘依赖（导出走临时目录）。
//

final class ShtVMTests: XCTestCase {

    // MARK: - 测试假件

    /// 假数据源（@MainActor：与 VM 同域，行为确定；按调用序返回响应/错误/延迟）
    @MainActor
    private final class MockShtSource: ShtDataSource {
        /// 调用序事件（分类延后顺序断言用）
        var events: [String] = []
        private(set) var browseCalls = 0
        private(set) var seenQs: [String] = []
        private(set) var seenPages: [Int] = []
        private(set) var seenAnchors: [(String, String)?] = []
        private(set) var seenModes: [String] = []
        private(set) var seenSorts: [String] = []
        private(set) var seenHasMagnet: [Bool] = []
        var responses: [[String: Any]] = []
        var errors: [Error?] = []
        var delays: [Int] = []

        private(set) var countCalls = 0
        var countValue: Int64 = -1
        private(set) var catCalls = 0
        var catForceCalls = 0
        private(set) var exportCalls = 0
        var exportRows: [Row] = []
        var exportError: Error? = nil

        func shtBrowse(
            main: String, cat: String, type: String, q: String, hasMagnet: Bool,
            page: Int, per: Int, anchor: (String, String)?, mode: String, sort: String,
            cand: Int, threshold: Float
        ) async throws -> [String: Any] {
            events.append("browse")
            let idx = browseCalls
            browseCalls += 1
            seenQs.append(q)
            seenPages.append(page)
            seenAnchors.append(anchor)
            seenModes.append(mode)
            seenSorts.append(sort)
            seenHasMagnet.append(hasMagnet)
            if delays.count > idx, delays[idx] > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delays[idx]) * 1_000_000)
            }
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx] : Self.emptyPage
        }

        func shtBrowseCount(
            main: String, cat: String, type: String, q: String, hasMagnet: Bool, sort: String
        ) async -> Int64 {
            countCalls += 1
            return countValue
        }

        func shtCategories() async throws -> [String: Any] {
            events.append("cats")
            catCalls += 1
            if catForceCalls == 0 && catCalls > 0 { catForceCalls = catCalls }
            return [
                "categories": [Row](),
                "mains": [Row(["name": .string("有码中文字幕"), "c": .int(64)])],
                "subs": [Row(["main": .string("有码中文字幕"), "name": .string("有码原创"), "c": .int(32)])],
                "types": [Row(["sub": .string("有码原创"), "name": .string("高清"), "c": .int(16)])],
                "total": Int64(96), "approx": true, "ts": Int64(1_730_000_000_000),
            ]
        }

        func shtExport(
            main: String, cat: String, type: String, q: String,
            onRows: ([Row]) async -> Void
        ) async throws {
            exportCalls += 1
            if let e = exportError { throw e }
            await onRows(exportRows)
        }

        func shtThread(tid: String) async throws -> [String: Any]? { nil }

        static let emptyPage: [String: Any] = [
            "items": [Row](), "total": Int64(-1), "page": 1,
            "covers": [String: String](), "approx": true, "derived": "",
        ]
    }

    /// 假缓存（可控时钟：TTL 命中/过期/stale 全覆盖）
    private final class MockCache: ShtCacheStore {
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

    private final class ToastBox {
        var list: [String] = []
    }

    // MARK: 构造器

    /// 帖子行（tid/title/post_date/last_checked/cover_url/magnet_count）
    private func trows(
        _ tids: [String], date: String = "2024-01-01", checked: String = "2024-06-01 12:00",
        cover: String = ""
    ) -> [Row] {
        tids.map {
            Row([
                "tid": .string($0), "title": .string("帖\($0)"),
                "post_date": .string(date), "last_checked": .string(checked),
                "cover_url": .string(cover), "magnet_count": .int(1),
            ])
        }
    }

    private func page(
        _ tids: [String], covers: [String: String] = [:], total: Int64 = -1,
        derived: String = "", cover: String = "", checked: String = "2024-06-01 12:00"
    ) -> [String: Any] {
        [
            "items": trows(tids, checked: checked, cover: cover), "total": total,
            "page": 1, "covers": covers, "approx": true, "derived": derived,
        ]
    }

    @MainActor
    private func makeVM(
        _ source: MockShtSource, _ cache: MockCache = MockCache(), _ toasts: ToastBox = ToastBox()
    ) -> ShtVM {
        let vm = ShtVM(
            source: source, cache: cache, marks: ShtMarkSource.empty(),
            onToast: { toasts.list.append($0) })
        vm.catsDelayMs = 0            // 测试不等待分类延后窗口
        vm.semanticInstalled = { true }
        return vm
    }

    // MARK: 缓存键（A-19：必须含 semantic）

    @MainActor
    func testListCacheKeyContainsSemanticAndFuzzy() {
        let base = ShtVM.listCacheKey(
            main: "m", cat: "c", type: "t", q: "词 词2", hasMagnet: true,
            fuzzy: false, semantic: false, sort: "date", per: 20, page: 3)
        XCTAssertEqual(base, "sht_list:m:c:t:词 词2:true:false:false:date:20:3")
        // semantic 翻转 → 不同键（防「精确」与「语义」同键串味）
        let sem = ShtVM.listCacheKey(
            main: "m", cat: "c", type: "t", q: "词 词2", hasMagnet: true,
            fuzzy: false, semantic: true, sort: "date", per: 20, page: 3)
        XCTAssertNotEqual(base, sem)
        // fuzzy 翻转 → 不同键
        let fz = ShtVM.listCacheKey(
            main: "m", cat: "c", type: "t", q: "词 词2", hasMagnet: true,
            fuzzy: true, semantic: false, sort: "date", per: 20, page: 3)
        XCTAssertNotEqual(base, fz)
    }

    // MARK: mode 参数映射（C9）

    @MainActor
    func testModeOf() {
        XCTAssertEqual(ShtVM.modeOf(fuzzy: false, semantic: false), "exact")
        XCTAssertEqual(ShtVM.modeOf(fuzzy: true, semantic: false), "fuzzy")
        XCTAssertEqual(ShtVM.modeOf(fuzzy: false, semantic: true), "semantic")
        XCTAssertEqual(ShtVM.modeOf(fuzzy: true, semantic: true), "semantic")   // 语义优先
    }

    // MARK: 锚点取值（E3：orderColOf；空值回落 post_date）

    @MainActor
    func testAnchorOfOrderColumnAndFallback() {
        // sort=date → post_date 列
        let a = ShtVM.anchorOf(trows(["1", "2"]), sort: "date")
        XCTAssertEqual(a?.0, "2024-01-01")
        XCTAssertEqual(a?.1, "2")
        // sort=updated → last_checked 列
        let b = ShtVM.anchorOf(trows(["1", "2"]), sort: "updated")
        XCTAssertEqual(b?.0, "2024-06-01 12:00")
        XCTAssertEqual(b?.1, "2")
        // last_checked 空 → 回落 post_date
        let rows = trows(["9"]).map { r -> Row in
            var m = r
            m["last_checked"] = .string("")
            return m
        }
        let c = ShtVM.anchorOf(rows, sort: "updated")
        XCTAssertEqual(c?.0, "2024-01-01")
        // 空行 → nil
        XCTAssertNil(ShtVM.anchorOf([], sort: "date"))
    }

    // MARK: fetch 写锚点（非 append；缓存命中同路径）

    @MainActor
    func testFetchWritesAnchor() async {
        let src = MockShtSource()
        src.responses = [page(["1", "2", "3"])]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertEqual(vm.page, 1)
        XCTAssertEqual(vm.anchors[1]?.1, "3")   // 本页末行 tid
        XCTAssertEqual(vm.anchors[1]?.0, "2024-01-01")
    }

    // MARK: fuzzy/semantic 无锚点（E3）

    @MainActor
    func testNoAnchorInFuzzyMode() async {
        let src = MockShtSource()
        src.responses = [page(["1", "2"])]
        let vm = makeVM(src)
        await vm.toggleFuzzy()
        XCTAssertEqual(vm.fuzzy, true)
        XCTAssertEqual(vm.semantic, false)   // 互斥：开模糊关语义
        XCTAssertNil(vm.anchors[1])          // 模糊模式无锚点
        XCTAssertNil(src.seenAnchors.first ?? nil)   // 传给 Q 的 anchor 也是 nil
        XCTAssertEqual(src.seenModes.first, "fuzzy")
    }

    // MARK: append 也写锚点（P5.3：否则第二页后锚点丢失）

    @MainActor
    func testAppendWritesAnchorAndDedupes() async {
        let src = MockShtSource()
        src.responses = [page(["1", "2", "3", "4"]), page(["3", "4", "5"])]
        let vm = makeVM(src)
        vm.per = 4
        await vm.reload()
        await vm.loadNext()
        XCTAssertEqual(vm.page, 2)
        XCTAssertEqual(vm.items?.map { $0.s("tid") }, ["1", "2", "3", "4", "5"])   // tid 去重
        XCTAssertEqual(vm.anchors[2]?.1, "5")   // append 成功也写锚点
        XCTAssertEqual(src.seenPages, [1, 2])
        XCTAssertEqual(src.seenAnchors[1]?.1, "4")   // append 用当前页末行锚点查下一页
    }

    // MARK: goPage 清锚点 + keepPage（C9/E7）

    @MainActor
    func testGoPageClearsAnchors() async {
        let src = MockShtSource()
        src.responses = [page(["1", "2"]), page(["7", "8"])]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertNotNil(vm.anchors[1])
        await vm.goPage(2)
        XCTAssertEqual(vm.page, 2)
        XCTAssertEqual(vm.items?.map { $0.s("tid") }, ["7", "8"])
        // 旧页锚点已清；新页锚点由 apply 重建（给第 3 页用）
        XCTAssertNil(vm.anchors[1])
        XCTAssertEqual(vm.anchors[2]?.1, "8")
        // maxOf(1,p) 钳制
        await vm.goPage(-3)
        XCTAssertEqual(vm.page, 1)
    }

    // MARK: 500 追加软上限（E8）

    @MainActor
    func testMaxMergedItemsCap() async {
        let src = MockShtSource()
        let big = Array((1...500).map { String($0) })
        src.responses = [page(big)]
        let vm = makeVM(src)
        vm.per = 500
        await vm.reload()
        XCTAssertEqual(vm.items?.count, 500)
        await vm.loadNext()   // ≥500 → 直接 return
        XCTAssertEqual(src.browseCalls, 1)   // 未追加
        XCTAssertEqual(vm.page, 1)
    }

    // MARK: hasMore 满页推断（铁律 20：total 未知也能翻页）

    @MainActor
    func testHasMoreFullPageInference() async {
        let src = MockShtSource()
        src.responses = [page(["1", "2"]), page(["3"])]
        let vm = makeVM(src)
        vm.per = 2
        await vm.reload()
        XCTAssertEqual(vm.hasMore, true)      // 2 == per 满页
        await vm.loadNext()
        XCTAssertEqual(vm.hasMore, false)     // 1 < per 不满页
    }

    // MARK: TTL 缓存命中不发网络（C9：5 分钟）

    @MainActor
    func testCacheHitSkipsNetwork() async {
        let src = MockShtSource()
        let cache = MockCache()
        let vm = makeVM(src, cache)
        await vm.reload()
        XCTAssertEqual(src.browseCalls, 1)
        cache.put(
            ShtVM.listCacheKey(
                main: "", cat: "", type: "", q: "", hasMagnet: false, fuzzy: false,
                semantic: false, sort: "date", per: 20, page: 1),
            page(["9"]))
        await vm.reload()
        XCTAssertEqual(src.browseCalls, 1)    // 仍 1 次 → 命中缓存
        XCTAssertEqual(vm.items?.first?.s("tid"), "9")
    }

    // MARK: rid 竞态：旧响应晚到整体丢弃（A.0）

    @MainActor
    func testRidRaceDiscardsStaleResponse() async {
        let src = MockShtSource()
        src.delays = [60, 0]
        src.responses = [page(["old"]), page(["new"])]
        let vm = makeVM(src)
        let slow = Task { await vm.reload() }    // 慢请求在飞
        try? await Task.sleep(nanoseconds: 5_000_000)
        await vm.reload()                        // 新请求先回
        await slow.value
        XCTAssertEqual(vm.items?.first?.s("tid"), "new")   // 旧响应不覆盖
        XCTAssertEqual(vm.page, 1)
    }

    // MARK: 语义模型未导入 = 明确业务态：不进 stale 兜底（A.4）

    @MainActor
    func testSemanticErrorDoesNotFallbackToStale() async {
        let src = MockShtSource()
        src.errors = [SemanticUnavailableError("语义模型未导入或加载失败 — 请到 设置 → 语义搜索模型 导入")]
        let cache = MockCache()
        let key = ShtVM.listCacheKey(
            main: "", cat: "", type: "", q: "", hasMagnet: false, fuzzy: false,
            semantic: true, sort: "date", per: 20, page: 1)
        // 注：fetch 首步是 TTL 缓存命中；预置语义键会让用例到不了 error 分支 → 不预置
        let vm = makeVM(src, cache)
        // toggleSemantic 有"未安装模型"门禁（NA-06）；此处直测 fetch 的语义分支防御
        vm.semantic = true
        vm.fuzzy = false
        await vm.refetch()
        XCTAssertEqual(vm.error, "语义模型未导入或加载失败 — 请到 设置 → 语义搜索模型 导入")
        XCTAssertNil(vm.items)   // stale 可用但不应用
        // 默认兜底文案
        XCTAssertEqual(ShtVM.semanticMessage(SemanticUnavailableError()), "语义模型未导入")
    }

    // MARK: 其他异常 → stale 回退 → 无 stale 才 ErrText（A.0 SWR）

    @MainActor
    func testStaleFallbackThenError() async {
        let src = MockShtSource()
        src.errors = [QRuntimeError("db down"), QRuntimeError("db down again")]
        let cache = MockCache()
        let vm = makeVM(src, cache)
        // 第一发失败（无 stale）→ error
        await vm.reload()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.items)
        // 有 stale → SWR 渲染旧数据不进错误态
        cache.put(
            ShtVM.listCacheKey(
                main: "", cat: "", type: "", q: "", hasMagnet: false, fuzzy: false,
                semantic: false, sort: "date", per: 20, page: 1),
            page(["cached"]))
        await vm.reload()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.items?.first?.s("tid"), "cached")
    }

    // MARK: covers：非 append 替换整张（NA-22 防旧 tid 残留）/ append 合并

    @MainActor
    func testCoversReplaceOnReloadMergeOnAppend() async {
        let src = MockShtSource()
        let cache = MockCache()
        src.responses = [
            page(["1", "2"], covers: ["1": "u1", "2": "u2"]),
            page(["3"], covers: ["3": "u3"]),
        ]
        let vm = makeVM(src, cache)
        vm.per = 2
        await vm.reload()
        XCTAssertEqual(vm.covers, ["1": "u1", "2": "u2"])
        await vm.loadNext()
        XCTAssertEqual(vm.covers, ["1": "u1", "2": "u2", "3": "u3"])   // 追加合并
        cache.store.removeAll()   // 绕开缓存命中，实查走空 covers 响应
        await vm.reload()         // 非 append（响应 covers 为空 map）→ 替换整张
        XCTAssertEqual(vm.covers, [:])   // 空 map 且行无 cover_url → 整张清空
    }

    // MARK: covers 行内兜底（P3.8：响应 covers 为空时用 cover/cover_url 填 map）

    @MainActor
    func testCoversFallbackFromItems() async {
        let src = MockShtSource()
        src.responses = [page(["1", "2"], cover: "https://sht.example/x.jpg")]
        let vm = makeVM(src)
        await vm.reload()
        XCTAssertEqual(vm.covers["1"], "https://sht.example/x.jpg")
        XCTAssertEqual(vm.covers["2"], "https://sht.example/x.jpg")
        // shtCoverUrl：非 http → 空（静态占位）
        XCTAssertEqual(ShtVM.shtCoverUrl(""), "")
        XCTAssertEqual(ShtVM.shtCoverUrl("covers/a.jpg"), "")
    }

    // MARK: 分类延后（S11-P6：先列表落地，再 loadCats）

    @MainActor
    func testCategoriesLoadAfterFirstScreen() async {
        let src = MockShtSource()
        let vm = makeVM(src)
        await vm.bind(dataEpoch: 0)
        XCTAssertEqual(src.events, ["browse", "cats"])   // 列表先、分类后
        XCTAssertEqual(vm.items?.count, 0)
        XCTAssertEqual(vm.mains.first?.s("name"), "有码中文字幕")
        XCTAssertEqual(vm.catTs, 1_730_000_000_000)
        // 二次 bind 不再刷列表/分类（非首次只同步设置）
        await vm.bind(dataEpoch: 0)
        XCTAssertEqual(src.browseCalls, 1)
        XCTAssertEqual(src.catCalls, 1)
    }

    // MARK: loadCats：24h 缓存命中 / force 跳缓存（C8）

    @MainActor
    func testLoadCatsCacheAndForce() async {
        let src = MockShtSource()
        let cache = MockCache()
        let vm = makeVM(src, cache)
        await vm.loadCats(force: false)
        XCTAssertEqual(src.catCalls, 1)   // miss → 远程
        cache.now += 60 * 1000            // 1 分钟后：仍在 24h TTL 内
        await vm.loadCats(force: false)
        XCTAssertEqual(src.catCalls, 1)   // 命中缓存
        await vm.loadCats(force: true)
        XCTAssertEqual(src.catCalls, 2)   // force 直接远程
    }

    // MARK: 首屏异步计数（A.4：Q.shtBrowseCount）

    @MainActor
    func testCountAsyncFirstScreenOnly() async {
        let src = MockShtSource()
        src.responses = [page(["1"]), page(["1", "2"])]
        src.countValue = 42
        let vm = makeVM(src)
        vm.per = 2
        await vm.reload()
        XCTAssertEqual(vm.total, 42)
        await vm.loadNext()   // append 不计数
        XCTAssertEqual(src.countCalls, 1)
    }

    // MARK: total<0 不回退已异步到达的计数（A.0）

    @MainActor
    func testTotalUnknownDoesNotRollback() async {
        let src = MockShtSource()
        let cache = MockCache()
        src.responses = [page(["1"], total: -1)]
        src.countValue = 77
        let vm = makeVM(src, cache)
        await vm.reload()
        XCTAssertEqual(vm.total, 77)
        cache.store.removeAll()   // 绕开缓存命中，实查 total=-1
        await vm.refresh()        // 新响应 total=-1 → 保留 77
        XCTAssertEqual(vm.total, 77)
    }

    // MARK: search 不 trim（C2：Q 层自行 trim）

    @MainActor
    func testSearchPassesQueryUntrimmed() async {
        let src = MockShtSource()
        let vm = makeVM(src)
        await vm.search("  tid123  ")
        XCTAssertEqual(vm.queryState, "  tid123  ")   // 原样入 state
        XCTAssertEqual(src.seenQs.first, "  tid123  ")
        // queryState 单向数据流：唯一写点 setQuery
        vm.setQuery("abc")
        XCTAssertEqual(vm.queryState, "abc")
    }

    // MARK: 模式互斥 + 未导入语义模型 Toast（C5）

    @MainActor
    func testToggleSemanticGatedByInstalledModel() async {
        let src = MockShtSource()
        let toasts = ToastBox()
        let vm = makeVM(src, MockCache(), toasts)
        vm.semanticInstalled = { false }
        var openedSettings = false
        vm.onOpenSettings = { openedSettings = true }
        await vm.toggleSemantic()
        XCTAssertEqual(vm.semantic, false)   // 不切换（不静默降级）
        XCTAssertTrue(vm.items == nil || vm.items?.isEmpty == true)   // 未发查询
        XCTAssertEqual(src.browseCalls, 0)
        XCTAssertEqual(toasts.list, ["未导入语义模型 — 请到 设置 → 语义搜索模型 导入"])
        XCTAssertEqual(openedSettings, true)
        // 已导入 → 切换成功且与模糊互斥
        vm.semanticInstalled = { true }
        vm.fuzzy = true
        await vm.toggleSemantic()
        XCTAssertEqual(vm.semantic, true)
        XCTAssertEqual(vm.fuzzy, false)
    }

    // MARK: toggleFuzzy 互斥 + 清锚点 + reload（NA-06）

    @MainActor
    func testToggleFuzzyMutexClearsAnchorsAndReloads() async {
        let src = MockShtSource()
        src.responses = [page(["1"]), page(["2"])]
        let vm = makeVM(src)
        vm.semantic = true
        await vm.toggleFuzzy()
        XCTAssertEqual(vm.fuzzy, true)
        XCTAssertEqual(vm.semantic, false)   // 开模糊关语义
        XCTAssertEqual(src.browseCalls, 1)   // toggle 即重查（NA-06）
        XCTAssertEqual(vm.page, 1)
    }

    // MARK: filterCount（C3：main/cat/type 非空 + hasMagnet）

    @MainActor
    func testFilterCount() {
        let src = MockShtSource()
        let vm = ShtVM(source: src, cache: MockCache(), marks: ShtMarkSource.empty(),
                       onToast: { _ in })
        XCTAssertEqual(vm.filterCount, 0)
        vm.main = "有码"
        vm.cat = "有码原创"
        vm.type = "高清"
        vm.hasMagnet = true
        XCTAssertEqual(vm.filterCount, 4)
    }

    // MARK: 导出文件组装（C4 格式逐字；临时目录）

    @MainActor
    func testExportFileAssemblyVerbatim() async {
        let src = MockShtSource()
        src.exportRows = [
            Row(["tid": .string("300001"), "title": .string("演示帖一"),
                 "date": .string("2024-05-01"), "kind": .string("磁力"),
                 "link": .string("magnet:?xt=urn:btih:abc"), "size": .string("734")]),
            Row(["tid": .string("300001"), "title": .string("演示帖一"),
                 "date": .string("2024-05-01"), "kind": .string("ED2K"),
                 "link": .string("ed2k://|file|x"), "size": .string("1024")]),
            Row(["tid": .string("300002"), "title": .string("演示帖二"),
                 "date": .string("2024-05-02"), "kind": .string("视频"),
                 "link": .string("https://v/1"), "size": .null]),
        ]
        let toasts = ToastBox()
        let vm = makeVM(src, MockCache(), toasts)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sht_export_test_\(UUID().uuidString)", isDirectory: true)
        vm.exportDirectory = { dir }
        vm.nowMs = { 1_730_000_000_123 }
        vm.main = "有码"
        vm.cat = "有码原创"
        vm.type = "高清"
        vm.setQuery("搜索词")
        let res = await vm.exportLinks()
        XCTAssertNotNil(res)
        XCTAssertEqual(res?.count, 3)
        let text = try! String(contentsOf: res!.url, encoding: .utf8)
        // 首行（半角冒号）+ 有搜索词追加「 搜索=」
        XCTAssertTrue(text.hasPrefix("# 导出: 主版=有码 副版=有码原创 类型=高清 搜索=搜索词\n"))
        // 帖头（tid 变化时）
        XCTAssertTrue(text.contains("\n[2024-05-01] 演示帖一\n"))
        XCTAssertTrue(text.contains("\n[2024-05-02] 演示帖二\n"))
        // 链接行：kind: link (size)；size 空 → 无括号
        XCTAssertTrue(text.contains("磁力: magnet:?xt=urn:btih:abc (734)\n"))
        XCTAssertTrue(text.contains("ED2K: ed2k://|file|x (1024)\n"))
        XCTAssertTrue(text.contains("视频: https://v/1\n"))
        // 成功 Toast 逐字
        XCTAssertEqual(toasts.list, ["✓ 已导出 3 条链接"])
        // 清理
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: 导出 0 条 → nil + Toast（C4.3）/ 异常 → 「导出失败:」（C4.4 半角冒号）

    @MainActor
    func testExportEmptyAndError() async {
        let src = MockShtSource()
        let toasts = ToastBox()
        let vm = makeVM(src, MockCache(), toasts)
        vm.exportDirectory = {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("sht_export_test_\(UUID().uuidString)", isDirectory: true)
        }
        // 0 条
        let res = await vm.exportLinks()
        XCTAssertNil(res)
        XCTAssertEqual(toasts.list.last, "导出失败或无数据")
        // 异常
        src.exportError = QRuntimeError("boom")
        let res2 = await vm.exportLinks()
        XCTAssertNil(res2)
        XCTAssertEqual(toasts.list.last, "导出失败: boom")   // 半角冒号
        // 文案纯函数
        XCTAssertEqual(
            ShtExportComposer.linkLine(kind: "磁力", link: "magnet:?xt=urn:btih:h", size: ""),
            "磁力: magnet:?xt=urn:btih:h\n")
    }

    // MARK: 详情解析（D3/D4/D5 三分支 + D8 兜底）

    @MainActor
    func testThreadDataParseBranches() {
        // 小说区 + blocks → ReaderBody
        let lit = ShtThreadData.parse(
            [
                "title": "小说", "board_name": "原创小说", "post_date": "2024-01-01",
                "cat_name": "小说文学区", "words": 300,
                "magnets": [[String: Any]](), "images": [Any](), "videos": [Any](),
                "blocks": [["t": "第一段", "sz": 0]],
            ], tid: "1")
        XCTAssertTrue(lit.isLiterature)
        XCTAssertTrue(lit.useReaderBody)
        XCTAssertFalse(lit.needsEmptyFallback)
        // 自拍图片区有图 → 图片贴分支（不进 Reader）
        let img = ShtThreadData.parse(
            [
                "title": "图贴", "cat_name": "自拍图片区", "images": ["a.jpg"],
                "magnets": [[String: Any]](), "videos": [Any](), "blocks": [[String: Any]](),
            ], tid: "2")
        XCTAssertTrue(img.isImagePost)
        XCTAssertFalse(img.useReaderBody)
        // 全空非文学 → 空信息兜底
        let bare = ShtThreadData.parse(
            [
                "title": "裸帖", "cat_name": "有码中文字幕",
                "magnets": [[String: Any]](), "images": [Any](), "videos": [Any](),
                "blocks": [[String: Any]](),
            ], tid: "3")
        XCTAssertTrue(bare.needsEmptyFallback)
        // 磁力解析 + 空 link 回落 + fmtSize 角标
        let mag = ShtThreadData.parse(
            [
                "title": "t", "cat_name": "x",
                "magnets": [["hash": "abc", "name": "n", "size": "734", "link": ""]],
                "images": [Any](), "videos": [Any](), "blocks": [[String: Any]](),
            ], tid: "4")
        XCTAssertEqual(mag.magnets.first?.displayLink, "magnet:?xt=urn:btih:abc")
        XCTAssertEqual(Fmt.fmtSize("2048"), "2 GB")
        // 元信息行（D4：非空项 " · " 连接）
        XCTAssertEqual(lit.metaLine, "原创小说 · 2024-01-01")
    }
}
