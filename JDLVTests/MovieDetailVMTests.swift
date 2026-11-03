import XCTest
import JDLVCore
@testable import JDLV

//
//  MovieDetailVMTests.swift —— 影片详情/女优详情 VM 行为单测（08 B 节 + 09 B 节 + 14 A.0）。
//
//  覆盖：详情组装顺序字段（♀ 前 ♂ 沉底）/ 磁力卡字段（link/badge/次行逐字拼接）/
//  灯箱 gallery 组装（[封面]+剧照 同组索引）/ 反查 payload 编码往返（LookupCodec）/
//  收藏/已读写入与 Toast / 进入详情即记已读 / bind 幂等 / rid 竞态丢弃旧响应 /
//  空态与 ErrText / 影子兜底封面回填 covBackfilled / merged_into 解析 /
//  标签聚合 60 上限与 hasMore / 出演影片 hasMore（total<=0 也可翻页）。
//
//  时钟/数据源/收藏存储/Toast 全部可注入 → 无网络、无磁盘、无 AppServices 依赖。
//

final class MovieDetailVMTests: XCTestCase {

    // MARK: - 测试假件

    /// 假数据源（按调用序返回响应/错误/延迟）
    @MainActor
    private final class MockSource: MovieDetailDataSource {
        private(set) var calls = 0
        var responses: [[String: Any]?] = []
        var errors: [Error?] = []
        var delays: [Int] = []
        private(set) var seenMids: [String] = []
        var articles: [Row] = []
        var covers: [String: String] = [:]
        private(set) var coverCalls = 0

        func movie(mid: String) async throws -> [String: Any]? {
            let idx = calls
            calls += 1
            seenMids.append(mid)
            if delays.count > idx, delays[idx] > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delays[idx]) * 1_000_000)
            }
            if idx < errors.count, let e = errors[idx] { throw e }
            return idx < responses.count ? responses[idx] : nil
        }

        func movieArticles(mid: String) async -> [Row] { articles }

        func movieCovers(ids: [String]) async -> [String: String] {
            coverCalls += 1
            return covers
        }
    }

    private final class ToastBox { var list: [String] = [] }

    @MainActor
    private func makeVM(
        _ source: MockSource, _ favStore: MemoryFavStore = MemoryFavStore(),
        _ toasts: ToastBox = ToastBox()
    ) -> MovieDetailVM {
        MovieDetailVM(source: source, favStore: favStore, onToast: { toasts.list.append($0) })
    }

    /// 详情响应（对齐 Q.movie 返回键：基础标量 + tags/actors/magnets/previews）
    private func moviePayload(
        id: String, actors: [[String: Any]] = [], tags: [Row] = [],
        magnets: [Row] = [], previews: [String] = [], derived: String = ""
    ) -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "number": "ABP-\(id)", "title": "演示影片 \(id)",
            "release_date": "2024-06-01", "year": "2024", "score": 4.5,
            "reviews_count": Int64(123), "duration": "120",
            "want_watch_count": Int64(10), "watched_count": Int64(20),
            "has_cnsub": true, "summary": "剧情简介",
            "maker_id": "m1", "maker_name": "SOD create",
            "series_id": "s1", "series_name": "演示系列",
            "director_id": "d1", "director_name": "演示导演",
            "publisher_id": "p1", "publisher_name": "演示发行商",
            "cover_url": "https://img.example/c.jpg", "derived": derived,
        ]
        if !tags.isEmpty { d["tags"] = tags }
        if !actors.isEmpty { d["actors"] = actors }
        if !magnets.isEmpty { d["magnets"] = magnets }
        if !previews.isEmpty { d["previews"] = previews }
        return d
    }

    private func actorMap(id: String, name: String, gender: Int64) -> [String: Any] {
        ["actor_id": id, "actor_name": name, "gender": gender]
    }

    private func magnetRow(hash: String, size: String, cnsub: Bool, files: Int64,
                           name: String = "a.mp4") -> Row {
        Row([
            "hash": .string(hash), "name": .string(name), "size": .string(size),
            "cnsub": .bool(cnsub), "hd": .bool(false),
            "files_count": .int(files), "created_at": .string(""),
        ])
    }

    // MARK: 详情组装：拆嵌套明细 + ♀ 分区在上（B.5）

    @MainActor
    func testApplyAssemblySplitsNestedAndSortsActors() async {
        let src = MockSource()
        // 原始序：男(gender=1) 在前 —— 应用后应 ♀ 全部在前、♂ 沉底且同组保持原序
        src.responses = [moviePayload(id: "100001", actors: [
            actorMap(id: "a1", name: "男优一", gender: 1),
            actorMap(id: "f1", name: "女优一", gender: 0),
            actorMap(id: "f2", name: "女优二", gender: 0),
            actorMap(id: "a2", name: "男优二", gender: 1),
            actorMap(id: "f3", name: "无性别缺省", gender: 0),
        ], tags: [Row(["tag_id": .string("9"), "tag_name": .string("巨乳")])],
        magnets: [magnetRow(hash: "h1", size: "600", cnsub: true, files: 7)],
        previews: ["p1", "p2"])]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        XCTAssertFalse(vm.loading)
        XCTAssertEqual(vm.movie?.s("id"), "100001")
        XCTAssertEqual(vm.movie?.s("number"), "ABP-100001")
        // ♀ 在上（含 gender 缺失当女），♂ 沉底且组内原序
        XCTAssertEqual(vm.actors.map { $0.s("actor_id") }, ["f1", "f2", "f3", "a1", "a2"])
        // 嵌套明细拆位
        XCTAssertEqual(vm.tags.first?.s("tag_name"), "巨乳")
        XCTAssertEqual(vm.magnets.count, 1)
        XCTAssertEqual(vm.previews, ["p1", "p2"])
        // 未加载相关资讯 → 整块隐藏（空列表）
        XCTAssertTrue(vm.relatedArticles.isEmpty)
    }

    // MARK: 磁力卡字段（B.7 逐字拼接）

    @MainActor
    func testMagnetCardFields() {
        let link = MovieDetailVM.magnetLink(magnetRow(hash: "abc123", size: "600",
                                                      cnsub: false, files: 0))
        XCTAssertEqual(link, "magnet:?xt=urn:btih:abc123")
        // 角标：纯数字按 MB；≥1024 转 GB 去尾零；cnsub 追加「 · 中字」（前带空格）
        XCTAssertEqual(MovieDetailVM.magnetBadge(magnetRow(hash: "h", size: "600",
                                                           cnsub: false, files: 0)), "600 MB")
        XCTAssertEqual(MovieDetailVM.magnetBadge(magnetRow(hash: "h", size: "2048",
                                                           cnsub: false, files: 0)), "2 GB")
        XCTAssertEqual(MovieDetailVM.magnetBadge(magnetRow(hash: "h", size: "1228",
                                                           cnsub: true, files: 0)), "1.2 GB · 中字")
        // 次行：name 前 46 字 + files_count>0 直接拼接「· N 个文件」（无空格分隔）
        let longName = String(repeating: "字", count: 50)
        XCTAssertEqual(
            MovieDetailVM.magnetSecondLine(magnetRow(hash: "h", size: "1", cnsub: false,
                                                     files: 0, name: longName)),
            String(repeating: "字", count: 46))
        XCTAssertEqual(
            MovieDetailVM.magnetSecondLine(magnetRow(hash: "h", size: "1", cnsub: false,
                                                     files: 7, name: "abc")),
            "abc· 7 个文件")
        // name 空 + files_count>0 → 次行仍渲染（「· N 个文件」开头）
        XCTAssertTrue(MovieDetailVM.magnetHasSecondLine(
            magnetRow(hash: "h", size: "1", cnsub: false, files: 3, name: "")))
        XCTAssertFalse(MovieDetailVM.magnetHasSecondLine(
            magnetRow(hash: "h", size: "1", cnsub: false, files: 0, name: "")))
    }

    // MARK: 灯箱 gallery 组装（B.3：[封面] + 剧照，同组连续翻页）

    @MainActor
    func testGalleryAssemblyAndPreviewIndex() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001", previews: ["p1", "", "p2"])]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        // 封面在前 + 剧照过滤空 URL
        XCTAssertEqual(vm.gallery.count, 3)
        XCTAssertEqual(vm.gallery[0], MovieImg.movieCover("https://img.example/c.jpg", "100001"))
        XCTAssertEqual(vm.gallery[1], MovieImg.preview("p1"))
        XCTAssertEqual(vm.gallery[2], MovieImg.preview("p2"))
        // 封面 → index 0；剧照第 i 张 → 1 + i
        XCTAssertEqual(vm.galleryIndexOfPreview(0), 1)
        XCTAssertEqual(vm.galleryIndexOfPreview(1), 2)
        XCTAssertTrue(vm.coverTappable)
    }

    @MainActor
    func testGalleryWithoutCoverUsesPreviewsOnly() async {
        let src = MockSource()
        var d = moviePayload(id: "100001", previews: ["p1"])
        d["cover_url"] = ""
        src.responses = [d]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        XCTAssertEqual(vm.gallery, [MovieImg.preview("p1")])
        XCTAssertFalse(vm.coverTappable)
        XCTAssertEqual(vm.galleryIndexOfPreview(0), 0)
    }

    // MARK: 反查行 payload 编码往返（LookupCodec；label 全角冒号逐字）

    @MainActor
    func testJumpLinksPayloadRoundTrip() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001")]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        let links = MovieDetailVM.jumpLinks(m: vm.movie!)
        XCTAssertEqual(links.count, 5)
        // 顺序逐字：片商/系列/导演/发行商/年份
        XCTAssertEqual(links.map { $0.label },
                       ["片商：", "系列：", "导演：", "发行商：", "年份："])
        // 片商：值=name、payload 往返 filters.maker == maker_id、label「片商：SOD create」
        XCTAssertEqual(links[0].value, "SOD create")
        let spec0 = LookupCodec.decode(links[0].payload ?? "")
        XCTAssertEqual(spec0?.label, "片商：SOD create")
        XCTAssertEqual(spec0?.filters.maker, "m1")
        // 系列/导演/发行商
        XCTAssertEqual(LookupCodec.decode(links[1].payload ?? "")?.filters.seriesId, "s1")
        XCTAssertEqual(LookupCodec.decode(links[2].payload ?? "")?.filters.directorId, "d1")
        XCTAssertEqual(LookupCodec.decode(links[3].payload ?? "")?.filters.publisherId, "p1")
        // 年份：release_date 前 4 位
        XCTAssertEqual(links[4].value, "2024")
        XCTAssertEqual(LookupCodec.decode(links[4].payload ?? "")?.filters.year, "2024")
        XCTAssertEqual(LookupCodec.decode(links[4].payload ?? "")?.label, "年份：2024")
    }

    @MainActor
    func testJumpLinksMissingValueAndTagLinks() {
        // 缺值行：「—」且不可点
        let bare = Row(["id": .string("1")])
        let links = MovieDetailVM.jumpLinks(m: bare)
        XCTAssertEqual(links.map { $0.value }, ["—", "—", "—", "—", "—"])
        XCTAssertTrue(links.allSatisfy { $0.payload == nil })
        // 标签行：tag_id 空的条目跳过；payload 往返 Filters(tags) + label「标签：{name}」
        let tagLinks = MovieDetailVM.tagLinks(tags: [
            Row(["tag_id": .string("9"), "tag_name": .string("巨乳")]),
            Row(["tag_id": .string(""), "tag_name": .string("无 id")]),
            Row(["tag_id": .string("12"), "tag_name": .string("人妻")]),
        ])
        XCTAssertEqual(tagLinks.count, 2)
        let spec = LookupCodec.decode(tagLinks[0].payload)
        XCTAssertEqual(spec?.filters.tags, "9")
        XCTAssertEqual(spec?.label, "标签：巨乳")
        XCTAssertEqual(tagLinks[1].name, "人妻")
    }

    // MARK: 收藏/已读写入 + Toast（B.0/B.4/B.7）

    @MainActor
    func testFavToggleAndReadWrites() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001")]
        let store = MemoryFavStore()
        let toasts = ToastBox()
        let vm = makeVM(src, store, toasts)
        await vm.bind(mid: "100001")
        // 进入详情即记已读（B.10）→ read=true
        XCTAssertTrue(vm.read)
        let __h = await store.historyIs(kind: "movie", itemId: "100001")
        XCTAssertTrue(__h)
        XCTAssertFalse(vm.fav)
        // toggleFav → 写入 + Toast「已收藏」
        await vm.toggleFav()
        XCTAssertTrue(vm.fav)
        let __f = await store.favIs(kind: "movie", itemId: "100001")
        XCTAssertTrue(__f)
        XCTAssertEqual(toasts.list.last, "已收藏")
        await vm.toggleFav()
        XCTAssertFalse(vm.fav)
        XCTAssertEqual(toasts.list.last, "已取消收藏")
        // markRead
        await vm.markRead()
        XCTAssertTrue(vm.read)
    }

    @MainActor
    func testReadButtonToasts() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001")]
        let store = MemoryFavStore()
        let toasts = ToastBox()
        let vm = makeVM(src, store, toasts)
        await vm.bind(mid: "100001")
        // 已读态（进入即已读）→ Toast「已复制」
        await vm.onReadButtonPressed()
        XCTAssertEqual(toasts.list.last, "已复制")
        // 未读态 → Toast「已标记已读」并写已读
        let vm2 = makeVM(src, MemoryFavStore(), toasts)
        src.responses.append(moviePayload(id: "100001"))
        await vm2.bind(mid: "100002")
        await vm2.onReadButtonPressed()
        XCTAssertEqual(toasts.list.last, "已标记已读")
        XCTAssertTrue(vm2.read)
    }

    // MARK: bind 幂等（B.10：同一 mid 且已加载数据 → 幂等返回）

    @MainActor
    func testBindIdempotentForSameMid() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001")]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        await vm.bind(mid: "100001")
        XCTAssertEqual(src.calls, 1)
        // 不同 mid → 重新加载
        src.responses.append(moviePayload(id: "100002"))
        await vm.bind(mid: "100002")
        XCTAssertEqual(src.calls, 2)
        XCTAssertEqual(vm.movie?.s("id"), "100002")
    }

    // MARK: rid 竞态：旧响应一律丢弃（A.0 / B.10）

    @MainActor
    func testRidRaceDiscardsStaleResponse() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001"), moviePayload(id: "100002")]
        src.delays = [150, 0]
        let vm = makeVM(src)
        let first = Task { await vm.bind(mid: "100001") }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await vm.bind(mid: "100002")   // 第二次请求 rid=2，先返回
        await first.value              // 第一次响应晚到 → rid != reqId → 整体丢弃
        XCTAssertEqual(src.calls, 2)
        XCTAssertEqual(vm.movie?.s("id"), "100002")
        XCTAssertFalse(vm.loading)
    }

    // MARK: 空态 / 错误态（B.1 + ErrText）

    @MainActor
    func testNilMovieMeansEmptyNotError() async {
        let src = MockSource()
        src.responses = [nil]
        let vm = makeVM(src)
        await vm.bind(mid: "404")
        XCTAssertNil(vm.movie)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.loading)
        // 未记已读（m 为空不 historyMark）
        XCTAssertFalse(vm.read)
    }

    @MainActor
    func testErrorSurfacesErrText() async {
        let src = MockSource()
        src.errors = [QRuntimeError("远程库不可达：测试")]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        XCTAssertNil(vm.movie)
        XCTAssertEqual(vm.error, ErrText.of(QRuntimeError("远程库不可达：测试")))
        XCTAssertFalse(vm.loading)
    }

    // MARK: 影子兜底在线回填封面（covBackfilled；derived 含「本地缓存」）

    @MainActor
    func testCoverBackfillOnShadowDerivedRow() async {
        let src = MockSource()
        var d = moviePayload(id: "100001", derived: "本地缓存 · 可能过期")
        d["cover_url"] = ""
        src.responses = [d]
        src.covers = ["100001": "https://img.example/backfilled.jpg"]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        XCTAssertEqual(src.coverCalls, 1)
        XCTAssertTrue(vm.covBackfilled)
        XCTAssertEqual(vm.movie?.s("cover_url"), "https://img.example/backfilled.jpg")
        // 非「本地缓存」derived 不回填
        let src2 = MockSource()
        src2.responses = [moviePayload(id: "100001")]
        let vm2 = makeVM(src2)
        await vm2.bind(mid: "100001")
        XCTAssertEqual(src2.coverCalls, 0)
        XCTAssertFalse(vm2.covBackfilled)
    }

    // MARK: Img.movieCover 口径（E10：空 cover 拼 /covers/{id 前 2 位小写}/{id}.jpg）

    func testMovieCoverUrlFallback() {
        XCTAssertEqual(
            MovieImg.movieCover("", "ABC123"),
            CdnRewrite.jdbImgUrl("/covers/ab/ABC123.jpg"))
        XCTAssertEqual(MovieImg.movieCover("https://img.example/c.jpg", "ABC123"),
                       CdnRewrite.jdbImgUrl("https://img.example/c.jpg"))
        XCTAssertEqual(MovieImg.movieCover("", "ab"), "")   // id trim 后 length < 3 → ""
        XCTAssertEqual(MovieImg.preview(""), "")
    }

    // MARK: 相关资讯（B.8：失败静默空列表；副行「category · 日期前 10 位」拼接口径）

    @MainActor
    func testRelatedArticlesLoaded() async {
        let src = MockSource()
        src.responses = [moviePayload(id: "100001")]
        src.articles = [Row([
            "id": .string("400001"), "title": .string("演示资讯"),
            "category_name": .string("业界"), "released_at": .string("2026-10-01 10:00:00"),
        ])]
        let vm = makeVM(src)
        await vm.bind(mid: "100001")
        XCTAssertEqual(vm.relatedArticles.count, 1)
        XCTAssertEqual(vm.relatedArticles[0].s("id"), "400001")
    }

    // MARK: merged_into 解析（09 B8：mainId = merged_into.ifEmpty { aid }）

    func testMainIdResolution() {
        XCTAssertEqual(
            ActorDetailVM.mainIdOf(aid: "200001", row: Row(["merged_into": .string("200099")])),
            "200099")
        XCTAssertEqual(
            ActorDetailVM.mainIdOf(aid: "200001", row: Row(["merged_into": .string("")])),
            "200001")
        XCTAssertEqual(ActorDetailVM.mainIdOf(aid: "200001", row: nil), "200001")
        XCTAssertEqual(
            ActorDetailVM.mainIdOf(aid: "200001", row: Row(["merged_into": .null])),
            "200001")
    }
}
