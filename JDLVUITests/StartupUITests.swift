import XCTest

// R4 P3 门禁：按需挂载 Tab 下的启动与切 Tab 行为。
//  1) -JDLV_DEMO 1 启动 2s 内 home_search_field 可见（首屏不被隐藏 Tab 的查询拖死）；
//  2) 切到 browse 再返回 search，搜索词状态保留（访问过的 Tab 不重建、单实例栈）。
// 注：搜索词用 -JDLV_TEST_SEARCH 注入（B2 typeText 字符丢失规避），不做键盘输入。
final class StartupUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo(query: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-JDLV_DEMO", "1",
                    "-JDLV_DEFAULTS_SUITE", "startup_\(UUID().uuidString.prefix(8))",
                    "-JDLV_KEYCHAIN_SERVICE", "startupks_\(UUID().uuidString.prefix(8))"]
        if let query {
            args += ["-JDLV_TEST_SEARCH", query]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// 轮询等待字段值等于期望（XCUI 无值级 wait；UI 测试环境无主线程阻塞问题）
    @discardableResult
    private func waitFieldValue(_ field: XCUIElement, equals expected: String,
                                timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (field.value as? String) == expected { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return (field.value as? String) == expected
    }

    func testHomeVisibleWithin2s() throws {
        let app = launchDemo()
        let field = app.textFields["home_search_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2),
                      "启动 2s 内 home_search_field 必须可见（懒挂载后首屏不再被 5 个隐藏 Tab 拖死）")
    }

    func testTabSwitchKeepsSearchState() throws {
        let app = launchDemo(query: "演示")

        let field = app.textFields["home_search_field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "home_search_field 必须出现")
        XCTAssertTrue(waitFieldValue(field, equals: "演示", timeout: 10),
                      "注入搜索词应回填输入框（首屏数据通路正常）")

        let browseTab = app.buttons["tab_browse"].firstMatch
        XCTAssertTrue(browseTab.waitForExistence(timeout: 5), "tab_browse 必须存在")
        browseTab.tap()

        // 返回 search：字段与注入的查询词必须保留（懒挂载不重建已访问 Tab）
        let searchTab = app.buttons["tab_search"].firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5), "tab_search 必须存在")
        searchTab.tap()

        let field2 = app.textFields["home_search_field"].firstMatch
        XCTAssertTrue(field2.waitForExistence(timeout: 5), "返回 search 后输入框必须仍在")
        XCTAssertEqual(field2.value as? String, "演示",
                       "Tab 切换后搜索词必须保留（search Tab 未被重建）")
    }
}
