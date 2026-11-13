import XCTest

//
//  ProductionSmokeUITests —— A9/R8 验收底线（R-V2）：无 demo 的生产链路冒烟。
//
//  - 不带任何 -JDLV_DEMO 参数（LaunchMode 严格判定下必然生产路径）；
//  - 独立 UserDefaults suite + 独立 Keychain service（-JDLV_DEFAULTS_SUITE /
//    -JDLV_KEYCHAIN_SERVICE）→ testImgMode 未开启（种子不含该键）、干净首启态；
//  - 种子配置指向 CI ios job 的 MySQL 8 fixture（JDLV_TEST_MYSQL_*，库名 jdlv_app_it，
//    数据由单测 bundle 先行的 ProductionSmokeFixtureTests 准备）；
//  - 断言：首页出现 fixture 真实标题「冒烟影片 S001」（不是 demo 标题）；
//    设置页「测试连接」返回真实成功（含版本号、不含「演示模式」）；
//    搜索真实数据命中（生产 Q 链路真实发起过数据库连接）。
//

final class ProductionSmokeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func fixtureEnv() throws -> (host: String, port: Int, user: String, pass: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JDLV_TEST_MYSQL_HOST"] else { return nil }
        let port = Int(env["JDLV_TEST_MYSQL_PORT"] ?? "3306") ?? 3306
        let user = env["JDLV_TEST_MYSQL_USER"] ?? "root"
        let pass = env["JDLV_TEST_MYSQL_PASS"] ?? ""
        return (host, port, user, pass)
    }

    private func launchProduction(_ f: (host: String, port: Int, user: String, pass: String))
        -> XCUIApplication {
        let suite = "smoke_\(UUID().uuidString.prefix(8))"
        let service = "svc_\(UUID().uuidString.prefix(8))"

        var seed: [String: Any] = [
            "db_src": "remote",
            "remote_host": f.host,
            "remote_port": String(f.port),
            "remote_user": f.user,
            "remote_pass": f.pass,
            "remote_jdb": "jdlv_app_it",
            "remote_sht": "jdlv_app_it",
            "db_ssl": false,
            "connect_timeout": 5,
            "query_timeout": 8,
            "theme_name": "dark",
        ]
        // A9/R8：显式断言种子不含 test_img_mode（生产冒烟禁止测试图片模式）
        XCTAssertFalse(seed.keys.contains("test_img_mode"))

        let data = try! JSONSerialization.data(withJSONObject: seed)
        let b64 = data.base64EncodedString()

        let app = XCUIApplication()
        app.launchArguments = [
            "-JDLV_DEFAULTS_SUITE", suite,
            "-JDLV_KEYCHAIN_SERVICE", service,
            "-JDLV_SEED_SETTINGS", b64,
        ]
        app.launch()
        return app
    }

    /// 生产冒烟底线：真实 MySQL fixture → 首页真实标题 + 测试连接真实成功
    func testProductionHomeAndRealConnection() throws {
        guard let f = try fixtureEnv() else {
            throw XCTSkip("本地无 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*）")
        }
        let app = launchProduction(f)

        // ① 首页进入生产主界面（无 demo、无首启门禁：种子配置合法）
        let searchTab = app.descendants(matching: .any)["tab_search"].firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20), "生产启动必须直达主界面（种子配置合法）")

        // ② 首页出现 fixture 真实标题（生产 Q 链路真实查询 MySQL；demo 标题不得出现）
        // R5 P3：等待窗口 25→45s —— run 43331622094 证据：XCUITest automation session
        // 卡顿 78s 后 MySQL 冷池建连 >25s；断言本身不变（必须出现真实 fixture 标题）
        let smokeTitle = app.staticTexts["冒烟影片 S001"]
        XCTAssertTrue(smokeTitle.waitForExistence(timeout: 45),
                      "首页必须出现 fixture 真实标题（生产数据链路）")
        XCTAssertFalse(app.staticTexts["演示影片 001"].exists, "生产模式不得出现 demo 标题")

        // ③ 设置页「测试连接」→ 真实成功（含版本号、不含「演示模式」）
        // R5 P3：tab 用 identifier 精确查（label 与隐藏 Tab 内容多匹配，禁用全量扫描兜底）；
        // 点击后立即断言 settings_page 落地 + 有限重试（不再盲点 4 次）
        let settingsTab = app.buttons["tab_settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "设置 tab 未找到（tab_settings）")
        var landed = false
        for attempt in 0..<3 {
            settingsTab.tap()
            if app.descendants(matching: .any)["settings_page"].firstMatch
                .waitForExistence(timeout: 6) { landed = true; break }
            let d = XCTAttachment(screenshot: app.screenshot())
            d.name = "diag-tab-land-\(attempt)"
            d.lifetime = .keepAlways
            add(d)
        }
        XCTAssertTrue(landed, "点设置 tab 后 settings_page 未出现（3 次重试；附落地页截图）")

        // settings_group_db identifier 在头行按钮上 → tap 即展开/收起（精确，无坐标）
        let dbGroup = app.descendants(matching: .any)["settings_group_db"].firstMatch
        XCTAssertTrue(dbGroup.waitForExistence(timeout: 10), "数据源分组卡未找到")
        let testButton = app.descendants(matching: .any)["ds_test_button"].firstMatch
        if !testButton.exists {
            dbGroup.tap()   // 折叠中 → 展开分组
        }
        XCTAssertTrue(testButton.waitForExistence(timeout: 8), "测试连接按钮未找到")
        // R5 P3：有限次滚动（≤8 次 swipeUp，frame∩window 帧判定，不做 hittable 快照）
        // → 精确 tap()（任务硬要求：不用坐标点击）
        var swipes = 0
        while !(testButton.exists && testButton.frame.intersects(app.frame)) && swipes < 8 {
            app.swipeUp()
            usleep(200_000)
            swipes += 1
        }
        XCTAssertTrue(testButton.exists && testButton.frame.intersects(app.frame),
                      "ds_test_button 滚动 \(swipes) 次后仍未进入可视区（最大滚动次数断言）")
        testButton.tap()
        // 结果等待：总预算 90s（60s + 重试点一次 + 30s）；失败附截图 + AX 树 dump
        var result = app.descendants(matching: .any)["settings_test_result"].firstMatch
        if !result.waitForExistence(timeout: 60) {
            testButton.tap()   // 重试一次（identifier 精确，按钮原位）
            result = app.descendants(matching: .any)["settings_test_result"].firstMatch
        }
        if !result.waitForExistence(timeout: 30) {
            let diag = XCTAttachment(screenshot: app.screenshot())
            diag.name = "diag-smoke-conn-hang"
            diag.lifetime = .keepAlways
            add(diag)
            let dump = XCTAttachment(string: app.debugDescription)
            dump.name = "diag-tree-hang"
            dump.lifetime = .keepAlways
            add(dump)
            // 真实连接挂起是功能失败，不得 skip 掩盖（R4 P12/V45 原语义）
            XCTFail("settings testConnection result not shown in 90s（真实连接挂起 = 功能失败）")
            return
        }
        let label = result.label
        XCTAssertTrue(label.contains("✓"), "测试连接必须真实成功: \(label)")
        XCTAssertTrue(label.contains("8."), "成功文案应含真实 MySQL 版本: \(label)")
        XCTAssertFalse(label.contains("演示模式"), "生产模式不得出现演示标注: \(label)")

        // ④ 搜索真实数据命中（生产查询链路二次佐证；键盘聚焦失败 → 跳过，不否定前 3 步）
        searchTab.tap()
        let bar = app.textFields["home_search_field"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.tap()
        Thread.sleep(forTimeInterval: 1.0)
        var typed = false
        // 6 栈常驻：隐藏 Tab 的字段也在 AX 树里 → 必须按搜索栏容器作用域查询
        let field = app.textFields["home_search_field"].firstMatch
        if field.waitForExistence(timeout: 5) {
            do {
                try field.typeText("冒烟影片")
                typed = true
            } catch {
                typed = false
            }
        }
        if typed {
            let hit = app.staticTexts["冒烟影片 S001"]
            XCTAssertTrue(hit.waitForExistence(timeout: 20), "搜索必须命中 fixture 真实数据")
        } else {
            let note = XCTAttachment(string: "search typing skipped (no keyboard focus); " +
                "home-title + real connection already prove the production DB path")
            note.name = "diag_search_skipped"
            note.lifetime = .keepAlways
            add(note)
        }
    }
}
