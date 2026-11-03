import XCTest

// P8 门禁：-JDLV_DEMO 1 演示数据启动；6 Tab 存在、逐个切换不崩溃；
// 首页 push 一个二级详情页再返回（压栈验证；Tab 切换保留状态由独立 NavigationStack 保证）。
final class LaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1"]
        app.launch()
        return app
    }

    func testSixTabsPresentAndSwitchable() throws {
        let app = launchDemo()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "tab bar not found")

        let labels = ["搜索", "浏览", "女优", "98t", "收藏", "设置"]
        for label in labels {
            let button = tabBar.buttons[label]
            XCTAssertTrue(button.exists, "missing tab: \(label)")
        }

        // 逐个切换（含回到首页），全程不崩溃
        for label in labels {
            tabBar.buttons[label].tap()
            XCTAssertEqual(app.state, .runningForeground, "app crashed after tapping tab \(label)")
        }
        tabBar.buttons["搜索"].tap()
    }

    func testHomePushMovieDetailAndBack() throws {
        let app = launchDemo()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "tab bar not found")

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
}
