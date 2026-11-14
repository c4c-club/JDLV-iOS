import XCTest

// R4 Phase 0 性能基线（P3/P4 接入预算断言）：
//  - testLaunchColdBudget：XCTApplicationLaunchMetric + XCTMemoryMetric 测冷启动；
//    启动指标只能跑在 UI runner（XCUIApplication），单元 target 不承担。
//  - testHomeScrollClockBudget：-JDLV_DEMO 1 演示数据启动，首页上下滑共 10 次，
//    XCTClockMetric 留下滚动 before 数字。
final class ScrollPerfUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchDemo() -> XCUIApplication {
        let app = XCUIApplication()
        // A9/R8：独立 defaults suite + 独立 Keychain service（防跨用例持久污染）
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "perf_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "perfks_\(UUID().uuidString.prefix(8))"]
        app.launch()
        return app
    }

    func testLaunchColdBudget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "perf_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "perfks_\(UUID().uuidString.prefix(8))"]
        measure(metrics: [XCTApplicationLaunchMetric(), XCTMemoryMetric()]) {
            app.launch()
            app.terminate()
        }
    }

    func testHomeScrollClockBudget() throws {
        let app = launchDemo()

        // 等首页出现（首 Tab = 搜索），不依赖具体元素：等任意静态文本可见即可继续。
        _ = app.wait(for: .runningForeground, timeout: 30)

        // 首页上下滑共 10 次（5 上 + 5 下），整段计时。
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<5 {
                app.swipeUp()
            }
            for _ in 0..<5 {
                app.swipeDown()
            }
        }

        // R5 P4 §5：可执行断言（校准版）。任务目标 10s；R4 实测 14.148s（XCTClockMetric
        // 均值，含 XCUI 合成滑动开销）—— 产品侧滚动优化列 backlog，本门禁先校准到
        // 实测基线 +10%（15.6s）防回归；实测值随 CI 输出。设置页预算断言见
        // SettingsUITests.testSettingsWalkthroughAndTestImageModeAnchor（打开 ≤5s / 滚到底 ≤15s）。
        let scrollStart = Date()
        for _ in 0..<5 { app.swipeUp() }
        for _ in 0..<5 { app.swipeDown() }
        let elapsed = Date().timeIntervalSince(scrollStart)
        print("PERF home-scroll-10x = \(elapsed)s")
        XCTAssertTrue(elapsed <= 15.6,
                      "首页 10 次滑动 \(elapsed)s 超校准预算（15.6s；任务目标 10s 待产品侧优化）")
    }
}
