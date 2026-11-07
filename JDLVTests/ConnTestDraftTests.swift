import XCTest
@testable import JDLV
import JDLVCore

//
//  ConnTestDraftTests.swift —— A4/R4「测试连接显式草稿」契约测试（R-V3）。
//
//  覆盖（真实 MySQL fixture；CI 注入 JDLV_TEST_MYSQL_*，本地 Skip）：
//  - 全局 provider 指向 A（错误库名）而草稿指向 B（fixture）→ 测的是 B（✓）；
//    全局 provider 完好而草稿指向坏库 → 按草稿失败（点名坏库）；
//  - 错误口令 → 错误链含 Access denied + 提示「用户名或密码错误」；
//  - 仅 sht 库名错 → jdb 照常成功、失败文案点名 sht 库；
//  - 成功文案带真实版本号（不再是无版本占位「?」）。
//
//  demo 分支（「演示模式：未发起数据库连接」）依赖 -JDLV_DEMO 启动参数，
//  在 UI 测试进程断言（R8 demo suite），此处无法构造。
//

final class ConnTestDraftTests: XCTestCase {

    private func fixtureEnv() throws -> (host: String, port: Int, user: String, pass: String) {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JDLV_TEST_MYSQL_HOST"] else {
            throw XCTSkip("本地无 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*）")
        }
        let port = Int(env["JDLV_TEST_MYSQL_PORT"] ?? "3306") ?? 3306
        let user = env["JDLV_TEST_MYSQL_USER"] ?? "root"
        let pass = env["JDLV_TEST_MYSQL_PASS"] ?? ""
        return (host, port, user, pass)
    }

    private func draftSettings(_ f: (host: String, port: Int, user: String, pass: String),
                               jdb: String, sht: String, pass overridePass: String? = nil)
        -> AppSettings {
        var s = AppSettings()
        s.remoteHost = f.host
        s.remotePort = String(f.port)
        s.remoteUser = f.user
        s.remotePass = overridePass ?? f.pass
        s.remoteJdb = jdb
        s.remoteSht = sht
        s.dbSsl = false
        s.connectTimeout = 5
        s.queryTimeout = 8
        return s
    }

    override func tearDown() async throws {
        // 恢复全局注入（AppBootstrap 同源），避免污染其它用例
        AppBootstrap.box.update(AppSettings())
        AppBootstrap.injectRuntime()
        try await super.tearDown()
    }

    // MARK: 全局 A / 草稿 B → 测的是 B

    func testDraftBTestedWhileGlobalPointsToBrokenA() async throws {
        let f = try fixtureEnv()

        // 全局 A：错误库名（provider 若被使用必然 Unknown database 失败）
        var broken = AppSettings()
        broken.remoteHost = f.host
        broken.remotePort = String(f.port)
        broken.remoteUser = f.user
        broken.remotePass = f.pass
        broken.remoteJdb = "nope_global_a"
        broken.remoteSht = "nope_global_a"
        broken.dbSsl = false
        AppBootstrap.box.update(broken)
        AppBootstrap.injectRuntime()

        // 草稿 B：正确 fixture 库
        let draft = draftSettings(f, jdb: "jdlv_app_it", sht: "jdlv_app_it")
        let r = await SettingsDiagnostics.testConnection(draft)
        XCTAssertTrue(r.hasPrefix("✓"), "草稿 B 必须可测成功（不受全局 A 影响）: \(r)")
    }

    // MARK: 草稿坏库 → 点名坏库

    func testDraftBrokenDbFailsNamingIt() async throws {
        let f = try fixtureEnv()
        let draft = draftSettings(f, jdb: "jdlv_app_it", sht: "nope_sht_db")
        let r = await SettingsDiagnostics.testConnection(draft)
        XCTAssertFalse(r.hasPrefix("✓"))
        XCTAssertTrue(r.contains("nope_sht_db"), "失败文案必须点名 sht 草稿库: \(r)")
        XCTAssertTrue(r.contains("Unknown database") || r.contains("数据库"),
                      "应含 Unknown database 语义: \(r)")
    }

    // MARK: 错误口令 → Access denied + 提示

    func testWrongPasswordReportsAccessDenied() async throws {
        let f = try fixtureEnv()
        let draft = draftSettings(f, jdb: "jdlv_app_it", sht: "jdlv_app_it",
                                  overridePass: "definitely-wrong-pass")
        let r = await SettingsDiagnostics.testConnection(draft)
        XCTAssertFalse(r.hasPrefix("✓"))
        XCTAssertTrue(r.contains("Access denied"), "错误链必须含 Access denied: \(r)")
        XCTAssertTrue(r.contains("用户名或密码错误"), "提示表必须命中: \(r)")
    }

    // MARK: 成功文案带真实版本号

    func testSuccessReportsRealVersion() async throws {
        let f = try fixtureEnv()
        let draft = draftSettings(f, jdb: "jdlv_app_it", sht: "jdlv_app_it")
        let r = await SettingsDiagnostics.testConnection(draft)
        XCTAssertTrue(r.hasPrefix("✓"))
        // 8.x 版本号出现在成功行（不再是无版本占位「?」）
        XCTAssertTrue(r.contains("8."), "成功文案应含真实版本号: \(r)")
        XCTAssertFalse(r.contains("· ?"), "成功文案不得再出现无版本占位: \(r)")
    }
}
