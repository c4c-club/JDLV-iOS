import JDLVCore
import XCTest
@testable import JDLV

//
//  DesignTokenTests.swift —— P8 通用组件层设计 token 单测：
//  Tx 五级 / 色板关键 token / 组件尺寸常量（44/36/48/10/1/2/8）/ Lightbox 阈值 /
//  共享组件逐字文案冒烟 / DemoStore（DEBUG）API 冒烟。
//

final class DesignTokenTests: XCTestCase {

    // MARK: Tx 五级（07 全局排版契约：20/16/15/13/12 + 28/22/22/19/17）

    func testTxFiveLevels() {
        XCTAssertEqual(Tx.allCases.count, 5)
        XCTAssertEqual(Tx.titleL.size, 20)
        XCTAssertEqual(Tx.titleM.size, 16)
        XCTAssertEqual(Tx.body.size, 15)
        XCTAssertEqual(Tx.bodyS.size, 13)
        XCTAssertEqual(Tx.meta.size, 12)
        XCTAssertEqual(Tx.titleL.lineHeight, 28)
        XCTAssertEqual(Tx.titleM.lineHeight, 22)
        XCTAssertEqual(Tx.body.lineHeight, 22)
        XCTAssertEqual(Tx.bodyS.lineHeight, 19)
        XCTAssertEqual(Tx.meta.lineHeight, 17)
        // 最小 12pt
        XCTAssertTrue(Tx.allCases.allSatisfy { $0.size >= 12 })
    }

    func testTxWeights() {
        XCTAssertEqual(Tx.titleL.weight, .bold)
        XCTAssertEqual(Tx.titleM.weight, .semibold)
        XCTAssertEqual(Tx.body.weight, .regular)
        XCTAssertEqual(Tx.bodyS.weight, .regular)
        XCTAssertEqual(Tx.meta.weight, .regular)
    }

    // MARK: 色板关键 token（theme/Theme.kt 对位）

    func testPaletteKeyTokens() {
        XCTAssertEqual(Theme.dark.bg0, 0x0F1218)
        XCTAssertEqual(Theme.dark.bg3, 0x232A38)
        XCTAssertEqual(Theme.dark.line, 0x2E3648)
        XCTAssertEqual(Theme.light.bg0, 0xF2F5FA)
        XCTAssertEqual(Theme.light.bg3, 0xE7EBF3)
        XCTAssertEqual(Theme.sepia.bg0, 0xEFE6CF)
        XCTAssertEqual(Theme.accents.count, 6)
        XCTAssertEqual(Theme.accents.first?.hex, 0x7C5CFF)
        XCTAssertEqual(Theme.accentOf("未知"), 0x7C5CFF)   // 兜底紫
        // fallback：DARK + 紫（AppTheme.fallback）
        XCTAssertEqual(AppTheme.fallback().pal.bg0, Theme.dark.bg0)
    }

    // MARK: 组件尺寸常量（07 B 节 / 08 A.5 / 10 §0；任务要求 44/36/48/10/1/2/8 全覆盖）

    func testComponentMetrics() {
        // 搜索条 44pt（总高≈52）、圆角 22、清除钮 36
        XCTAssertEqual(ComponentMetrics.searchBarHeight, 44)
        XCTAssertEqual(ComponentMetrics.searchBarBlockHeight, 52)
        XCTAssertEqual(ComponentMetrics.searchBarRadius, 22)
        XCTAssertEqual(ComponentMetrics.searchClearButton, 36)
        // chips / 下拉 36pt；最小触控 36（按钮 48）
        XCTAssertEqual(ComponentMetrics.chipHeight, 36)
        XCTAssertEqual(ComponentMetrics.dropdownHeight, 36)
        XCTAssertEqual(ComponentMetrics.touchMin, 36)
        XCTAssertEqual(ComponentMetrics.buttonMin, 48)
        // 卡片：1pt 描边 + 2pt 投影 + 内边距 8pt；容器圆角 12
        XCTAssertEqual(ComponentMetrics.cardStroke, 1)
        XCTAssertEqual(ComponentMetrics.cardElevation, 2)
        XCTAssertEqual(ComponentMetrics.cardPadding, 8)
        XCTAssertEqual(ComponentMetrics.cardCorner, 12)
        // 图片圆角 10pt
        XCTAssertEqual(ComponentMetrics.imageCorner, 10)
        // 骨架：行高 180、呼吸 0.25→0.55、0.7s 线性
        XCTAssertEqual(ComponentMetrics.skeletonRowHeight, 180)
        XCTAssertEqual(ComponentMetrics.skeletonAlphaMin, 0.25)
        XCTAssertEqual(ComponentMetrics.skeletonAlphaMax, 0.55)
        XCTAssertEqual(ComponentMetrics.skeletonAnimDuration, 0.7)
        // 下拉刷新阈值 64 / 恢复横幅 6000ms
        XCTAssertEqual(ComponentMetrics.refreshThreshold, 64)
        XCTAssertEqual(ComponentMetrics.restoredBannerMs, 6000)
    }

    // MARK: Lightbox 阈值（10 §1.5：双击 2.5x、捏合 1–6x、复位 1.5、左右 30%/70%）

    func testLightboxMetrics() {
        XCTAssertEqual(LightboxMetrics.doubleTapZoom, 2.5)
        XCTAssertEqual(LightboxMetrics.minZoom, 1)
        XCTAssertEqual(LightboxMetrics.maxZoom, 6)
        XCTAssertEqual(LightboxMetrics.zoomedThreshold, 1.5)
        XCTAssertEqual(LightboxMetrics.prevTapZone, 0.3)
        XCTAssertEqual(LightboxMetrics.nextTapZone, 0.7)
        XCTAssertEqual(LightboxMetrics.pageIndicatorOpacity, 0.75)
        XCTAssertEqual(LightboxMetrics.emptyColorHex, 0x9AA0AD)
    }

    // MARK: 共享组件逐字文案冒烟（全角/半角差异）

    func testSharedCopyExact() {
        // 下拉刷新四态（07 B10）
        XCTAssertEqual(AppCopy.refreshTextRefreshing, "正在刷新…")
        XCTAssertEqual(AppCopy.refreshTextPull, "下拉可以刷新")
        XCTAssertEqual(AppCopy.refreshTextRelease, "松开立即刷新")
        // 刷新结果 Toast（全角冒号）
        XCTAssertEqual(AppCopy.refreshDoneToast(3), "✓ 刷新完成 · 共 3 条")
        XCTAssertEqual(AppCopy.refreshFailToast("很长的错误信息"),
                       "刷新失败：\(String("很长的错误信息".prefix(40)))")
        // 横幅（07 A5；半角括号 + 全角冒号）
        XCTAssertEqual(AppCopy.offlineBanner("javdb · 98t"),
                       "⚠ 远程库不可达：javdb · 98t — 正在显示缓存数据 (恢复后下拉刷新)")
        XCTAssertEqual(AppCopy.restoredBanner, "✓ 网络已恢复 — 下拉刷新查看最新数据")
        // 状态框
        XCTAssertEqual(AppCopy.errorIcon, "⚠️")
        XCTAssertEqual(AppCopy.emptyIcon, "🗂")
        XCTAssertEqual(AppCopy.retryButton, "重试")
        // AppSwitchRow 徽标
        XCTAssertEqual(AppCopy.switchOnBadge, "已开启")
        XCTAssertEqual(AppCopy.switchOffBadge, "已关闭")
        // LoadMoreFooter
        XCTAssertEqual(AppCopy.loadMore, "加载更多")
        XCTAssertEqual(AppCopy.noMore, "没有更多了")
        XCTAssertEqual(AppCopy.loadedLine(loaded: 5, total: 100, approx: false), "已加载 5 / 100")
        XCTAssertEqual(AppCopy.loadedLine(loaded: 5, total: 100, approx: true), "已加载 5 · 约 100 条")
        XCTAssertEqual(AppCopy.loadedLine(loaded: 5, total: -1, approx: false), "已加载 5 条")
        // PageChip / 跳页对话框（全角「·」+ 半角括号 / 半角逗号+空格）
        XCTAssertEqual(AppCopy.pageChipLabel(loaded: 40, total: 120), "40 / 120")
        XCTAssertEqual(AppCopy.pageChipLabel(loaded: 40, total: -1), "40 / ?")
        XCTAssertEqual(AppCopy.pageJumpTitle, "跳转页码")
        XCTAssertEqual(AppCopy.pageJumpPlaceholder, "输入页码")
        XCTAssertEqual(AppCopy.pageJumpGo, "跳转")
        XCTAssertEqual(AppCopy.pageJumpCancel, "取消")
        XCTAssertEqual(AppCopy.pageJumpBodyKnown(loaded: 80, total: 120, per: 40),
                       "已加载 80 / 120 · 共 3 页 (每页 40 条)")
        XCTAssertEqual(AppCopy.pageJumpBodyUnknown(loaded: 40, per: 40),
                       "已加载 40 条 · 总数未知 (每页 40 条), 可直接输入页码")
        XCTAssertEqual(AppCopy.tooDeepToast(maxPage: 125),
                       "跳页过深（最多约 125 页），请用滚动加载")
        // PosterImage 失败文案
        XCTAssertEqual(AppCopy.posterFailedRetry, "加载失败 · 点击重试")
        // 卡片元信息（顺序与条件逐字）
        XCTAssertEqual(AppCopy.movieMetaParts(releaseDate: "2024-01-15", wantWatch: 3,
                                              magnets: 2, fav: true).joined(separator: " · "),
                       "2024-01-15 · 想看 3 · 磁 2 · ★已收藏")
        XCTAssertEqual(AppCopy.shtMetaParts(postDate: "2026-01-01", boardName: "有码中文字幕",
                                            magnetCount: 0, fav: false),
                       "2026-01-01 · 有码中文字幕")
        // ActorCard（「N 部」+ ·★均分 %.2f）
        XCTAssertEqual(AppCopy.actorMetaLine(videosCount: 12, avgScoreAll: 4.5), "12 部 · ★4.50")
        XCTAssertEqual(AppCopy.actorMetaLine(videosCount: 12, avgScoreAll: 0), "12 部")
        // 视图三档
        XCTAssertEqual([AppCopy.viewSmall, AppCopy.viewLarge, AppCopy.viewList],
                       ["小图", "大图", "列表"])
        // 反查兜底
        XCTAssertEqual(AppCopy.lookupInvalid, "反查参数无效")
        XCTAssertEqual(AppCopy.lookupInvalidHint, "按返回键重试")
        XCTAssertEqual(AppCopy.lookupDefaultLabel, "反查")
    }

    // MARK: RefreshResult 通道

    func testRefreshResultToasts() {
        XCTAssertEqual(RefreshResult.done(7).toastText, "✓ 刷新完成 · 共 7 条")
        let fail = RefreshResult.fail(String(repeating: "错", count: 50))
        XCTAssertEqual(fail.toastText, "刷新失败：\(String(repeating: "错", count: 40))")
    }

    // MARK: Route（路由枚举 Hashable + 每 Tab path 独立）

    @MainActor
    func testRouterPathsIndependent() {
        let r = Router()
        XCTAssertEqual(Router.tabs, ["search", "browse", "actors", "sht", "favs", "settings"])
        XCTAssertEqual(r.tab, Router.startTab)
        r.tab = "browse"
        r.push(.movie("100001"))
        r.push(.actor("200001"))
        XCTAssertEqual(r.path(for: "browse").count, 2)
        XCTAssertEqual(r.path(for: "search").count, 0)   // 其他 Tab 栈不受影响
        r.pop()
        XCTAssertEqual(r.path(for: "browse").count, 1)
        r.tab = "search"
        r.push(.lookup("abc"))
        XCTAssertEqual(r.path(for: "search").count, 1)
    }

    // MARK: DemoStore（仅 DEBUG；签名固定 + 合成规模下限）

    #if DEBUG
    func testDemoStoreSeededByLaunchArg() {
        // 测试进程未带 -JDLV_DEMO → 关闭（开关本身可单测的部分）
        XCTAssertFalse(DemoDataSource.enabled())
    }

    @MainActor
    func testDemoStoreDataAndApis() {
        let store = DemoStore.shared
        // 首页三段
        let home = store.homeSections(per: 12)
        XCTAssertEqual(home["recent"]?.count, 12)
        XCTAssertEqual(home["hot"]?.count, 12)
        XCTAssertEqual(home["top"]?.count, 12)
        XCTAssertGreaterThanOrEqual(home["top"]?.first?.i("rank") ?? 0, 1)
        // 影片行关键列名（与真实库一致）
        let m = home["recent"]?.first
        XCTAssertFalse(m?.s("id").isEmpty ?? true)
        XCTAssertFalse(m?.s("number").isEmpty ?? true)
        XCTAssertTrue(m?.s("title").hasPrefix("演示影片 ") ?? false)
        XCTAssertFalse(m?.s("release_date").isEmpty ?? true)
        // browse
        let browse = store.browse(f: Filters(letter: "abc"), page: 1, per: 40,
                                  sort: "release_date", asc: false)
        let items = browse["items"] as? [Row]
        XCTAssertNotNil(items)
        XCTAssertLessThanOrEqual(items?.count ?? 99, 40)
        // movie / actor / actorMovies
        let mid = items?.first?.s("id") ?? ""
        if !mid.isEmpty {
            XCTAssertEqual(store.movie(mid: mid)?.s("id"), mid)
        }
        let actors = store.actors(page: 1, per: 30, sort: "videos", gender: "f", q: "")
        XCTAssertGreaterThanOrEqual(actors.count, 1)
        XCTAssertLessThanOrEqual(actors.count, 30)
        XCTAssertFalse(actors.first?.s("name").isEmpty ?? true)
        if let aid = actors.first?.s("id") {
            XCTAssertNotNil(store.actor(aid: aid))
            XCTAssertGreaterThanOrEqual(store.actorMovies(aid: aid, page: 1).count, 0)
        }
        // 98t / 资讯 / 热评 / TOP250
        let threads = store.shtList(main: "", cat: "", type: "", q: "", page: 1, per: 20)
        XCTAssertGreaterThanOrEqual(threads.count, 1)
        if let tid = threads.first?.s("tid") {
            XCTAssertNotNil(store.shtThread(tid: tid))
        }
        let articles = store.articles(page: 1, categoryId: "", q: "")
        XCTAssertGreaterThanOrEqual(articles.count, 1)
        if let aid = articles.first?.s("id") {
            XCTAssertNotNil(store.article(aid: aid))
        }
        XCTAssertGreaterThanOrEqual(store.hotReviews(period: "weekly", key: "", page: 1).count, 1)
        XCTAssertGreaterThanOrEqual(store.top250Years().count, 1)
        let t250 = store.top250(year: "", page: 1)
        XCTAssertGreaterThanOrEqual(t250.count, 1)
        // 合成规模下限（线程安全直查 COUNT）
        XCTAssertGreaterThanOrEqual(DemoStore.movieCount, 120)
        XCTAssertGreaterThanOrEqual(DemoStore.actorCount, 60)
        XCTAssertGreaterThanOrEqual(DemoStore.threadCount, 80)
        XCTAssertGreaterThanOrEqual(DemoStore.articleCount, 20)
        XCTAssertGreaterThanOrEqual(DemoStore.hotReviewCount, 20)
        XCTAssertEqual(DemoStore.top250Count, 25)
        // 收藏三分类
        XCTAssertEqual(store.favList(kind: "movie").count, 3)
        XCTAssertEqual(store.favList(kind: "sht").count, 2)
        XCTAssertEqual(store.favList(kind: "actor").count, 2)
    }
    #endif
}
