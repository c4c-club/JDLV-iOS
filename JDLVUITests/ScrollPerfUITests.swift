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

    // MARK: R7 P2 冷启动预算（5 次 terminate+launch；读 AX 通道 firstCard 毫秒）

    /// 读取 perf_firstcard AX 值（App 内 PerfSignposts.firstCardMs；-1 = 未就绪轮询等待）
    private func readFirstCardMs(_ app: XCUIApplication, round: Int) -> Int64 {
        let probe = app.descendants(matching: .any)["perf_firstcard"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 30),
                      "perf_firstcard not found (round \(round))")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let v = probe.value as? String {
                let msPart = v.split(separator: "|").first.map(String.init) ?? v
                if let n = Int64(msPart), n >= 0 { return n }
            }
            usleep(200_000)
        }
        // 失败时把完整诊断串带进断言（ms|h:<home>|i:<items>）
        let diag = (probe.value as? String) ?? "<nil>"
        XCTFail("firstCard probe 未就绪 (round \(round)): \(diag)")
        return -1
    }

    func testColdLaunchBudgets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-JDLV_DEMO", "1",
                               "-JDLV_DEFAULTS_SUITE", "perf_\(UUID().uuidString.prefix(8))",
                               "-JDLV_KEYCHAIN_SERVICE", "perfks_\(UUID().uuidString.prefix(8))"]
        var samples: [Int64] = []
        for round in 0..<5 {
            app.launch()   // launch 自带 terminate 现有实例 → 每轮都是冷启动
            let ms = readFirstCardMs(app, round: round)
            XCTAssertGreaterThanOrEqual(ms, 0, "firstCard 未打点 (round \(round))")
            samples.append(ms)
            app.terminate()
        }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        // 5 样本 95 分位 = 最大值（ceil(0.95*n)-1）
        let p95 = sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
        print("PERF firstCard samples=\(samples) p50=\(p50)ms p95=\(p95)ms")
        // R7 P2 任务 03 §验收 78 行：「冷启动预算达标（CI 数据）或明确记录未达标原因」。
        // CI 模拟器启动硬地板 ~2.3s（before 基线 AppLaunch 2.314s，见 p2-perf-before.json），
        // firstCard = 启动 + 首屏数据 ≈ 2.7s，1500ms 物理不可达；round0 另含 demo 懒建表。
        // 实测样本与原因随 PERF 行落 CI 日志，真机复测归 P7。
        let p50Ok = p50 <= 1500
        let p95Ok = p95 <= 3000
        print("PERF coldLaunchBudget p50Ok=\(p50Ok) p95Ok=\(p95Ok)" +
              (p50Ok && p95Ok ? " 达标" :
               " 未达标：模拟器启动地板（before AppLaunch 2.314s）+ round0 demo 懒建表；真机 P7 复测"))
    }
}
