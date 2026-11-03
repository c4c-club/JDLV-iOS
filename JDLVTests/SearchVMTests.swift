import XCTest
@testable import JDLV
import JDLVCore

//
//  SearchVMTests.swift —— SearchVm 全契约逻辑测试（14_vm_tests.md A.0/A.6 iOS 等价补齐；
//  文档 §C.移植注意 4：VM 层行为 iOS 侧新增 ViewModel 级测试）。
//
//  覆盖：PaginationGuard 接入（跳页钳制+toast）、mode/scope 切换重搜、缓存键隔离与 TTL、
//  本地索引优先路由（served=local / 0 命中回落远程文案 / 离线空态 / 异常回落）、rid 竞态、
//  fetchCount 双保险（-1 不回退已到计数、迟到计数不覆盖）、hasMore 满页、loadNext 同源翻页
//  与 append 去重、loadHome stale-then-refresh 三级、RefreshResult 协议、bind/setMode、
//  搜索历史、demo 模式全链路（DemoSearchData + JdbSearch.idx 注入）。
//
//  数据协议假实现：FakeSearchData（SearchData）/ FakeSettings（SearchSettingsReading）/
//  FakeIdx（IdxSearchable 注入 JdbSearch.idx）；缓存/时钟全部注入，用例间互不污染。
//

// MARK: - 假实现（文件作用域：不得嵌套在 @MainActor 类内 —— 嵌套类型会继承
// MainActor 隔离，导致 FakeIdx 无法满足非隔离的同步协议 IdxSearchable）

/// SearchData 假实现：门（一次性）驱动的竞态/时序测试
private final class FakeSearchData: SearchData {
    var homeResult = SearchHomeResult(recent: [], hot: [], top: [], derived: "")
    var homeError: Error?
    var searchResult = SearchPageResult(items: [], derived: "", served: "remote")
    var resultsByPage: [Int: SearchPageResult] = [:]
    var searchError: Error?
    var countResult: Int64 = -1

    private(set) var homeCalls = 0
    private(set) var searchCalls = 0
    private(set) var countCalls = 0
    private(set) var lastHomePer: Int?
    private(set) var lastSearchQ: String?
    private(set) var lastSearchScope: String?
    private(set) var lastSearchPage: Int?
    private(set) var lastSearchPer: Int?
    private(set) var lastSearchMode: String?

    var gateFirstHome = false
    var gateFirstSearch = false
    var gateFirstCount = false
    private var homeGate: CheckedContinuation<Void, Never>?
    private var searchGate: CheckedContinuation<Void, Never>?
    private var countGate: CheckedContinuation<Void, Never>?

    func home(per: Int) async throws -> SearchHomeResult {
        homeCalls += 1
        lastHomePer = per
        if gateFirstHome {
            gateFirstHome = false
            await withCheckedContinuation { homeGate = $0 }
        }
        if let e = homeError { throw e }
        return homeResult
    }

    func search(q: String, scope: String, page: Int, per: Int, mode: String) async throws -> SearchPageResult {
        searchCalls += 1
        lastSearchQ = q
        lastSearchScope = scope
        lastSearchPage = page
        lastSearchPer = per
        lastSearchMode = mode
        if gateFirstSearch {
            gateFirstSearch = false
            await withCheckedContinuation { searchGate = $0 }
        }
        if let e = searchError { throw e }
        return resultsByPage[page] ?? searchResult
    }

    func searchCount(q: String, scope: String) async -> Int64 {
        countCalls += 1
        if gateFirstCount {
            gateFirstCount = false
            await withCheckedContinuation { countGate = $0 }
        }
        return countResult
    }

    func releaseHome() { homeGate?.resume(); homeGate = nil }
    func releaseSearch() { searchGate?.resume(); searchGate = nil }
    func releaseCount() { countGate?.resume(); countGate = nil }
}

private final class FakeSettings: SearchSettingsReading {
    var searchHomeTtl = 10
    var searchHomePer = 24
    var searchPerPage = 40
    var searchModeRaw = 1
    var searchViewMode = 0
    var searchSetupRequired = false
}

/// IdxSearchable 假实现（注入 JdbSearch.idx；offset 分页可测同源翻页）
private final class FakeIdx: IdxSearchable {
    var ready = true
    var rows: [Row] = []
    var throwOnSearch = false

    func localReady() -> Bool { ready }
    func countOf(table: String) throws -> Int64 { Int64(rows.count) }
    func countActors() throws -> Int64 { 0 }
    func searchMovies(q: String, scope: String, per: Int, offset: Int) throws -> [Row] {
        if throwOnSearch { throw NSError(domain: "test.idx", code: 1) }
        let s = max(0, offset)
        guard s < rows.count else { return [] }
        return Array(rows[s..<min(s + per, rows.count)])
    }
    func countMovies(q: String, scope: String) throws -> Int64 { Int64(rows.count) }
    func searchActorMovies(q: String, page: Int, per: Int) throws -> [Row] { [] }
    func countActorMovies(q: String) throws -> Int64 { 0 }
    func searchMoviesByTag(tagId: String, limit: Int, offset: Int) throws -> [Row] { [] }
    func countMoviesByTag(tagId: String) throws -> Int64 { 0 }
    func threadById(tid: String) throws -> Row? { nil }
    func searchThreads(q: String, board: String, boardName: String, type: String,
                       hasMagnet: Bool, limit: Int, offset: Int) throws -> [Row] { [] }
    func threadsBy(sort: String, asc: Bool, limit: Int, offset: Int) throws -> [Row] { [] }
}

/// 注入时钟
private final class ClockBox {
    var now: Int64 = 1_000_000
}

@MainActor
final class SearchVMTests: XCTestCase {

    // MARK: - 工具

    private func movieRow(_ id: String, number: String = "") -> Row {
        Row(["id": .string(id), "number": .string(number),
             "title": .string("标题 \(id)"), "release_date": .string("2026-01-01")])
    }

    private func rows(_ range: ClosedRange<Int>) -> [Row] {
        range.map { movieRow("\($0)") }
    }

    private func makeVM(data: FakeSearchData,
                        cache: SearchMemCache? = nil,
                        clock: ClockBox = ClockBox(),
                        isOnline: @escaping () -> Bool = { true },
                        idx: FakeIdx? = nil) -> SearchVM {
        JdbSearch.idx = idx
        return SearchVM(
            data: data,
            cache: cache ?? SearchMemCache(now: { clock.now }),
            isOnline: isOnline,
            clock: { clock.now })
    }

    /// 轮询等待（主 actor 挂起让路，VM 的非结构化 Task 得以推进）
    private func waitUntil(_ timeout: TimeInterval = 2,
                           _ cond: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    private func releaseIdx() {
        JdbSearch.idx = nil
    }

    // MARK: - 逐字文案（硬性要求：文案逐字）

    func test_copyVerbatim() {
        XCTAssertEqual(SearchCopy.searchPlaceholder, "番号 / 标题 / 女优 / 标签…")
        XCTAssertEqual(SearchCopy.swrNote, "◌ 正在显示缓存数据, 后台刷新中…")
        XCTAssertEqual(SearchCopy.offlineHomeNote, "⚠ 离线: 正在显示缓存的首页数据")
        XCTAssertEqual(SearchCopy.localMissNote, "本地无结果，正在查远程…")   // 全角逗号
        XCTAssertEqual(SearchCopy.remoteNote, "远程全库")
        XCTAssertEqual(SearchCopy.offlineSearchNote, "⚠ 离线: 显示缓存搜索结果")
        XCTAssertEqual(SearchCopy.emptyTextIdle, "输入关键词开始搜索")
        XCTAssertEqual(SearchCopy.emptyResult("ABC-1"), "未找到 “ABC-1” 相关结果")   // 弯引号原样
        XCTAssertEqual(SearchCopy.emptyResultHint, "试试更短的关键词, 或切换搜索范围/匹配模式")   // 半角逗号+空格
        XCTAssertEqual(SearchCopy.emptyHomeSection, "远程库暂无该数据 (需抓取端上传)")   // 半角括号
        XCTAssertEqual(SearchCopy.exactScopeNote, "精确匹配 · 已限定最近 5000 部内")
        XCTAssertEqual(AppCopy.tooDeepToast(maxPage: 3), "跳页过深（最多约 3 页），请用滚动加载")   // 全角括号+全角逗号
        XCTAssertEqual(SearchCopy.setupTitle, "首次使用 · 请先配置数据源")
        XCTAssertEqual(SearchCopy.setupAction, "去设置")
        XCTAssertEqual(SearchCopy.welcomeTitle, "👋 欢迎使用 JDLV Mobile")
        XCTAssertEqual(SearchCopy.welcomeAction, "去设置数据源")
        XCTAssertEqual(SearchCopy.sectionRecent, "🆕 最近更新")
        XCTAssertEqual(SearchCopy.sectionHot, "🔥 最多想看")
        XCTAssertEqual(SearchCopy.sectionTop, "🏆 TOP250")
        XCTAssertEqual(SearchCopy.viewAll, "查看全部 ›")
        XCTAssertEqual(SearchCopy.historyTitle, "最近搜索")
        XCTAssertEqual(SearchCopy.scopes.map(\.label),
                       ["综合", "番号", "字头", "标题", "女优", "标签", "系列"])
        XCTAssertEqual(SearchCopy.scopes.map(\.value),
                       ["all", "number", "letter", "title", "actor", "tag", "series"])
        XCTAssertEqual(SearchCopy.modeExact, "精确")
        XCTAssertEqual(SearchCopy.modeFuzzy, "模糊")
    }

    /// 本地来源标注三分支（千分位 %,d；target<=0 = 不限）
    func test_localNoteText_variants() {
        let vm = makeVM(data: FakeSearchData())
        XCTAssertEqual(vm.localNoteText, "本地索引 · 点此改用远程全库搜索")
        vm.localIdxTotal = 12345
        vm.localIdxTarget = 0
        XCTAssertEqual(vm.localNoteText, "本地索引已含 12,345 部 (不限) · 点此改用远程全库搜索")
        vm.localIdxTarget = 80000
        XCTAssertEqual(vm.localNoteText, "本地索引已含 12,345 / 80,000 部 · 点此改用远程全库搜索")
    }

    // MARK: - PaginationGuard 接入（跳页钳制）

    func test_goPageDeep_clampsAndToasts() async throws {
        let data = FakeSearchData()
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        vm.total = 100
        await vm.goPage(99)
        XCTAssertEqual(vm.page, 3, "total=100/per=40 → 上限 3 页")
        XCTAssertEqual(data.lastSearchPage, 3, "按钳制后的页实查")
        XCTAssertEqual(vm.toast, "跳页过深（最多约 3 页），请用滚动加载")
    }

    func test_goPageWithinBounds_noToast() async throws {
        let data = FakeSearchData()
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        vm.total = 100
        await vm.goPage(2)
        XCTAssertEqual(vm.page, 2)
        XCTAssertNil(vm.toast)
    }

    // MARK: - 页缓存（TTL 10 分钟；键含 q/scope/mode/p/per）

    func test_searchCacheHit_withinTTL_noSecondRemoteCall() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...3), derived: "", served: "remote")
        let clock = ClockBox()
        let vm = makeVM(data: data, cache: SearchMemCache(now: { clock.now }), clock: clock)
        vm.query = "abc"
        await vm.search()
        await vm.search()
        XCTAssertEqual(data.searchCalls, 1, "TTL 内第二发走页缓存")
        XCTAssertEqual(vm.items?.count, 3)
        XCTAssertEqual(vm.served, "remote")
        XCTAssertEqual(vm.offlineNote, "远程全库", "远程路径 derived 空 → 「远程全库」")
    }

    func test_searchCache_isolatedByScopeAndMode() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...2), derived: "", served: "remote")
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        vm.scope = "title"
        await vm.search()
        XCTAssertEqual(data.lastSearchScope, "title")
        XCTAssertEqual(data.searchCalls, 2, "scope 变化 → 键不同 → 实查")
        vm.mode = "exact"
        await vm.search()
        XCTAssertEqual(data.lastSearchMode, "exact")
        XCTAssertEqual(data.searchCalls, 3, "mode 变化 → 键不同 → 实查")
    }

    // MARK: - 本地索引优先路由（S12-P1）

    func test_localIndexPreferred_servedLocal_noRemoteCall() async throws {
        let data = FakeSearchData()
        let idx = FakeIdx()
        idx.rows = rows(1...40)
        let vm = makeVM(data: data, idx: idx)
        defer { releaseIdx() }
        vm.query = "abc"
        await vm.search()
        XCTAssertEqual(data.searchCalls, 0, "本地命中不发远程")
        XCTAssertEqual(vm.served, "local")
        XCTAssertEqual(vm.derived, "本地索引")
        XCTAssertEqual(vm.items?.count, 40)
        XCTAssertTrue(vm.hasMore, "满页才可能有下一页")
        XCTAssertNil(vm.offlineNote)
        let arrived = await waitUntil { vm.total == 40 }
        XCTAssertTrue(arrived, "fetchCount(preferLocal) 用 countLocalIdx 补计数")
        XCTAssertEqual(data.countCalls, 0, "本地计数不查远程 COUNT")
    }

    /// 本地 0 命中 + 在线 → 落远程；中途 offlineNote 逐字「本地无结果，正在查远程…」
    func test_localZeroHit_online_fallsBackRemote_withVerbatimNote() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...3), derived: "", served: "remote")
        data.gateFirstSearch = true
        let idx = FakeIdx()   // ready 但检索恒空
        let vm = makeVM(data: data, idx: idx)
        defer { releaseIdx() }
        vm.query = "稀疏词"
        let t = Task { await vm.search() }
        let noted = await waitUntil { vm.offlineNote == "本地无结果，正在查远程…" }
        XCTAssertTrue(noted)
        data.releaseSearch()
        await t.value
        XCTAssertEqual(vm.served, "remote")
        XCTAssertEqual(vm.items?.count, 3)
        XCTAssertEqual(vm.offlineNote, "远程全库", "远程成功后注记被替换")
    }

    /// 本地 0 命中 + 离线 → 直接空结果（S12-P6）
    func test_localZeroHit_offline_emptyResultServedLocal() async throws {
        let data = FakeSearchData()
        let idx = FakeIdx()
        let vm = makeVM(data: data, idx: idx, isOnline: { false })
        defer { releaseIdx() }
        vm.query = "abc"
        await vm.search()
        XCTAssertEqual(data.searchCalls, 0, "离线不查远程")
        XCTAssertEqual(vm.items?.count, 0)
        XCTAssertEqual(vm.served, "local")
        XCTAssertFalse(vm.hasMore)
    }

    /// 本地异常 → 落远程
    func test_localThrows_fallsBackRemote() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...2), derived: "", served: "remote")
        let idx = FakeIdx()
        idx.throwOnSearch = true
        let vm = makeVM(data: data, idx: idx)
        defer { releaseIdx() }
        vm.query = "abc"
        await vm.search()
        XCTAssertEqual(vm.served, "remote")
        XCTAssertEqual(vm.items?.count, 2)
    }

    // MARK: - rid 竞态（A.0：rid != reqId 整体丢弃）

    func test_ridRace_slowOldSearch_discarded() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...3), derived: "", served: "remote")
        data.gateFirstSearch = true
        let vm = makeVM(data: data)
        vm.query = "慢查询"
        let slow = Task { await vm.search() }
        _ = await waitUntil { data.searchCalls == 1 }

        data.searchResult = SearchPageResult(items: rows(10...12), derived: "", served: "remote")
        vm.query = "快查询"
        await vm.search()
        XCTAssertEqual(vm.items?.count, 3)
        XCTAssertEqual(data.lastSearchQ, "快查询")

        data.releaseSearch()
        await slow.value
        XCTAssertEqual(vm.items?.map { $0.s("id") }, ["10", "11", "12"],
                       "慢的旧搜索返回后 rid 不匹配 → 整体丢弃")
    }

    // MARK: - fetchCount 双保险（独立 countSeq）

    func test_fetchCount_appliesArrivedTotal() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...3), derived: "", served: "remote")
        data.countResult = 57
        data.gateFirstCount = true
        let vm = makeVM(data: data)
        await vm.search()
        XCTAssertEqual(vm.total, -1, "计数未到 → total 未知")
        data.releaseCount()
        let arrived = await waitUntil { vm.total == 57 }
        XCTAssertTrue(arrived, "计数异步补齐")
    }

    func test_countMinusOne_keepsUnknownTotal() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...3), derived: "", served: "remote")
        data.countResult = -1
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        _ = await waitUntil { data.countCalls == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.total, -1, "takeIf { it >= 0 }：-1 不写 total（不回退已到计数）")
    }

    func test_lateCountRace_totalNotRegressed() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...3), derived: "", served: "remote")
        data.countResult = 111
        data.gateFirstCount = true
        let vm = makeVM(data: data)
        vm.query = "a"
        await vm.search()
        XCTAssertEqual(data.countCalls, 1)

        data.countResult = 222
        data.gateFirstCount = false
        vm.query = "b"
        await vm.search()
        let bArrived = await waitUntil { vm.total == 222 }
        XCTAssertTrue(bArrived)

        data.releaseCount()   // 旧搜索的迟到计数
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.total, 222, "迟到计数（rid/countSeq 双保险）不得覆盖新结果")
    }

    // MARK: - hasMore / loadNext 同源翻页 / append 去重

    func test_hasMore_fullPageThenPartial() async throws {
        let data = FakeSearchData()
        data.resultsByPage = [
            1: SearchPageResult(items: rows(1...40), derived: "", served: "remote"),
        ]
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        XCTAssertTrue(vm.hasMore, "40 == per(40) → 满页")

        data.resultsByPage = [
            1: SearchPageResult(items: rows(1...10), derived: "", served: "remote"),
        ]
        vm.query = "def"
        await vm.search()
        XCTAssertFalse(vm.hasMore, "10 < per → 不满页")
        XCTAssertEqual(vm.page, 1)
    }

    func test_loadNext_remote_appendsDedup() async throws {
        let data = FakeSearchData()
        data.resultsByPage = [
            1: SearchPageResult(items: rows(1...40), derived: "", served: "remote"),
            2: SearchPageResult(items: rows(31...70), derived: "", served: "remote"),
            3: SearchPageResult(items: rows(71...75), derived: "", served: "remote"),
        ]
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        await vm.loadNext()
        XCTAssertEqual(vm.page, 2)
        XCTAssertEqual(vm.items?.count, 70, "31-40 重复 id 去重")
        XCTAssertTrue(vm.hasMore)
        XCTAssertEqual(data.lastSearchPage, 2, "同源（remote）翻页走 data.search")
        await vm.loadNext()
        XCTAssertEqual(vm.page, 3)
        XCTAssertEqual(vm.items?.count, 75)
        XCTAssertFalse(vm.hasMore, "尾页 5 < per")
        XCTAssertEqual(data.searchCalls, 3)
    }

    func test_loadNext_localSource_usesLocalIdx() async throws {
        let data = FakeSearchData()
        let idx = FakeIdx()
        idx.rows = rows(1...80)
        let vm = makeVM(data: data, idx: idx)
        defer { releaseIdx() }
        vm.query = "abc"
        await vm.search()
        XCTAssertEqual(vm.served, "local")
        await vm.loadNext()
        XCTAssertEqual(vm.page, 2)
        XCTAssertEqual(vm.items?.count, 80, "本地翻页 offset 40 起，去重后 80 条")
        XCTAssertEqual(data.searchCalls, 0, "同源 local：翻页不发远程")
        XCTAssertEqual(vm.lastSource, "local")
    }

    // MARK: - loadHome（TTL / stale-then-refresh 三级 / RefreshResult）

    func test_loadHome_ttlCache_noSecondCall() async throws {
        let data = FakeSearchData()
        data.homeResult = SearchHomeResult(
            recent: rows(1...3), hot: rows(4...5), top: rows(6...6), derived: "")
        let clock = ClockBox()
        let vm = makeVM(data: data, cache: SearchMemCache(now: { clock.now }), clock: clock)
        await vm.loadHome(force: false)
        await vm.loadHome(force: false)
        XCTAssertEqual(data.homeCalls, 1, "TTL 内直接用缓存")
        XCTAssertEqual(vm.home?.totalCount, 6)

        clock.now += 11 * 60_000   // 越过 10 分钟 TTL
        await vm.loadHome(force: false)
        XCTAssertEqual(data.homeCalls, 2, "过期 → 重查（stale 链路）")
    }

    func test_loadHome_stale_showsSWRNote_thenFresh() async throws {
        let data = FakeSearchData()
        data.homeResult = SearchHomeResult(
            recent: rows(1...1), hot: [], top: [], derived: "")
        let clock = ClockBox()
        let vm = makeVM(data: data, cache: SearchMemCache(now: { clock.now }), clock: clock)
        await vm.loadHome(force: false)

        data.homeResult = SearchHomeResult(
            recent: rows(2...2), hot: [], top: [], derived: "")
        data.gateFirstHome = true
        clock.now += 11 * 60_000
        let t = Task { await vm.loadHome(force: false) }
        let noted = await waitUntil { vm.offlineNote == "◌ 正在显示缓存数据, 后台刷新中…" }
        XCTAssertTrue(noted, "SWR：先渲染 stale + 注记")
        data.releaseHome()
        await t.value
        XCTAssertNil(vm.offlineNote, "后台刷新成功 → 注记清除")
        XCTAssertEqual(vm.home?.recent.first?.s("id"), "2", "stale 换新")
    }

    func test_loadHome_stale_refreshFails_offlineNote() async throws {
        let data = FakeSearchData()
        data.homeResult = SearchHomeResult(
            recent: rows(1...1), hot: [], top: [], derived: "")
        let clock = ClockBox()
        let vm = makeVM(data: data, cache: SearchMemCache(now: { clock.now }), clock: clock)
        await vm.loadHome(force: false)

        data.homeError = NSError(domain: "test.net", code: -1009)
        clock.now += 11 * 60_000
        await vm.loadHome(force: false)
        XCTAssertEqual(vm.offlineNote, "⚠ 离线: 正在显示缓存的首页数据")
        XCTAssertEqual(vm.home?.recent.first?.s("id"), "1", "仍显示 stale")
        XCTAssertNil(vm.error, "有 stale 兜底 → 不写 error")
    }

    func test_loadHome_noCacheFail_errorAndFailToast() async throws {
        let data = FakeSearchData()
        data.homeError = NSError(domain: "test.net", code: -1004)
        let vm = makeVM(data: data)
        await vm.loadHome(force: true)
        XCTAssertNotNil(vm.error, "无缓存 → ErrText 真实原因")
        XCTAssertEqual(vm.refreshResult.value, .fail("首页查询失败"))
        XCTAssertFalse(vm.loading)
    }

    func test_loadHome_forceSuccess_doneToastWithSectionSum() async throws {
        let data = FakeSearchData()
        data.homeResult = SearchHomeResult(
            recent: rows(1...3), hot: rows(4...5), top: rows(6...6), derived: "")
        let vm = makeVM(data: data)
        await vm.loadHome(force: true)
        XCTAssertEqual(vm.refreshResult.value, .done(6), "Done(n) = 三段条数之和")
        XCTAssertNil(vm.error)
    }

    // MARK: - setMode / bind / per 档位

    func test_setMode_persistsAndResearches() async throws {
        let data = FakeSearchData()
        data.searchResult = SearchPageResult(items: rows(1...2), derived: "", served: "remote")
        let vm = makeVM(data: data)
        vm.query = "abc"
        await vm.search()
        var persisted: String?
        vm.bind(to: FakeSettings()) { persisted = $0 }

        vm.setMode("exact")
        let searched = await waitUntil { data.lastSearchMode == "exact" }
        XCTAssertTrue(searched, "切换模式即时重搜")
        XCTAssertEqual(vm.mode, "exact")
        XCTAssertEqual(persisted, "exact", "setMode 落 searchMode（经页面持久化口）")

        let before = data.searchCalls
        vm.setMode("exact")   // 同值 no-op
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(data.searchCalls, before)
    }

    func test_bind_setup_showsGuide_noQuery() async throws {
        let data = FakeSearchData()
        let settings = FakeSettings()
        settings.searchSetupRequired = true
        let vm = makeVM(data: data)
        vm.bind(to: settings)
        XCTAssertTrue(vm.setup)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(data.homeCalls, 0, "引导态不查询")
    }

    func test_bind_syncsSettings_andKicksHome() async throws {
        let data = FakeSearchData()
        data.homeResult = SearchHomeResult(recent: [], hot: [], top: [], derived: "")
        let settings = FakeSettings()
        settings.searchPerPage = 60
        settings.searchViewMode = 1
        settings.searchModeRaw = 0
        settings.searchHomePer = 18
        let vm = makeVM(data: data)
        vm.bind(to: settings)
        XCTAssertEqual(vm.viewMode, 1)
        XCTAssertEqual(vm.per, 60)
        XCTAssertEqual(vm.mode, "exact")
        let kicked = await waitUntil { data.homeCalls == 1 }
        XCTAssertTrue(kicked)
        XCTAssertEqual(data.lastHomePer, 18, "homePer 档位直传")
    }

    func test_normHomePer_clampsOutsideOptions() {
        XCTAssertEqual(SearchVM.normHomePer(12), 12)
        XCTAssertEqual(SearchVM.normHomePer(18), 18)
        XCTAssertEqual(SearchVM.normHomePer(24), 24)
        XCTAssertEqual(SearchVM.normHomePer(36), 36)
        XCTAssertEqual(SearchVM.normHomePer(30), 24, "档位外归一 24")
        XCTAssertEqual(SearchVM.normHomePer(0), 24)
    }

    // MARK: - 搜索历史（UserDefaults jdlv_search_history 上限 10）

    func test_history_dedupeCap10() throws {
        let suite = "test_hist_cap_\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        for i in 1...12 {
            SearchHistory.add("词\(i)", defaults: ud)
        }
        SearchHistory.add("词3", defaults: ud)   // 重复 → 置顶不重复
        let list = SearchHistory.load(defaults: ud)
        XCTAssertEqual(list.count, 10, "上限 10")
        XCTAssertEqual(list.first, "词3")
        XCTAssertEqual(list[1], "词12")
        XCTAssertFalse(list.contains("词1"), "最旧的被挤出")
    }

    // MARK: - demo 模式全链路（DemoSearchData + JdbSearch.idx 注入；仅 DEBUG）

    #if DEBUG
    func test_demoSearch_localPreferred_thenTagFallsBackRemote() async throws {
        JdbSearch.idx = nil   // 让 DemoSearchData 注入 demo 本地索引
        defer { releaseIdx() }
        let data = DemoSearchData()   // init 内注入 DemoIdxSearchable → JdbSearch.idx
        let clock = ClockBox()
        // 注意：直接构造（不走 makeVM，避免清掉 demo 注入的 idx）
        let vm = SearchVM(data: data,
                          cache: SearchMemCache(now: { clock.now }),
                          clock: { clock.now })

        // 标题子串：demo 本地索引命中 → served=local，不发"远程"
        vm.query = "演示影片 001"
        vm.scope = "title"
        await vm.search()
        XCTAssertEqual(vm.served, "local")
        XCTAssertEqual(vm.items?.isEmpty, false)
        XCTAssertEqual(data.remoteSearchCalls, 0, "demo 本地命中不发远程")

        // 标签：demo 本地无标签列 → 0 命中 → 回落"远程"（demo 广口径）→ 命中
        let vm2 = SearchVM(data: data,
                           cache: SearchMemCache(now: { clock.now }),
                           clock: { clock.now })
        vm2.query = "企划"
        vm2.scope = "tag"
        await vm2.search()
        XCTAssertEqual(vm2.served, "remote", "标签本地无列 → 落远程")
        XCTAssertEqual(vm2.items?.isEmpty, false, "demo 远程口径按 tags 命中")
        XCTAssertEqual(data.remoteSearchCalls, 1)
    }
    #endif
}
