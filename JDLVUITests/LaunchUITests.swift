import XCTest

// P8 门禁：-JDLV_DEMO 1 演示数据启动；6 Tab 存在、逐个切换不崩溃；
// 首页 push 一个二级详情页再返回（压栈验证；Tab 切换保留状态由独立 NavigationStack 保证）。
final class LaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private let tabs: [(String, String)] = [
        ("搜索", "search"), ("浏览", "browse"), ("女优", "actors"),
        ("98t", "sht"), ("收藏", "favs"), ("设置", "settings")]

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        // A9/R8：独立 defaults suite + 独立 Keychain service（防跨用例持久污染）
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    func testSixTabsPresentAndSwitchable() throws {
        let app = launchDemo()

        for (label, route) in tabs {
            if !tabExists(app, label, route) {
                let n = app.buttons.count
                var dump = "app buttons (n=" + String(n) + "): "
                for i in 0..<min(n, 40) {
                    let b = app.buttons.element(boundBy: i)
                    dump += "[" + String(i) + "] label='" + b.label + "' id='" + b.identifier + "'; "
                }
                XCTFail("missing tab: " + label + " :: " + dump)
            }
        }

        // 逐个切换（含回到首页），全程不崩溃
        for (label, route) in tabs {
            tabLabeled(app, label, route).tap()
            XCTAssertEqual(app.state, .runningForeground, "app crashed after tapping tab \(label)")
        }
        tabLabeled(app, "搜索", "search").tap()
    }

    func testHomePushMovieDetailAndBack() throws {
        let app = launchDemo()

        XCTAssertTrue(tabExists(app, "搜索", "search"), "tab bar not found")

        // 首页（搜索 Tab）压栈一个二级详情页（demo 模式 = 第一张影片卡）
        let push = app.descendants(matching: .any)["home_push_movie"].firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 15), "home push element not found")
        push.tap()

        let secondary = app.descendants(matching: .any)["secondary_page"].firstMatch
        XCTAssertTrue(secondary.waitForExistence(timeout: 10), "secondary page not pushed")

        // 返回逐层回首页（压栈语义：绝不 pop 掉首页）
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "back button not found")
        back.tap()

        XCTAssertTrue(push.waitForExistence(timeout: 10), "home not restored after back")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // iOS 18.5 模拟器 tab 按钮的 label/identifier 偶发不等于标题 → label 直查 + 全量索引扫描双路
    // tab_<route> 唯一且稳定；label 查询会与隐藏 Tab 内容多匹配 → 永远用 identifier
    private func tabLabeled(_ app: XCUIApplication, _ label: String, _ route: String) -> XCUIElement {
        let byId = app.buttons["tab_" + route]
        if byId.waitForExistence(timeout: 5) { return byId }
        let n = app.buttons.count
        for i in 0..<n {
            let b = app.buttons.element(boundBy: i)
            if b.identifier.contains("tab_" + route) { return b }
        }
        return app.buttons[label].firstMatch
    }

    private func tabExists(_ app: XCUIApplication, _ label: String, _ route: String,
                           timeout: TimeInterval = 5) -> Bool {
        if app.buttons["tab_" + route].waitForExistence(timeout: timeout) { return true }
        for _ in 0..<6 {
            let n = app.buttons.count
            for i in 0..<n {
                let b = app.buttons.element(boundBy: i)
                if b.identifier.contains("tab_" + route) { return true }
            }
            usleep(500_000)
        }
        return false
    }
}
