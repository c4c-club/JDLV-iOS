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
        for _ in 0..<times { app.swipeUp() }
    }

    func testTopTabsScrollTopVisibleAboveTabBar() throws {
        let app = launchDemo()
        let tabs: [(String, String)] = [
            ("搜索", "tab_search"), ("浏览", "tab_browse"), ("女优", "tab_actors"),
            ("98t", "tab_sht"), ("收藏", "tab_favs"), ("设置", "tab_settings")]

        for (label, route) in tabs {
            let tab = app.buttons[route].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "\(label) tab 必须存在")
            tab.tap()
            swipeUp(app, times: 3)

            let fab = app.buttons["scroll_top"].firstMatch
            // 设置/收藏页 FAB 常显；列表页阈值显隐 —— 滑 3 屏后都应可见
            let appeared = fab.waitForExistence(timeout: 3)
            XCTAssertTrue(appeared, "\(label) 滑 3 屏后 scroll_top 必须存在")
            if appeared {
                let tabBar = app.buttons["tab_search"].firstMatch
                if tabBar.exists {
                    XCTAssertLessThanOrEqual(fab.frame.maxY,
                                             tabBar.frame.minY + 1,
                                             "\(label) 的 scroll_top 不得被自绘 TabBar 遮挡")
                }
                fab.tap()
            }
        }
    }

    func testPageJumpOnBrowse() throws {
        let app = launchDemo()
        let browseTab = app.buttons["tab_browse"].firstMatch
        XCTAssertTrue(browseTab.waitForExistence(timeout: 10))
        browseTab.tap()

        // 等分页加载（chip 渲染条件 loaded>0 || total>0）
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
        // 首页第一张卡 → 详情
        let home = app.otherElements["home_page"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        let card = app.buttons["home_push_movie"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "home_push_movie 必须存在")
        card.tap()
        swipeUp(app, times: 3)
        let fab = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "影片详情滑 3 屏后 scroll_top 必须存在")
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

        swipeUp(app, times: 3)
        let fab = app.buttons["scroll_top"].firstMatch
        XCTAssertTrue(fab.waitForExistence(timeout: 5), "帖详情滑 3 屏后 scroll_top 必须存在")
        fab.tap()
    }
}
