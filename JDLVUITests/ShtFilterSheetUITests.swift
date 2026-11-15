import XCTest

/// R6 PHASE3：98t 主版筛选「有选项且可点选」UI 出口测试（任务 04）。
/// VM 层断言（选项>0、setMain 查询参数、兜底可点选）在 ShtVMTests；
/// 本测试验证真实 sheet 渲染与点选链路（点开 Picker → 选项行 → 回选 → 关闭）。
final class ShtFilterSheetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testShtFilterSheetMainOptionsExistAndSelectable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "uitest_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "ks_\(UUID().uuidString.prefix(8))"]
        app.launch()

        XCTAssertTrue(app.buttons["tab_sht"].waitForExistence(timeout: 20), "tab bar not found")
        let grid = app.descendants(matching: .any)["sht_grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 45), "98t grid not rendered")

        app.buttons["sht_filter_button"].firstMatch.tap()
        let mainPicker = app.descendants(matching: .any)["sht_main_picker"].firstMatch
        XCTAssertTrue(mainPicker.waitForExistence(timeout: 15), "筛选 sheet 未渲染主版 Picker")

        // 选项 > 0 且可点选：Form 内 Picker（iPhone 默认 nav 风格）点开 → 选项行出现。
        // CI demo 走远程分类（shtCategories mock 对位 demo 聚合，首行 = 有码中文字幕）。
        mainPicker.tap()
        let option = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "有码中文字幕")).firstMatch
        if option.waitForExistence(timeout: 8) {
            option.tap()
        } else {
            // nav 风格在不同 OS 上呈现差异：选项行可能是静态文本/other 节点
            let alt = app.descendants(matching: .any)
                .containing(NSPredicate(format: "label CONTAINS %@", "有码中文字幕")).firstMatch
            XCTAssertTrue(alt.waitForExistence(timeout: 8), "主版选项未出现（选项数=0 的旧缺陷）")
            alt.tap()
        }

        let done = app.buttons["sht_filter_done"].firstMatch
        if done.waitForExistence(timeout: 6) {
            done.tap()
        } else {
            app.swipeDown(velocity: .fast)   // 兜底关 sheet
        }
        XCTAssertTrue(app.descendants(matching: .any)["sht_grid"].firstMatch
            .waitForExistence(timeout: 10), "关闭 sheet 后列表未恢复")
    }
}
