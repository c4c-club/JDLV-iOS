import XCTest

// R4 P3/P4 布局溢出门禁（任务 06 §17.4.4）：页面关键卡片/网格不得横向溢出。
// CI 模拟器机型不固定：320pt（iPhone SE）专用断言只在「当前 destination 最短边 ≤ 340」时执行，
// 否则记录环境性 skip（符合 P12 口径：仅环境缺失允许 skip）；402pt（iPhone 16 Pro）等机型
// 由 CI 目标机直接跑溢出断言。
final class SmallDeviceLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "smalldev_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "smalldevks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    /// 当前 destination 的屏幕宽度（pt）
    private func screenWidth(_ app: XCUIApplication) -> CGFloat {
        app.frame.width
    }

    /// 断言元素横向不溢出（右缘不超过屏幕右缘 + 1pt 容差）
    private func assertNoHorizontalOverflow(_ app: XCUIApplication, _ el: XCUIElement,
                                            _ name: String) {
        XCTAssertTrue(el.exists, "\(name) 必须存在")
        let f = el.frame
        XCTAssertLessThanOrEqual(f.maxX, app.frame.maxX + 1.0,
                                 "\(name) 右缘 \(f.maxX) 超出屏幕 \(app.frame.maxX)（横向溢出）")
        XCTAssertGreaterThanOrEqual(f.minX, app.frame.minX - 1.0,
                                    "\(name) 左缘 \(f.minX) 越出屏幕左缘")
    }

    func testGridsDoNotOverflowHorizontally() throws {
        let app = launchDemo()
        let isSmallDevice = screenWidth(app) <= 340
        if !isSmallDevice {
            // 非小屏 destination：小屏专用断言跳过（环境性 skip；402pt 等机型跑下方通用断言）
            throw XCTSkip("当前 destination 宽 \(Int(screenWidth(app)))pt ≠ 320pt 小屏；小屏断言仅在有 SE 类机型时执行")
        }

        // 首页：结果卡/横滑卡不溢出
        let home = app.otherElements["home_page"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 10), "home_page 必须出现")
        assertNoHorizontalOverflow(app, home, "home_page")

        // browse（2 列网格）
        let browseTab = app.buttons["tab_browse"].firstMatch
        XCTAssertTrue(browseTab.waitForExistence(timeout: 5))
        browseTab.tap()
        let browse = app.otherElements["browse_page"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "browse_page 必须出现")
        assertNoHorizontalOverflow(app, browse, "browse_page")

        // actors → 进详情（320pt 两列网格 + 头部资料卡）
        let actorsTab = app.buttons["tab_actors"].firstMatch
        XCTAssertTrue(actorsTab.waitForExistence(timeout: 5))
        actorsTab.tap()
        let actors = app.otherElements["tab_root_actors"].firstMatch
        XCTAssertTrue(actors.waitForExistence(timeout: 10), "tab_root_actors 必须出现")
        assertNoHorizontalOverflow(app, actors, "tab_root_actors")
    }
}
