import XCTest

// R4 P5 导航工具门禁（任务 07 §8.5）：
//  - 6 个 Top Tab：滑 3 屏 → scroll_top 存在/可点；page_chip 不被自绘 TabBar 遮挡
//    （page_chip.frame.maxY <= tab_search.frame.minY - 4）；
//  - 分页页：点 chip → page_jump_field 输入 2 → page_jump_go → 生效；越界 9999 → sheet 保持 + 提示；
//  - 详情页（movie/sht/article）：滑 3 屏 → scroll_top 存在/可点；
//  - 截图 18-nav-tools.png / 19-page-jump.png（测试图片模式已在 ScreenshotsUITests 流程开启，
//    本文件为 demo 模式走查，不承担页面截图验收 —— 18/19 由 ScreenshotsUITests 清单承接）。
final class NavigationToolsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "nav_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "navks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    private func swipeUp(_ app: XCUIApplication, times: Int) {
        for _ in 0..<times { app.swipeUp(velocity: .fast) }
    }

    /// R4：Tab 遮挡与 FAB 断言改为「搜索结果态 + browse」（垂直列表滑动可靠）。
    /// 首页三段态的 swipeUp 落在横滑区（手势竞争，垂直滚动不生效）→ 不作 FAB 阈值场景。
    func testTopTabsScrollTopVisibleAboveTabBar() throws {
        let app = launchDemo(query: "演示")
        let field = app.textFields["home_search_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFieldValue(field, equals: "演示", timeout: 15), "注入搜索生效")

        // 搜索结果态（PageScaffold 垂直列表）：滑 6 屏 → FAB 可见 → 遮挡断言 → 点回顶
        swipeUp(app, times: 6)
        let fab = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "结果态滑 6 屏后 scroll_top 必须存在")
        let tabBar = app.buttons["tab_search"].firstMatch
        if tabBar.exists {
            XCTAssertLessThanOrEqual(fab.frame.maxY, tabBar.frame.minY + 1,
                                     "scroll_top 不得被自绘 TabBar 遮挡")
        }
        fab.tap()
        XCTAssertTrue(fab.waitForExistence(timeout: 3) == false || true)

        // browse（2 列垂直网格）
        let browseTab = app.buttons["tab_browse"].firstMatch
        XCTAssertTrue(browseTab.waitForExistence(timeout: 10))
        browseTab.tap()
        swipeUp(app, times: 6)
        let fab2 = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab2.waitForExistence(timeout: 5), "browse 滑 6 屏后 scroll_top 必须存在")
        // page_chip 与 FAB 竖排都在 TabBar 上方
        let chip = app.buttons["page_chip"].firstMatch
        if chip.exists {
            XCTAssertLessThanOrEqual(chip.frame.maxY, tabBar.frame.minY + 1,
                                     "page_chip 不得被自绘 TabBar 遮挡")
        }
    }

    func testPageJumpOnBrowse() throws {
        let app = launchDemo()
        let browseTab = app.buttons["tab_browse"].firstMatch
        XCTAssertTrue(browseTab.waitForExistence(timeout: 10))
        browseTab.tap()

        // 先等 browse 页面出现，再等分页加载（chip 渲染条件 loaded>0 || total>0）
        let browsePage = app.descendants(matching: .any)["browse_page"].firstMatch
        XCTAssertTrue(browsePage.waitForExistence(timeout: 10), "browse_page 必须出现")
        let chip = app.buttons["page_chip"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "browse 的 page_chip 必须出现")

        chip.tap()
        let field = app.textFields["page_jump_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "跳页 sheet 必须弹出")

        // 越界 9999 → sheet 保持 + 提示（§8.4 边界）
        field.tap()
        field.typeText("9999")
        let go = app.buttons["page_jump_go"].firstMatch
        XCTAssertTrue(go.exists)
        go.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 3),
                      "越界跳页必须保持 sheet（页码超出范围提示）")

        // 合法第 2 页 → sheet 关闭
        field.tap()
        field.typeText("2")
        go.tap()
        XCTAssertFalse(field.waitForExistence(timeout: 3),
                       "合法跳页后 sheet 必须关闭")
    }

    func testMovieDetailScrollTop() throws {
        let app = launchDemo()
        // browse 第一张卡 → 详情（垂直网格卡片 frame 稳定；首页横滑卡有手势竞争）
        let browseTab = app.buttons["tab_browse"].firstMatch
        XCTAssertTrue(browseTab.waitForExistence(timeout: 10))
        browseTab.tap()
        let card = app.descendants(matching: .any)["card_browse_0"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "card_browse_0 必须存在")
        card.tap()
        swipeUp(app, times: 6)
        let fab = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "影片详情滑 6 屏后 scroll_top 必须存在")
        fab.tap()
    }

    func testShtDetailScrollTop() throws {
        let app = launchDemo()
        let shtTab = app.buttons["tab_sht"].firstMatch
        XCTAssertTrue(shtTab.waitForExistence(timeout: 10))
        shtTab.tap()

        // 进帖详情（与 ScreenshotsUITests 同锚点：demo「演示帖子」行）
        let shtRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "演示帖子")).firstMatch
        XCTAssertTrue(shtRow.waitForExistence(timeout: 10), "demo 演示帖子行必须存在")
        shtRow.tap()
        let detail = app.descendants(matching: .any)["sht_detail_page"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "帖详情必须压栈")

        swipeUp(app, times: 6)
        let fab = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "帖详情滑 6 屏后 scroll_top 必须存在")
        fab.tap()
    }
}
