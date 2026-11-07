import XCTest
@testable import JDLV
import JDLVCore

//
//  CoreHardeningTests.swift —— A10 + R3-R13 加固的可观测验证（R-V10，App 单测面）。
//
//  覆盖：
//  - Db.scalar 按结果集列定义首位取值（真实 MySQL fixture：select 2 as b, 1 as a → 2，
//    修复旧 keys.first 无序字典实现）；
//  - tablesStrict：nil provider → 类型化 DbError「数据源未配置」（不再吞成空集）；
//  - 未知 which → 类型化错误（不再 fatalError / 不再默认映射 sht）；
//  - provider 并发读写压力（读写交错 200 次；进程不崩、终态一致 —— TSan 未启用，
//    以压力烟测替代，见 R9 阶段记录）；
//  - connectTimeout 档位归一（{4,8,15,30} 外 → 8）。
//

final class CoreHardeningTests: XCTestCase {

    override func setUp() {
        super.setUp()
        OfflineGate.reset(now: 0)
    }

    override func tearDown() async throws {
        await MainActor.run {
            AppBootstrap.box.update(AppSettings())
            AppBootstrap.injectRuntime()
        }
        try await super.tearDown()
    }

    // MARK: scalar 首列（列序；真实 MySQL）

    func testScalarReadsFirstColumnByResultSetOrder() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JDLV_TEST_MYSQL_HOST"] else {
            throw XCTSkip("本地无 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*）")
        }
        var s = AppSettings()
        s.remoteHost = host
        s.remotePort = env["JDLV_TEST_MYSQL_PORT"] ?? "3306"
        s.remoteUser = env["JDLV_TEST_MYSQL_USER"] ?? "root"
        s.remotePass = env["JDLV_TEST_MYSQL_PASS"] ?? ""
        s.remoteJdb = "jdlv_app_it"
        s.remoteSht = "jdlv_app_it"
        s.dbSsl = false
        AppBootstrap.box.update(s)
        AppBootstrap.injectRuntime()

        // 旧实现 keys.first 依赖无序字典：b/a 命名顺序下可能取到 1；列序实现必须取 2
        let v = try await Db.scalar("jdb", "select 2 as b, 1 as a")
        XCTAssertEqual(v, 2, "scalar 必须取结果集第一列（b=2），而不是无序字典任意键")
    }

    // MARK: tablesStrict 类型化错误

    @MainActor
    func testTablesStrictThrowsTypedErrorWhenUnconfigured() async {
        Db.configure(settingsProvider: { nil }, hasNetwork: { true })
        do {
            _ = try await Db.tablesStrict("jdb")
            XCTFail("nil provider 必须抛类型化错误而不是返回空集")
        } catch {
            let msg = (error as? CustomStringConvertible)?.description ?? String(describing: error)
            XCTAssertTrue(msg.contains("数据源未配置"), "实际错误: \(msg)")
        }
    }

    // MARK: 未知 which → 类型化错误

    @MainActor
    func testUnknownWhichThrowsTypedExceptionNotFatal() async {
        AppBootstrap.box.update(AppSettings())
        AppBootstrap.injectRuntime()
        do {
            _ = try await MySQLPool.shared.query(which: "nope", sql: "select 1")
            XCTFail("未知 which 必须类型化报错")
        } catch {
            let msg = (error as? CustomStringConvertible)?.description ?? String(describing: error)
            XCTAssertTrue(msg.contains("未知数据源"), "实际错误: \(msg)")
        }
        do {
            _ = try await ConnFactory.databaseName("nope", MySQLPoolSettings(
                host: "h", port: 1, user: "u", pass: "p", jdbDb: "j", shtDb: "s", tls: false))
            XCTFail("ConnFactory 白名单必须拒绝未知 which")
        } catch {
            let msg = (error as? CustomStringConvertible)?.description ?? String(describing: error)
            XCTAssertTrue(msg.contains("未知数据源"), "实际错误: \(msg)")
        }
    }

    // MARK: provider 并发读写压力（TSan 未启用的替代烟测）

    @MainActor
    func testProviderConcurrentReadWriteStress() async throws {
        AppBootstrap.box.update(AppSettings())
        AppBootstrap.injectRuntime()
        let pool = MySQLPool.shared
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { [pool] in
                    if i % 2 == 0 {
                        _ = pool.settingsProvider?()
                        _ = pool.hasNetwork?()
                    } else {
                        pool.settingsProvider = { nil }
                        pool.settingsProvider = { MySQLPoolSettings(
                            host: "127.0.0.1", port: 3306, user: "u", pass: "p",
                            jdbDb: "j", shtDb: "s", tls: false) }
                    }
                }
            }
        }
        let p = try XCTUnwrap(pool.settingsProvider?(), "压力后 provider 必须可用且终态一致")
        XCTAssertEqual(p.host, "127.0.0.1")
    }

    // MARK: connectTimeout 档位归一（A10/R9）

    func testConnectTimeoutNormalizedToChip() {
        var s = AppSettings()
        XCTAssertEqual(s.connectTimeout, 8, "默认 8（对齐 chips {4,8,15,30}）")
        s.connectTimeout = 5
        XCTAssertEqual(s.normalized().connectTimeout, 8, "档位外（旧默认 5）归一 8")
        s.connectTimeout = 30
        XCTAssertEqual(s.normalized().connectTimeout, 30, "合法档位原样")
    }
}
