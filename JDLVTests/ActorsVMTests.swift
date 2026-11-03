import XCTest
import JDLVCore
@testable import JDLV

//
//  ActorsVMTests.swift —— 女优列表 / 女优详情 VM 行为单测（09 A/B 节 + 14 A.0/A.3）。
//
//  覆盖：bind NA-02 必载 / bind 与设置不一致同步后 reload / setGender/setSort 参数传递 /
//  搜索 trim / total 恒 -1（PageChip「N / ?」+ 异步计数）/ hasMore 满页推断 /
//  append 按 id 去重 + total<0 不回退 / rid 竞态 / stale 回退（只 put 不 get）/
//  goPage maxOf(1,p) / RefreshResult 仅手动下拉 / 标签 60 上限与 hasMore /
//  标签加载更多 offset/去重 / 出演影片 hasMore（total<=0 也能继续）/ 排序×方向×标签参数 /
//  收藏 Toast 与写入。
//
//  时钟/数据源/收藏存储/Toast 全部可注入 → 无网络、无磁盘依赖（SettingsStore 用独立
//  UserDefaults suite，Keychain 读取失败安全返回 nil）。
//

final class ActorsVMTests: XCTestCase {

    // MARK: - 测试假件

    /// 假女优列表数据源（对齐 Q.actors 返回键：items/total(恒 -1)/page/approx）
    @MainActor
    private final class MockSource: ActorsDataSource {
        private(set) var calls = 0
        var responses: [[String: Any]] = []
        var errors: [Error?] = []
        var delays: [Int] = []
        private(set) var seenSorts: [String] = []
        private(set) var seenGenders: [String] = []
        private(set) var seenQs: [String] = []
        private(set) var seenPages: [Int] = []
        private(set) var seenPers: [Int] = []
        private(set) var countCalls = 0
        var countValue: Int64 = -1

        func actors(
            sort: String, q: String, page: Int, per: Int, gender: String
        ) async throws -> [String: Any] {
            let idx = calls
            calls += 1
            seenSorts.append(sort)
            seenGenders.append(gender)
            seenQs.append(q)
            seenPages.append(page)
            seenPers.append(per)
            if delays.count > idx, delays[idx] > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delays[idx]) * 1_000_000)
            }
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx] : emptyPage(page)
        }

        func actorsCount(q: String, gender: String) async -> Int64 {
            countCalls += 1
            return countValue
        }

        private func emptyPage(_ page: Int) -> [String: Any] {
            ["items": [Row](), "total": Int64(-1), "page": page, "approx": true]
        }
    }

    private final class ToastBox { var list: [String] = [] }

    @MainActor
    private func makeVM(
        _ source: MockSource, _ toasts: ToastBox = ToastBox(),
        cache: BrowseCacheStore = MemoryBrowseCache()
    ) -> ActorsVM {
        ActorsVM(source: source, cache: cache, onToast: { toasts.list.append($0) })
    }

    private func actorRow(_ id: String, videos: Int64 = 10) -> Row {
        Row([
            "id": .string(id), "name": .string("演示女优 \(id)"),
            "avatar_url": .string(""), "videos_count": .int(videos),
        ])
    }

    /// Q.actors 口径：total 恒 -1
    private func page(_ ids: [String], page p: Int = 1) -> [String: Any] {
        ["items": ids.map { actorRow($0) }, "total": Int64(-1), "page": p, "approx": true]
    }

    // MARK: bind（NA-02）：items 为空 → 同步设置后必 reload（默认值恒等也不跳过）

    @MainActor
    func testBindLoadsWhenEmpty() async {
        let src = MockSource()
        src.responses = [page(["a1", "a2"])]
        let vm = makeVM(src)
        await vm.bind()
        XCTAssertEqual(src.calls, 1)                       // 必载（旧版默认值恒等导致永不首查）
        XCTAssertEqual(vm.items?.count, 2)
        XCTAssertEqual(vm.page, 1)
        XCTAssertEqual(src.seenSorts.last, "videos")
        XCTAssertEqual(src.seenGenders.last, "f")
        // 已加载且与设置一致 → bind 不动
        await vm.bind()
        XCTAssertEqual(src.calls, 1)
    }

    // MARK: bind：非空但与设置不一致 → 同步 + reload

    @MainActor
    func testBindSyncsSettingsWhenMismatch() async {
        let src = MockSource()
        src.responses = [page(["a1"])]
        let suite = UserDefaults(suiteName: "test_actors_\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        let vm = makeVM(src)
        vm.store = store
        await vm.bind()                       // 首载（videos/f）
        XCTAssertEqual(src.calls, 1)
        XCTAssertEqual(src.seenSorts.last, "videos")
        // 设置改为 popularity/m（模拟设置页/其他入口落盘）
        store.updateSettings { s in
            s.actorSort = "popularity"
            s.actorGender = "m"
        }
        await vm.bind()
        XCTAssertEqual(src.calls, 2)          // 与设置不一致 → reload
        XCTAssertEqual(vm.sort, "popularity")
        XCTAssertEqual(vm.gender, "m")
        XCTAssertEqual(src.seenSorts.last, "popularity")
        XCTAssertEqual(src.seenGenders.last, "m")
    }

    // MARK: setGender / setSort：参数传递 + page=1

    @MainActor
    func testSetGenderAndSortParams() async {
        let src = MockSource()
        src.responses = [page(["a1"]), page(["a2"]), page(["a3"])]
        let vm = makeVM(src)
        await vm.bind()
        await vm.setGender("m")
        XCTAssertEqual(src.seenGenders.last, "m")
        XCTAssertEqual(src.seenPages.last, 1)
        XCTAssertEqual(vm.gender, "m")
        await vm.setSort("avg_solo")
        XCTAssertEqual(src.seenSorts.last, "avg_solo")
        XCTAssertEqual(src.seenPages.last, 1)
        XCTAssertEqual(vm.sort, "avg_solo")
        // 6 档排序逐字 value 透传
        let values = ActorsCopy.sortOptions.map { $0.value }
        XCTAssertEqual(values, ["videos", "popularity", "name", "debut", "avg_solo", "avg_all"])
        XCTAssertEqual(ActorsCopy.genderOptions.map { $0.value }, ["f", "m", "all"])
    }

    // MARK: 搜索：trim + page=1

    @MainActor
    func testSearchTrimsAndReloads() async {
        let src = MockSource()
        src.responses = [page(["a1"]), page(["a2"])]
        let vm = makeVM(src)
        await vm.bind()
        await vm.search("  苍井  ")
        XCTAssertEqual(vm.q, "苍井")
        XCTAssertEqual(src.seenQs.last, "苍井")
        XCTAssertEqual(src.seenPages.last, 1)
        // 缓存键含 q
        XCTAssertEqual(ActorsVM.cacheKey(sort: "videos", gender: "f", q: "苍井", page: 2),
                       "actors:videos:f:苍井:2")
    }

    // MARK: total 恒 -1 → PageChip「N / ?」；异步计数到达 → 「N / total」

    @MainActor
    func testTotalUnknownAndAsyncCount() async {
        let src = MockSource()
        src.responses = [page(["a1", "a2"])]
        src.countValue = -1                     // 计数失败 → 保持未知
        let vm = makeVM(src)
        await vm.bind()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.total, 0)             // total<0 不落 → 未知
        XCTAssertEqual(AppCopy.pageChipLabel(loaded: 2, total: vm.total), "2 / ?")
        // 计数到达 → total 更新；后续页 total -1 不回退
        let cache = MemoryBrowseCache()
        let vm2 = ActorsVM(source: src, cache: cache, onToast: { _ in })
        vm2.per = 2
        src.countValue = 57
        src.responses.append(page(["a1", "a2"]))   // responses[1]：满页
        await vm2.bind()
        XCTAssertEqual(vm2.total, 57)
        src.responses.append(page(["a3"], page: 2))
        await vm2.loadNext()
        XCTAssertEqual(vm2.total, 57)           // total<0 不回退已到达计数
        XCTAssertEqual(AppCopy.pageChipLabel(loaded: 3, total: vm2.total), "3 / 57")
    }

    // MARK: hasMore 按满页推断（铁律 20：total 未知也能翻页）

    @MainActor
    func testHasMoreByFullPage() async {
        let src = MockSource()
        src.responses = [page(["a1", "a2"]), page(["a3"])]
        let vm = makeVM(src)
        vm.per = 2
        await vm.bind()
        XCTAssertTrue(vm.hasMore)               // 本页 2 条 == per
        await vm.loadNext()
        XCTAssertEqual(vm.page, 2)
        XCTAssertFalse(vm.hasMore)              // 本页 1 条 < per
        // 已无更多 → loadNext 不再发请求
        let callsBefore = src.calls
        await vm.loadNext()
        XCTAssertEqual(src.calls, callsBefore)
    }

    // MARK: append 按 id 去重

    @MainActor
    func testAppendDedupById() async {
        let src = MockSource()
        src.responses = [page(["a1", "a2"]), page(["a2", "a3", "a4"])]
        let vm = makeVM(src)
        vm.per = 2
        await vm.bind()
        await vm.loadNext()
        XCTAssertEqual(vm.items?.map { $0.s("id") }, ["a1", "a2", "a3", "a4"])
        XCTAssertEqual(vm.page, 2)
    }

    // MARK: rid 竞态：旧响应一律丢弃

    @MainActor
    func testRidRaceDiscardsStaleResponse() async {
        let src = MockSource()
        src.responses = [page(["a1"]), page(["a2"])]
        src.delays = [150, 0]
        let vm = makeVM(src)
        let first = Task { await vm.bind() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await vm.search("新词")                 // 第二次请求先返回
        await first.value
        XCTAssertEqual(src.calls, 2)
        XCTAssertEqual(vm.items?.first?.s("id"), "a2")
        XCTAssertEqual(vm.q, "新词")
        XCTAssertFalse(vm.loading)
    }

    // MARK: stale 回退（只 put 不 get；失败时 stale 兜底 → 不进错误态）

    @MainActor
    func testStaleFallbackOnFailure() async {
        let src = MockSource()
        let cache = MemoryBrowseCache()
        src.responses = [page(["a1", "a2"])]
        let vm = makeVM(src, cache: cache)
        vm.per = 2
        await vm.bind()
        XCTAssertEqual(vm.items?.count, 2)
        // 第二次查询失败 → stale（键同 actors:{sort}:{gender}:{q}:{page}；只 put 不 get）
        src.errors = [nil, QRuntimeError("远程库不可达：测试")]
        await vm.reload()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.items?.count, 2)      // stale 渲染
        // 无 stale → ErrText + fromRefresh 时 Fail
        let src2 = MockSource()
        src2.errors = [QRuntimeError("查询超时")]
        let toasts = ToastBox()
        let vm2 = makeVM(src2, toasts)
        await vm2.refresh()
        XCTAssertNotNil(vm2.error)
        guard case .fail? = vm2.refreshChannel.value else {
            return XCTFail("手动下拉失败应写 RefreshResult.Fail")
        }
        XCTAssertEqual(vm2.refreshChannel.value?.toastText,
                       AppCopy.refreshFailToast(ErrText.of(QRuntimeError("查询超时"))))
        vm2.refreshChannel.consume()
        XCTAssertNil(vm2.refreshChannel.value)
    }

    // MARK: goPage：仅 maxOf(1, p) 钳制 + keepPage

    @MainActor
    func testGoPageClampMinOne() async {
        let src = MockSource()
        src.responses = [page(["a1"]), page(["a2"]), page(["a3"]), page(["a4"])]
        let vm = makeVM(src)
        await vm.bind()
        await vm.goPage(0)
        XCTAssertEqual(vm.page, 1)
        XCTAssertEqual(src.seenPages.last, 1)
        await vm.goPage(3)
        XCTAssertEqual(vm.page, 3)
        XCTAssertEqual(src.seenPages.last, 3)
    }

    // MARK: RefreshResult 仅手动下拉路径写入

    @MainActor
    func testRefreshResultOnlyFromManualRefresh() async {
        let src = MockSource()
        src.responses = [page(["a1", "a2"]), page(["a1", "a2"])]
        let toasts = ToastBox()
        let vm = makeVM(src, toasts)
        await vm.reload()
        XCTAssertNil(vm.refreshChannel.value)   // 首载/筛选不写
        await vm.refresh()
        guard case .done(let n)? = vm.refreshChannel.value else {
            return XCTFail("手动下拉成功应写 RefreshResult.Done")
        }
        XCTAssertEqual(n, 2)
        XCTAssertEqual(vm.refreshChannel.value?.toastText, "✓ 刷新完成 · 共 2 条")
    }

    // MARK: - ActorDetailVM

    @MainActor
    private final class MockActorSource: ActorDetailDataSource {
        private(set) var calls = 0
        var responses: [[String: Any]?] = []
        var errors: [Error?] = []
        private(set) var seenAids: [String] = []
        private(set) var seenPages: [Int] = []
        private(set) var seenSorts: [String] = []
        private(set) var seenAscs: [Bool] = []
        private(set) var seenTagIds: [String] = []
        var tagPages: [[Row]] = []              // 每次标签调用的返回
        private(set) var tagCalls = 0
        private(set) var seenTagOffsets: [Int] = []

        func actor(
            aid: String, page: Int, per: Int, sort: String, asc: Bool, tagId: String
        ) async throws -> [String: Any]? {
            let idx = calls
            calls += 1
            seenAids.append(aid)
            seenPages.append(page)
            seenSorts.append(sort)
            seenAscs.append(asc)
            seenTagIds.append(tagId)
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx] : nil
        }

        func actorTags(aid: String, offset: Int, limit: Int) async -> [Row] {
            let idx = tagCalls
            tagCalls += 1
            seenTagOffsets.append(offset)
            return idx < tagPages.count ? tagPages[idx] : []
        }
    }

    @MainActor
    private func actorPayload(
        aid: String, ids: [String], total: Int64, merged: String = "", page p: Int = 1
    ) -> [String: Any] {
        [
            "actor": [
                "id": aid, "name": "演示女优", "name_zht": "", "other_name": "别名甲",
                "birthday": "1990-01-01", "height": "160", "popularity": Int64(88),
                "avg_score_all": 4.25, "twitter": "@demo", "avatar_url": "",
                "merged_into": merged,
            ] as [String: Any],
            "total": total, "items": ids.map { actorRow($0) }, "page": p,
        ]
    }

    // MARK: 详情组装 + InfoRow 口径 + 收藏写入 + 历史标记

    @MainActor
    func testActorDetailLoadAndFav() async {
        let src = MockActorSource()
        src.responses = [actorPayload(aid: "200001", ids: ["m1", "m2"], total: 2)]
        let store = MemoryFavStore()
        let toasts = ToastBox()
        let vm = ActorDetailVM(source: src, favStore: store, onToast: { toasts.list.append($0) })
        await vm.bind(aid: "200001")
        XCTAssertFalse(vm.loading)
        XCTAssertEqual(vm.actor?.s("name"), "演示女优")
        XCTAssertEqual(vm.total, 2)
        XCTAssertEqual(vm.items.count, 2)
        // 加载成功后 historyMark("actor", aid, name)
        XCTAssertTrue(await store.historyIs(kind: "actor", itemId: "200001"))
        // toggleFav → 写入 + Toast 逐字
        await vm.toggleFav()
        XCTAssertTrue(vm.fav)
        XCTAssertTrue(await store.favIs(kind: "actor", itemId: "200001"))
        XCTAssertEqual(toasts.list.last, "已收藏")
        await vm.toggleFav()
        XCTAssertEqual(toasts.list.last, "已取消收藏")
    }

    // MARK: 出演影片 hasMore（total<=0 也要能继续加载）+ append 按 id 去重

    @MainActor
    func testActorMoviesHasMoreAndAppend() async {
        let src = MockActorSource()
        src.responses = [
            actorPayload(aid: "200001", ids: ["m1", "m2"], total: 0),    // total 异常 0
            actorPayload(aid: "200001", ids: ["m2", "m3"], total: 0, page: 2),
        ]
        let vm = ActorDetailVM(source: src, favStore: MemoryFavStore(), onToast: { _ in })
        await vm.bind(aid: "200001")
        XCTAssertTrue(vm.hasMore)               // total<=0 → 继续加载
        await vm.loadNext()
        XCTAssertEqual(vm.page, 2)
        XCTAssertEqual(vm.items.map { $0.s("id") }, ["m1", "m2", "m3"])   // 去重拼接
        // total 真值路径：items >= total → 停止
        let src2 = MockActorSource()
        src2.responses = [actorPayload(aid: "200001", ids: ["m1", "m2"], total: 2)]
        let vm2 = ActorDetailVM(source: src2, favStore: MemoryFavStore(), onToast: { _ in })
        await vm2.bind(aid: "200001")
        XCTAssertFalse(vm2.hasMore)
    }

    // MARK: 排序 × 方向 × 标签参数透传（B5/B9：快照随请求发出）

    @MainActor
    func testActorDetailSortParams() async {
        let src = MockActorSource()
        src.responses = [actorPayload(aid: "200001", ids: ["m1"], total: 1)]
        let vm = ActorDetailVM(source: src, favStore: MemoryFavStore(), onToast: { _ in })
        await vm.bind(aid: "200001")
        await vm.setSort("id")
        XCTAssertEqual(src.seenSorts.last, "id")
        XCTAssertEqual(src.seenPages.last, 1)
        XCTAssertTrue(vm.sort == "id")          // sort=id 时页面显示口径说明
        await vm.setAsc(true)
        XCTAssertEqual(src.seenAscs.last, true)
        await vm.setTag("9")
        XCTAssertEqual(src.seenTagIds.last, "9")
        // 再点同一标签 → 取消（回「全部」）
        await vm.setTag("9")
        XCTAssertEqual(src.seenTagIds.last, "")
        XCTAssertEqual(vm.tagId, "")
        // 排序选项逐字
        XCTAssertEqual(ActorDetailCopy.sortOptions.map { $0.value },
                       ["release_date", "id", "score"])
        XCTAssertEqual(ActorDetailCopy.ascOptions.map { $0.value }, ["desc", "asc"])
    }

    // MARK: 标签聚合：TAG_LIMIT=60 / hasMore=满页 / loadMoreTags offset=已显示条数 + 去重

    @MainActor
    func testActorTagsLimitAndLoadMore() async {
        let src = MockActorSource()
        src.responses = [actorPayload(aid: "200001", ids: ["m1"], total: 1)]
        let full = (0..<60).map {
            Row(["id": .string("t\($0)"), "name": .string("标签\($0)"), "c": .int(Int64($0 + 1))])
        }
        src.tagPages = [full, [Row(["id": .string("t59"), "name": .string("重复"), "c": .int(1)]),
                               Row(["id": .string("t70"), "name": .string("新标签"), "c": .int(1)])]]
        let vm = ActorDetailVM(source: src, favStore: MemoryFavStore(), onToast: { _ in })
        await vm.bind(aid: "200001")
        XCTAssertEqual(vm.tags.count, 60)       // TAG_LIMIT = 60
        XCTAssertEqual(ActorDetailVM.TAG_LIMIT, 60)
        XCTAssertTrue(vm.tagsHasMore)           // 满页 60 → 有更多
        // 加载更多：offset = 已显示条数；按 tag id 去重合并
        await vm.loadMoreTags()
        XCTAssertEqual(src.seenTagOffsets.last, 60)
        XCTAssertEqual(vm.tags.count, 61)       // t59 重复被去重，t70 新增
        XCTAssertFalse(vm.tagsHasMore)          // 本次返回 2 < 60 → 没有更多
        // 未满页（首次返回 < 60）→ 无「加载更多」
        let src2 = MockActorSource()
        src2.responses = [actorPayload(aid: "200001", ids: ["m1"], total: 1)]
        src2.tagPages = [Array(full.prefix(59))]
        let vm2 = ActorDetailVM(source: src2, favStore: MemoryFavStore(), onToast: { _ in })
        await vm2.bind(aid: "200001")
        XCTAssertFalse(vm2.tagsHasMore)
    }

    // MARK: 标签聚合失败 → 空列表（UI 隐藏标签入口），不阻塞影片列表

    @MainActor
    func testActorTagsFailureIsSilent() async {
        let src = MockActorSource()
        src.responses = [actorPayload(aid: "200001", ids: ["m1"], total: 1)]
        src.tagPages = [[], []]
        let vm = ActorDetailVM(source: src, favStore: MemoryFavStore(), onToast: { _ in })
        await vm.bind(aid: "200001")
        XCTAssertEqual(vm.items.count, 1)       // 影片列表不受影响
        XCTAssertEqual(vm.tags.count, 0)        // 标签空 → UI 隐藏入口
        XCTAssertFalse(vm.tagsHasMore)
    }

    // MARK: demo 合成数据源（DEBUG）：详情组装/gallery/女优列表字段口径

    #if DEBUG
    @MainActor
    func testDemoMovieDetailAssembly() async {
        guard DemoDataSource.enabled() else { return }   // 仅 -JDLV_DEMO 1 注入时执行
        let src = DemoMovieDetailDataSource()
        let d = try? await src.movie(mid: "100000")
        XCTAssertNotNil(d)
        let base = MovieDetailVM.rowOf(d!)
        XCTAssertEqual(base.s("id"), "100000")
        XCTAssertFalse(base.s("number").isEmpty)
        let tags = d!["tags"] as? [Row] ?? []
        XCTAssertFalse(tags.isEmpty)                     // tags CSV → tag_id=tag_name
        let actors = d!["actors"] as? [[String: Any]] ?? []
        XCTAssertFalse(actors.isEmpty)                   // 确定性合成 1~3 人
        let previews = d!["previews"] as? [String] ?? []
        XCTAssertEqual(previews.count, 4)
        let vm = MovieDetailVM(source: src, favStore: MemoryFavStore(), onToast: { _ in })
        await vm.bind(mid: "100000")
        XCTAssertEqual(vm.actors.count, actors.count)
        XCTAssertEqual(MovieDetailVM.sortActors(vm.actors).map { $0.s("actor_id") },
                       vm.actors.map { $0.s("actor_id") })   // 已按 ♀ 前 ♂ 沉底
    }
    #endif
}
