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
        let smokeTitle = app.staticTexts["冒烟影片 S001"]
        XCTAssertTrue(smokeTitle.waitForExistence(timeout: 25),
                      "首页必须出现 fixture 真实标题（生产数据链路）")
        XCTAssertFalse(app.staticTexts["演示影片 001"].exists, "生产模式不得出现 demo 标题")

        // ③ 设置页「测试连接」→ 真实成功（含版本号、不含「演示模式」）
        let settingsTab = app.descendants(matching: .any)["tab_settings"].firstMatch
        XCTAssertTrue(settingsTab.exists)
        settingsTab.tap()
        let testButton = app.descendants(matching: .any)["ds_test_button"].firstMatch
        XCTAssertTrue(testButton.waitForExistence(timeout: 15), "测试连接按钮未找到")
        testButton.tap()
        let result = app.descendants(matching: .any)["settings_test_result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "测试结果未出现")
        let label = result.label
        XCTAssertTrue(label.contains("✓"), "测试连接必须真实成功: \(label)")
        XCTAssertTrue(label.contains("8."), "成功文案应含真实 MySQL 版本: \(label)")
        XCTAssertFalse(label.contains("演示模式"), "生产模式不得出现演示标注: \(label)")

        // ④ 搜索真实数据命中（生产查询链路二次佐证）
        searchTab.tap()
        let bar = app.descendants(matching: .any)["home_searchbar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.tap()
        app.typeText("冒烟影片")
        let hit = app.staticTexts["冒烟影片 S001"]
        XCTAssertTrue(hit.waitForExistence(timeout: 20), "搜索必须命中 fixture 真实数据")
    }
}
