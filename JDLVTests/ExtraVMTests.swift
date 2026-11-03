import XCTest
import JDLVCore
@testable import JDLV

//
//  ExtraVMTests.swift —— P9e 四页 VM 行为单测（14_vm_tests A.7/A.8/A.5 + 10 §5/§4/§7）。
//
//  覆盖：Articles（total>0 早停 / goPage 本地 ceil 钳制 / 同页忽略 / 分类 bind 静默拉取 /
//  stale 回落 / 刷新通道）/ HotReviews（keys 空 → hasData=false / key 响应回填 /
//  setPeriod 清 key/keys / 文案逐字）/ Top250（年份 chips 格式 / 副标题 / setYear 清空 /
//  TTL 缓存命中不发网 / force 绕过）/ Favs（三类计数 / ts DESC / 时间未知 / 空态 /
//  导出文本逐字）/ rid 竞态丢弃旧响应。
//
//  时钟/数据源/Toast 全部可注入 → 无网络、无磁盘、无 AppServices 依赖。
//

final class ExtraVMTests: XCTestCase {

    // MARK: - 通用假件

    private struct TestError: Error, CustomStringConvertible {
        let description = "mock failure"
    }

    private final class ToastBox { var list: [String] = [] }

    private static func artRow(_ id: String, title: String = "演示资讯", cat: String = "业界",
                               released: String = "2026-10-31 10:00:00", words: Int64 = 1859)
        -> Row {
        Row([
            "id": .string(id), "title": .string("\(title) \(id)"),
            "category_id": .string("1"), "category_name": .string(cat),
            "author_name": .string("某作者"), "cover_url": .string(""),
            "cover_path": .string(""), "released_at": .string(released),
            "word_count": .int(words),
        ])
    }

    private static func hotRow(rid: String, rank: Int64, title: String = "演示影片",
                               score: String = "4.3", likes: String = "12",
                               user: String = "网友", content: String = "评论内容") -> Row {
        Row([
            "rid": .string(rid), "rank": .int(rank), "movie_id": .string("100001"),
            "number": .string("ABC-001"), "movie_title": .string(title),
            "movie_score": .double(4.3), "movie_thumb_url": .string(""),
            "user_name": .string(user), "score": .string(score),
            "likes_count": .string(likes), "content": .string(content),
            "created_at": .string("2026-10-31 12:00:00"),
        ])
    }

    private static func movieRow(_ id: String, year: String = "2024") -> Row {
        Row([
            "id": .string(id), "number": .string("IPX-\(id)"), "title": .string("演示影片 \(id)"),
            "release_date": .string("2024-06-01"), "year": .string(year), "score": .double(4.2),
            "want_watch_count": .int(10), "magnets_count": .int(3), "cover_url": .string(""),
        ])
    }

    // MARK: - Articles 假件

    @MainActor
    private final class MockArticlesSource: ArticlesDataSource {
        var calls = 0
        var responses: [[String: Any]] = []
        var errors: [Error?] = []
        var delays: [UInt64] = []
        private(set) var lastPages: [Int] = []
        var categories: [Row] = []
        var categoryCalls = 0

        func articles(page: Int, per: Int, categoryId: Int?, q: String) async throws
            -> [String: Any] {
            let idx = calls
            calls += 1
            lastPages.append(page)
            if delays.count > idx, delays[idx] > 0 {
                try? await Task.sleep(nanoseconds: delays[idx] * 1_000_000)
            }
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx] : ["items": [Row](), "total": Int64(0)]
        }

        func articleCategories() async -> [Row] {
            categoryCalls += 1
            return categories
        }

        func article(aid: String) async throws -> Row? { ExtraVMTests.artRow(aid) }
        func articleMovies(aid: String) async -> [Row] { [] }
        func movieByNumber(number: String) async -> Row? {
            Row(["id": .string("100042"), "number": .string(number)])
        }
    }

    @MainActor
    private func articlesPayload(items: [Row], total: Int64) -> [String: Any] {
        ["items": items, "total": total, "page": 1, "per": 24]
    }

    @MainActor
    private func makeArticlesVM(_ src: MockArticlesSource, _ toasts: ToastBox = ToastBox())
        -> ArticlesVM {
        ArticlesVM(source: src, cache: MemoryBrowseCache(), onToast: { toasts.list.append($0) })
    }

    // MARK: Articles：goPage 本地 ceil 钳制（A.7）

    @MainActor
    func testArticlesGoPageClampsByLocalCeil() async {
        let src = MockArticlesSource()
        src.responses = [articlesPayload(items: (1...24).map { artRow("\($0)") }, total: 50)]
        let vm = makeArticlesVM(src)
        await vm.bind()
        XCTAssertEqual(vm.total, 50)
        await vm.goPage(99)                    // 本地钳制：ceil(50/24)=3 → page=3
        XCTAssertEqual(vm.page, 3)
        await vm.goPage(0)                     // 下界 1
        XCTAssertEqual(vm.page, 1)
    }

    @MainActor
    func testArticlesGoPageSamePageIgnoredWhenHasItems() async {
        let src = MockArticlesSource()
        src.responses = [articlesPayload(items: (1...24).map { artRow("\($0)") }, total: 50)]
        let vm = makeArticlesVM(src)
        await vm.bind()
        let before = src.calls
        await vm.goPage(1)                     // 目标页==当前页且有数据 → 不动
        XCTAssertEqual(src.calls, before)
    }

    // MARK: Articles：total>0 早停（A.7）

    @MainActor
    func testArticlesLoadNextStopsEarlyByTotal() async {
        let src = MockArticlesSource()
        src.responses = [
            articlesPayload(items: (1...24).map { artRow("\($0)") }, total: 48),
            articlesPayload(items: (25...48).map { artRow("\($0)") }, total: 48),
        ]
        let vm = makeArticlesVM(src)
        await vm.bind()
        await vm.loadNext()                    // 24/48 → 补第 2 页
        XCTAssertEqual(src.lastPages.last, 2)
        XCTAssertEqual(vm.items?.count, 48)
        await vm.loadNext()                    // 已加载 48 >= total 48 → 早停
        XCTAssertEqual(src.calls, 2)
    }

    // MARK: Articles：bind 静默拉分类（A.7 runCatching）

    @MainActor
    func testArticlesBindLoadsCategoriesSilently() async {
        let src = MockArticlesSource()
        src.categories = [Row(["category_id": .int(1), "category_name": .string("业界"),
                               "n": .int(12)])]
        src.responses = [articlesPayload(items: [artRow("1")], total: 1)]
        let vm = makeArticlesVM(src)
        await vm.bind()
        XCTAssertEqual(src.categoryCalls, 1)
        XCTAssertEqual(vm.categories.first?.s("category_name"), "业界")
        XCTAssertNotNil(vm.items)
    }

    // MARK: Articles：失败 stale 回落（A.0 三级）

    @MainActor
    func testArticlesStaleFallbackOnFailure() async {
        let src = MockArticlesSource()
        let cache = MemoryBrowseCache()
        let key = ArticlesVM.cacheKey(categoryId: nil, q: "", page: 1)
        cache.put(key, articlesPayload(items: [artRow("9")], total: 1))
        src.errors = [TestError()]
        let vm = ArticlesVM(source: src, cache: cache, onToast: { _ in })
        await vm.bind()
        XCTAssertNil(vm.error)                 // stale 命中 → 不写 error
        XCTAssertEqual(vm.items?.first?.s("id"), "9")
    }

    // MARK: Articles：手动下拉刷新通道 Done/Fail（A.0 RefreshResult）

    @MainActor
    func testArticlesRefreshChannelDoneAndFail() async {
        let src = MockArticlesSource()
        src.responses = [articlesPayload(items: [artRow("1")], total: 1)]
        src.errors = [nil, TestError()]       // 第一次成功、第二次失败
        let toasts = ToastBox()
        let vm = makeArticlesVM(src, toasts)
        await vm.refresh()
        guard case .done(let n)? = vm.refreshChannel.value else {
            return XCTFail("expected done")
        }
        XCTAssertEqual(n, 1)
        XCTAssertEqual(vm.refreshChannel.value?.toastText, "✓ 刷新完成 · 共 1 条")
        await vm.refresh()
        guard case .fail(let msg)? = vm.refreshChannel.value else {
            return XCTFail("expected fail")
        }
        XCTAssertTrue(msg.hasPrefix("查询失败"))
        XCTAssertEqual(vm.refreshChannel.value?.toastText.hasPrefix("刷新失败："), true)
        vm.refreshChannel.consume()
        XCTAssertNil(vm.refreshChannel.value)
    }

    // MARK: Articles：卡片元信息（10 §2.3 逐字拼接 + word_count 缺失跳过）

    @MainActor
    func testArticlesCardMetaParts() {
        let r = artRow("1", cat: "业界", released: "2026-10-31 10:00:00", words: 1859)
        XCTAssertEqual(ArticlesVM.cardMetaParts(r).joined(separator: " · "),
                       "业界 · 某作者 · 2026-10-31 · 1859 字")
        let noWords = artRow("2", words: 0)
        XCTAssertFalse(ArticlesVM.cardMetaParts(noWords).contains { $0.contains("字") })
    }

    // MARK: - HotReviews 假件

    @MainActor
    private final class MockHotSource: HotReviewsDataSource {
        var calls = 0
        var responses: [[String: Any]] = []
        var errors: [Error?] = []
        var delays: [UInt64] = []
        private(set) var seenPeriods: [String] = []
        private(set) var seenKeys: [String?] = []

        func hotReviews(period: String, periodKey: String?, page: Int, per: Int) async throws
            -> [String: Any] {
            let idx = calls
            calls += 1
            seenPeriods.append(period)
            seenKeys.append(periodKey)
            if delays.count > idx, delays[idx] > 0 {
                try? await Task.sleep(nanoseconds: delays[idx] * 1_000_000)
            }
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx]
                : ["items": [Row](), "total": Int64(0), "keys": [String](), "key": "",
                   "hasData": false]
        }
    }

    @MainActor
    private func hotPayload(items: [Row], keys: [String], key: String, hasData: Bool,
                            total: Int64 = 12) -> [String: Any] {
        ["items": items, "total": total, "keys": keys, "key": key, "hasData": hasData]
    }

    // MARK: HotReviews：keys 空 → hasData=false 明确空态（A.8 / P7.2 不再抛错）

    @MainActor
    func testHotReviewsEmptyKeysSetsHasDataFalse() async {
        let src = MockHotSource()
        src.responses = [hotPayload(items: [], keys: [], key: "", hasData: false)]
        let vm = HotReviewsVM(source: src, onToast: { _ in })
        await vm.bind()
        XCTAssertFalse(vm.hasData)             // 明确空态（不写 error）
        XCTAssertNil(vm.error)
        XCTAssertTrue((vm.items ?? []).isEmpty)
    }

    // MARK: HotReviews：key/keys 从响应回填（A.8）

    @MainActor
    func testHotReviewsKeyBackfilledFromResponse() async {
        let src = MockHotSource()
        src.responses = [hotPayload(
            items: [hotRow(rid: "1", rank: 1)], keys: ["2026-W02", "2026-W01"],
            key: "2026-W02", hasData: true)]
        let vm = HotReviewsVM(source: src, onToast: { _ in })
        await vm.bind()
        XCTAssertEqual(vm.key, "2026-W02")     // 响应回填（key 空 → keys.first）
        XCTAssertEqual(vm.keys, ["2026-W02", "2026-W01"])
        XCTAssertTrue(vm.hasData)
    }

    // MARK: HotReviews：切周期清 key/keys 并重查（10 §4.2）

    @MainActor
    func testHotReviewsSetPeriodClearsKeyAndKeys() async {
        let src = MockHotSource()
        src.responses = [hotPayload(items: [hotRow(rid: "1", rank: 1)],
                                    keys: ["2026-W02", "2026-W01"], key: "2026-W02",
                                    hasData: true),
                         hotPayload(items: [hotRow(rid: "2", rank: 1)], keys: ["2026-02"],
                                    key: "2026-02", hasData: true)]
        let vm = HotReviewsVM(source: src, onToast: { _ in })
        await vm.bind()
        await vm.setPeriod("monthly")
        XCTAssertEqual(vm.period, "monthly")
        XCTAssertEqual(vm.key, "2026-02")      // 新响应回填
        XCTAssertEqual(vm.keys, ["2026-02"])
        XCTAssertEqual(src.seenPeriods.last, "monthly")
        XCTAssertEqual(src.seenKeys.last, "2026-02")
    }

    // MARK: HotReviews：文案逐字（10 §4.5/§4.6：赞 0 不显示 / 评论 N★ / #N 双空格）

    @MainActor
    func testHotReviewsCopyVerbatim() {
        XCTAssertNil(HotReviewsCopy.likesText("0"))            // 赞 0 不显示
        XCTAssertNil(HotReviewsCopy.likesText(""))             // 空不显示
        XCTAssertEqual(HotReviewsCopy.likesText("23"), "赞 23")
        // score 空时「评论  · user」形态按原样保留
        XCTAssertEqual(HotReviewsCopy.sheetCommentLine(score: "", userName: "网友"),
                       "评论  · 网友")
        XCTAssertEqual(HotReviewsCopy.sheetCommentLine(score: "4.5", userName: "网友"),
                       "评论 4.5★ · 网友")
        XCTAssertEqual(HotReviewsCopy.sheetTitle(rank: "3", title: "", number: "ABC-001"),
                       "#3  ABC-001")          // #与标题间两个空格；title 空回退 number
        XCTAssertEqual(HotReviewsCopy.sheetLikesLine(likes: "", createdAt: "2026-10-31 12:00:00"),
                       "点赞 0 · 2026-10-31")
        XCTAssertEqual(HotReviewsCopy.rowSub(number: "ABC-001", movieScore: "4.3"),
                       "ABC-001 · 评分 4.3")
        XCTAssertEqual(HotReviewsCopy.emptyNoData,
                       "远程库暂无热评数据（需抓取端跑热评任务后上传）")
        XCTAssertEqual(HotReviewsCopy.copiedToast, "已复制评论全文")
        XCTAssertEqual(HotReviewsCopy.periods.map { $0.label },
                       ["全部", "上周", "月度", "季度", "年度", "最新"])
    }

    // MARK: HotReviews：goPage 本地 ceil 钳制（同 Articles）

    @MainActor
    func testHotReviewsGoPageClamp() async {
        XCTAssertEqual(HotReviewsVM.clampGoPage(99, total: 48, per: 24), 2)
        XCTAssertEqual(HotReviewsVM.clampGoPage(0, total: 48, per: 24), 1)
        XCTAssertEqual(HotReviewsVM.clampGoPage(9, total: 0, per: 24), 9)   // total 未知不钳
        XCTAssertEqual(HotReviewsVM.clampGoPage(9, total: 10, per: 0), 1)   // per<=0 按 1
    }

    // MARK: HotReviews：rid 竞态丢弃旧响应（A.0）

    @MainActor
    func testHotReviewsRidRaceDiscardsStaleResponse() async {
        let src = MockHotSource()
        src.delays = [120, 0]
        src.responses = [
            hotPayload(items: [hotRow(rid: "old", rank: 99)], keys: ["k-old"],
                       key: "k-old", hasData: true),
            hotPayload(items: [hotRow(rid: "new", rank: 1)], keys: ["k-new"],
                       key: "k-new", hasData: true),
        ]
        let vm = HotReviewsVM(source: src, onToast: { _ in })
        // 并发两次查询（第一次慢响应、第二次快响应）→ 旧响应整体丢弃（rid != reqId）
        let t1 = Task { await vm.reload() }              // period=all，慢 120ms
        try? await Task.sleep(nanoseconds: 5_000_000)    // 确保 t1 先挂起
        let t2 = Task { await vm.setPeriod("monthly") }  // 快响应
        await t1.value
        await t2.value
        XCTAssertEqual(vm.period, "monthly")
        XCTAssertEqual(vm.key, "k-new")
        XCTAssertEqual(vm.items?.first?.s("rid"), "new")
    }

    // MARK: - Top250

    @MainActor
    private final class MockTopSource: Top250DataSource {
        var calls = 0
        private(set) var seenYears: [String?] = []
        var year: String = "2026"
        var years: [Row] = [Row(["year": .string("2024"), "c": .int(26)]),
                            Row(["year": .string("2023"), "n": .int(31)])]

        func top250(year: String?, page: Int, per: Int) async throws -> [String: Any] {
            calls += 1
            seenYears.append(year)
            let items = (1...min(25, per))
                .map { ExtraVMTests.movieRow("\($0)", year: year ?? "2026") }
            return ["items": items, "total": Int64(25), "page": page, "per": per,
                    "year": year ?? ""]
        }

        func top250Years() async -> [Row] { years }
    }

    // MARK: Top250：年份 chips 格式 + 副标题（10 §5.2/§5.3 逐字）

    @MainActor
    func testTop250YearChipAndSubtitleFormat() {
        XCTAssertEqual(Top250Copy.title, "🏆 TOP250")
        XCTAssertEqual(Top250VM.subtitle(total: 250, year: ""), "共 250 部 · 当前：全部")
        XCTAssertEqual(Top250VM.subtitle(total: 26, year: "2024"), "共 26 部 · 当前：2024年")
        XCTAssertEqual(Top250Copy.yearChip("2024", 26), "2024 (26)")
        // 双列名口径：Q 列 c / demo 列 n
        XCTAssertEqual(Top250VM.yearEntry(Row(["year": .string("2024"), "c": .int(26)])).count, 26)
        XCTAssertEqual(Top250VM.yearEntry(Row(["year": .string("2023"), "n": .int(31)])).count, 31)
    }

    // MARK: Top250：setYear 清空 items + page 重置 + 年份传参（10 §5.3）

    @MainActor
    func testTop250SetYearClearsAndRefetches() async {
        let src = MockTopSource()
        let vm = Top250VM(source: src, cache: MemoryBrowseCache(),
                          yearsCache: MemoryBrowseCache(), onToast: { _ in })
        await vm.bind()
        XCTAssertEqual(vm.items?.count, 25)
        await vm.setYear("2024")
        XCTAssertEqual(vm.year, "2024")
        XCTAssertEqual(vm.page, 1)
        XCTAssertEqual(vm.items?.count, 25)        // 清空后新数据到位
        XCTAssertEqual(src.seenYears.last, "2024") // 年份筛选按 m.year
        XCTAssertEqual(vm.years.count, 2)          // 年份分布已加载
    }

    // MARK: Top250：TTL 缓存命中不发网；force 刷新绕过（§5.5 TTL 10min）

    @MainActor
    func testTop250CacheTtlHitAndForceBypass() async {
        let src = MockTopSource()
        let cache = MemoryBrowseCache()
        let vm = Top250VM(source: src, cache: cache, yearsCache: MemoryBrowseCache(),
                          onToast: { _ in })
        await vm.bind()
        XCTAssertEqual(src.calls, 1)
        await vm.setYear("")                       // 同值忽略 → 不触发
        XCTAssertEqual(src.calls, 1)
        vm.items = nil                             // 模拟重进首载
        await vm.reload()                          // 缓存 TTL 10min 命中 → 不发网
        XCTAssertEqual(src.calls, 1)
        await vm.refresh()                         // force → TTL 0 → 实查
        XCTAssertEqual(src.calls, 2)
    }

    // MARK: - Favs

    @MainActor
    private final class MockFavsStore: FavsStore {
        var data: [String: [Row]] = [:]
        private(set) var seenKinds: [String] = []

        func favList(kind: String) async -> [Row] {
            seenKinds.append(kind)
            return data[kind] ?? []
        }
    }

    private static func favRow(kind: String, id: String, title: String, ts: Int64) -> Row {
        Row(["kind": .string(kind), "id": .string(id), "title": .string(title),
             "ts": .int(ts)])
    }

    // MARK: Favs：三类 tab 计数 + ts DESC 保持 + 空态文案（10 §7.1/§7.3）

    @MainActor
    func testFavsThreeTabsCountsAndDescOrder() async {
        let st = MockFavsStore()
        let now: Int64 = 1_770_000_000_000
        st.data = [
            "movie": [
                favRow(kind: "movie", id: "100002", title: "新收藏", ts: now),
                favRow(kind: "movie", id: "100001", title: "旧收藏", ts: now - 86_400_000),
            ],
            "sht": [favRow(kind: "sht", id: "300001", title: "帖子", ts: now)],
            "actor": [favRow(kind: "actor", id: "200001", title: "女优", ts: now)],
        ]
        let vm = FavsVM(store: st)
        await vm.reload()
        XCTAssertEqual(vm.count("movie"), 2)
        XCTAssertEqual(vm.count("sht"), 1)
        XCTAssertEqual(vm.count("actor"), 1)
        XCTAssertEqual(vm.rows("movie").first?.s("id"), "100002")   // ts DESC 新在前
        XCTAssertEqual(vm.rows("movie").map { $0.s("id") }, ["100002", "100001"])
        XCTAssertFalse(FavsCopy.emptyText.isEmpty)
        XCTAssertEqual(FavsCopy.emptyText, "暂无收藏 — 在详情页点 ☆ 收藏")
    }

    // MARK: Favs：空三分类（空态判定）+ 全 kind 查询调用三次

    @MainActor
    func testFavsEmptyAllKinds() async {
        let st = MockFavsStore()
        let vm = FavsVM(store: st)
        await vm.reload()
        XCTAssertEqual(st.seenKinds, ["movie", "sht", "actor"])
        XCTAssertEqual(vm.count("movie"), 0)
        XCTAssertNil(vm.rows("movie").first)
        XCTAssertFalse(vm.loading)
    }

    // MARK: Favs：时间未知（ts<=0 不显示 1970-01-01，A-9）+ 时间格式（10 §7.2）

    @MainActor
    func testFavsUnknownTimeAndFormat() {
        let bad = favRow(kind: "movie", id: "1", title: "t", ts: 0)
        XCTAssertNil(FavsVM.rowTime(bad))                            // → 时间未知
        // 秒口径（LocalStore REAL 秒）：格式 yyyy-MM-dd HH:mm（16 字符，本地时区日期不定）
        let ok = favRow(kind: "movie", id: "1", title: "t", ts: 1_770_123_456)
        let time = FavsVM.rowTime(ok)
        XCTAssertEqual(time?.count, 16)
        XCTAssertEqual(time.map { Array($0) }?[4], "-")
        XCTAssertEqual(time.map { Array($0) }?[13], ":")
        // 双口径归一：秒（<1e12）与毫秒（>1e12）同一显示
        let ms = favRow(kind: "movie", id: "1", title: "t", ts: 1_770_123_456_000)
        XCTAssertEqual(FavsVM.rowTime(ok), FavsVM.rowTime(ms))
        XCTAssertEqual(FavsVM.rowTitle(Self.favRow(kind: "movie", id: "1", title: "", ts: 1)),
                       "(无标题)")
    }

    // MARK: Favs：导出文本逐字（10 §7.4：段头恒输出 / 行尾缀两个空格 + [时间]）

    @MainActor
    func testFavsExportTextVerbatim() {
        let nowMs: Int64 = 1_770_000_000_000   // 2026-02-12 08:40:00 UTC（本地时区随环境）
        let movies = [
            Self.favRow(kind: "movie", id: "1", title: "演示影片 001", ts: 1_760_000_000),
            Self.favRow(kind: "movie", id: "2", title: "", ts: 0),
        ]
        let text = FavsVM.exportText(
            movie: movies, sht: [Self.favRow(kind: "sht", id: "3", title: "帖子", ts: 1_760_000_000)],
            actor: [], nowMs: nowMs)
        XCTAssertTrue(text.hasPrefix("JDLV 收藏导出 20"))
        XCTAssertTrue(text.contains("\n\n== 影片 (2) ==\n"))
        XCTAssertTrue(text.contains("\n\n== 帖子 (1) ==\n"))
        XCTAssertTrue(text.contains("\n\n== 女优 (0) ==\n"))   // 为 0 也输出段头
        XCTAssertTrue(text.contains("- 演示影片 001  [20"))     // 两个空格 + [时间]
        XCTAssertTrue(text.contains("- (无标题)\n"))            // 无时间无尾缀
        XCTAssertTrue(text.contains("- 帖子  [20"))
    }

    // MARK: - ArticleBody 纯函数（10 §3：sanitize 三正则 / img 分块 / 空文本丢弃）

    @MainActor
    func testArticleHtmlSanitizeAndBlocks() {
        // sanitize 三条清洗正则（font 标签 / 内联 color/background / bgcolor）
        let dirty = "<font color=\"#ffffff\">白字</font><p style=\"color:#fff;background:url(x);\">段</p>"
            + "<td bgcolor=\"black\">格</td>"
        let clean = ArticleHtml.sanitize(dirty)
        XCTAssertFalse(clean.contains("font"))
        XCTAssertFalse(clean.contains("color:"))
        XCTAssertFalse(clean.contains("background:"))
        XCTAssertFalse(clean.contains("bgcolor"))
        XCTAssertTrue(clean.contains("白字"))
        // img 分块：文本/图片交替；空文本片段丢弃
        let html = "<p>第一段</p><img src=\"https://a/x.jpg\"><p></p><img src=\"//b/y.jpg\">尾"
        let blocks = ArticleHtml.parseBlocks(html)
        guard case .text(let t1)? = blocks.first else { return XCTFail("first=text") }
        XCTAssertTrue(t1.contains("第一段"))
        guard case .image(let s1, let i1)? = blocks.dropFirst().first else {
            return XCTFail("second=image")
        }
        XCTAssertEqual(s1, "https://a/x.jpg")
        XCTAssertEqual(i1, 0)
        // 空段丢弃 → 共 3 块（文本/图/文本「尾」... 实际 4 块：文/图/图/文）
        XCTAssertEqual(blocks.count, 4)
        guard case .image(_, let i2)? = blocks.dropFirst(2).first else {
            return XCTFail("third=image")
        }
        XCTAssertEqual(i2, 1)                  // 原始序
        // 外链判定 + 灯箱过滤（外链/解析为空排除）
        XCTAssertFalse(ArticleHtml.isExternal("https://c0.jdbstatic.com/articles/x.jpg"))
        let lb = ArticleHtml.lightboxImages(
            "<img src=\"https://instagram.com/a.jpg\"><img src=\"https://c0.jdbstatic.com/articles/b.jpg\">")
        XCTAssertEqual(lb.images.count, 1)
        XCTAssertEqual(lb.rawToFiltered, [nil, 0])
    }

    // MARK: ArticleNumberLinker（10 §3.3：候选 ≥5 位才有效；跨点不重叠）

    @MainActor
    func testArticleNumberLinkerMinLength() {
        let text = "短番 AB-12 与标准 ABC-123、连写 ABC123 以及 FC2-456 都可能出现"
        let cands = ArticleHtml.numberCandidates(in: text)
        let numbers = cands.map { $0.number }
        XCTAssertTrue(numbers.contains("AB-12"))    // 5 字符（含连字符）→ 有效
        XCTAssertTrue(numbers.contains("ABC-123"))
        XCTAssertTrue(numbers.contains("ABC123"))   // 无连字符形态也命中
        for c in cands { XCTAssertTrue(c.number.count >= 5) }
        // 4 字符候选（2 字母+2 数字无连字符）无效
        XCTAssertTrue(ArticleHtml.numberCandidates(in: "BC12").isEmpty)
        // FC2 形态含数字前缀 → 与 Android 同正则同样不命中（已知口径）
        XCTAssertFalse(numbers.contains("FC2-456"))
        // 番号链接 URL 可还原原文（大小写保留；opaque 段不吃 URL host 小写化）
        XCTAssertEqual(ArticleBodyView.numberURL("IPX-042")?.absoluteString,
                       "jdlv-number:IPX-042")
    }
}
