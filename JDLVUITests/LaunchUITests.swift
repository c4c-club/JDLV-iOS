import XCTest

// P1 门禁：6 Tab 存在、逐个切换不崩溃。
final class LaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSixTabsPresentAndSwitchable() throws {
        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "tab bar not found")

        let labels = ["搜索", "浏览", "女优", "98t", "收藏", "设置"]
        for label in labels {
            let button = tabBar.buttons[label]
            XCTAssertTrue(button.exists, "missing tab: \(label)")
        }

        for label in labels {
            tabBar.buttons[label].tap()
            XCTAssertEqual(app.state, .runningForeground, "app crashed after tapping tab \(label)")
        }
    }
}
