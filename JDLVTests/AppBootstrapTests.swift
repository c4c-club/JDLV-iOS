import XCTest
@testable import JDLV
import JDLVCore

//
//  AppBootstrapTests.swift —— A1/R1 生产 Bootstrap 契约测试（R-V1）。
//
//  覆盖：
//  - AppSettings → MySQLPoolSettings 全字段等值映射（R-V1「settingsProvider?() 全字段
//    == 持久化配置」）；
//  - 端口非法 / host/user/pass 空 → nil（Db 层显式「数据源未配置」，不静默空串）；
//  - injectRuntime：MySQLPool.shared.settingsProvider/hasNetwork 接的是快照盒与
//    NetworkStateBox（网络标志随注入状态变化）；CdnRewrite 同源 + applyHostOnly；
//  - nil provider：Db.query 抛「数据源未配置」、Db.check 返回 false；
//  - Store 级副作用单入口（A3/R3，R-V5）：不挂载 SettingsView 时 updateSettingsNow →
//    provider 同步刷新 + Db.reset（离线标记清）+ bumpData；非 db 变更不触发 reset；
//  - 真实 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*；本地缺 env 时 XCTSkip）：
//    Db.check 成功 + Db.query("select 1")（SqlPolicy admin.ping 模板）返回 1 行。
//
//  全局状态纪律：每个用例 setUp 先重置注入与网络标志；tearDown 还原
//  CdnRewrite 默认 provider / 空设置快照，避免污染其它用例。
//

final class AppBootstrapTests: XCTestCase {

    // MARK: - 工具

    private static var wipedTags: Set<String> = []

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_bootstrap_\(tag)"
        if !Self.wipedTags.contains(tag) {
            UserDefaults().removePersistentDomain(forName: name)
            Self.wipedTags.insert(tag)
        }
        return UserDefaults(suiteName: name)!
    }

    private func fixtureSettings() -> AppSettings {
        var s = AppSettings()
        s.dbSrc = "remote"
        s.remoteHost = "10.1.2.3"
        s.remotePort = "3307"
        s.remoteUser = "u_it"
        s.remotePass = "p_it"
        s.remoteJdb = "jdb_it"
        s.remoteSht = "sht_it"
        s.dbSsl = true
        s.connectTimeout = 15
        s.queryTimeout = 30
        s.jdbImgHost = "app"
        s.shtMirrorHost = "mirror.example"
        return s
    }

    @MainActor
    private func resetRuntime() {
        AppBootstrap.network.set(true)
        AppBootstrap.box.update(AppSettings())
        AppBootstrap.injectRuntime()
        CdnRewrite.settingsProvider = { CdnSettings() }
        CdnRewrite.shtHost = nil
    }

    override func setUp() {
        super.setUp()
        // 口令键清理（Keychain 不随 suite 走）
        KeychainStore.delete("settings:local_pass")
        KeychainStore.delete("settings:remote_pass")
        KeychainStore.delete("lock_secret")
        OfflineGate.reset(now: 0)
    }

    override func tearDown() async throws {
        await resetRuntime()
        try await super.tearDown()
    }

    // MARK: 1. 映射全字段等值（R-V1 核心）

    func testMappingFullFieldEquality() {
        let s = fixtureSettings()
        let p = AppBootstrap.mysqlSettings(s)
        XCTAssertNotNil(p, "合法配置必须映射成功")
        XCTAssertEqual(p?.host, "10.1.2.3")
        XCTAssertEqual(p?.port, 3307)
        XCTAssertEqual(p?.user, "u_it")
        XCTAssertEqual(p?.pass, "p_it")
        XCTAssertEqual(p?.jdbDb, "jdb_it")
        XCTAssertEqual(p?.shtDb, "sht_it")
        XCTAssertEqual(p?.tls, true)
        XCTAssertEqual(p?.connectTimeout, 15)
        XCTAssertEqual(p?.queryTimeout, 30)
        XCTAssertNil(p?.serverHostname)
    }

    // MARK: 2. 非法输入 → nil（禁止静默空串）

    func testMappingInvalidInputsReturnNil() {
        var s = fixtureSettings()

        s.remotePort = "abc"
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "端口非数字必须 nil")
        s.remotePort = "0"
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "端口 0 必须 nil")
        s.remotePort = "70000"
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "端口超界必须 nil")

        s.remotePort = "3307"
        s.remoteHost = ""
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "host 空必须 nil")

        s.remoteHost = "10.1.2.3"
        s.remoteUser = ""
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "user 空必须 nil")

        s.remoteUser = "u_it"
        s.remotePass = ""
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "pass 空必须 nil")
    }

    // MARK: 3. injectRuntime：provider/hasNetwork/CdnRewrite 同源

    @MainActor
    func testInjectionProviderFieldsAndNetworkFlag() {
        AppBootstrap.box.update(fixtureSettings())
        AppBootstrap.injectRuntime()

        let p = MySQLPool.shared.settingsProvider?()
        XCTAssertNotNil(p, "注入后 settingsProvider 不得为 nil")
        XCTAssertEqual(p?.host, "10.1.2.3")
        XCTAssertEqual(p?.port, 3307)
        XCTAssertEqual(p?.jdbDb, "jdb_it")
        XCTAssertEqual(p?.pass, "p_it")

        XCTAssertTrue(MySQLPool.shared.hasNetwork?() ?? false, "默认网络标志 = 在线")
        AppBootstrap.network.set(false)
        XCTAssertEqual(MySQLPool.shared.hasNetwork?(), false, "网络标志随注入状态变化")
        AppBootstrap.network.set(true)
        XCTAssertTrue(MySQLPool.shared.hasNetwork?() ?? false)

        // CdnRewrite 与同一快照盒同源（TestImages/图床 host 口径一致）
        XCTAssertEqual(CdnRewrite.settings().jdbImgHost, "app")
        // applyHostOnly：shtMirrorHost → 内存 shtHost（首帧前生效，R-V6 前置）
        XCTAssertEqual(CdnRewrite.shtHost, "mirror.example")
    }

    // MARK: 3b. CdnRewrite 启动注入（A6/R6：SettingsView 未出现也必须同源）

    @MainActor
    func testCdnInjectionBeforeAnySettingsView() {
        var s = AppSettings()
        s.jdbImgHost = "web"
        s.shtMirror = "https://mirror.example"
        s.shtMirrorHost = "mirror.example"
        s.proxyCdnJdb = true
        s.imageCacheMb = 256
        AppBootstrap.box.update(s)
        AppBootstrap.injectRuntime()

        let cs = CdnRewrite.settings()
        XCTAssertEqual(cs.jdbImgHost, "web")
        XCTAssertEqual(cs.shtMirrorHost, "mirror.example")
        XCTAssertTrue(cs.proxyCdnJdb)
        XCTAssertEqual(cs.imageCacheMb, 256)
        XCTAssertEqual(CdnRewrite.shtHost, "mirror.example", "applyHostOnly 必须在首帧前生效")

        // 热更新（updateSettingsNow 改镜像 → effects 路径同样生效）
        s.shtMirrorHost = "h2.example"
        AppBootstrap.box.update(s)
        AppBootstrap.injectRuntime()
        XCTAssertEqual(CdnRewrite.settings().shtMirrorHost, "h2.example")
        XCTAssertEqual(CdnRewrite.shtHost, "h2.example")
    }

    // MARK: 4. nil provider：显式报「数据源未配置」+ check false

    @MainActor
    func testNilProviderThrowsUnconfiguredAndCheckFalse() async {
        Db.configure(settingsProvider: { nil }, hasNetwork: { true })
        do {
            _ = try await Db.query("jdb", "select 1")
            XCTFail("nil provider 必须抛错而不是静默成功")
        } catch {
            let msg = (error as? CustomStringConvertible)?.description ?? String(describing: error)
            XCTAssertTrue(msg.contains("数据源未配置"), "实际错误文案: \(msg)")
        }
        let ok = await Db.check("jdb")
        XCTAssertFalse(ok, "nil provider 时 ping 必须 false（且无错误对象可展示）")
    }

    // MARK: 5. Store 级副作用单入口（不挂载 SettingsView；A3/R3，R-V5）

    @MainActor
    func testStoreLevelEffectsDriveProviderAndResetWithoutView() async {
        let store = SettingsStore(defaults: freshDefaults("effects"))
        // 与 AppBootstrap.start 相同的注入方式（weak store 防环）
        store.onPersistedEffects = { [weak store] old, new in
            guard let store else { return }
            SettingsEffects.apply(old: old, new: new, store: store)
        }
        // provider 注入（CdnRewrite 读 AppBootstrap.box —— 前序用例 tearDown 可能已重置为默认）
        AppBootstrap.box.update(store.settings)
        AppBootstrap.injectRuntime()
        _ = await store.updateSettingsNow { s in
            s.remoteHost = "10.1.2.3"
            s.remotePort = "3307"
            s.remoteUser = "u_it"
            s.remotePass = "p_it"
            s.remoteJdb = "jdb_it"
            s.remoteSht = "sht_it"
        }
        // 前置：provider 指向持久化配置
        XCTAssertEqual(MySQLPool.shared.settingsProvider?()?.port, 3307)

        // db 侧变更 → provider 刷新 + Db.reset（离线标记清）+ bumpData
        let e0 = store.dataEpoch
        Db.markOffline("jdb", ms: 60_000)
        XCTAssertTrue(Db.offlineJdb, "前置：离线标记已置位")
        _ = await store.autoSave { s in s.remotePort = "3308" }
        XCTAssertEqual(store.lastSaveResult, .saved)
        XCTAssertEqual(MySQLPool.shared.settingsProvider?()?.port, 3308,
                       "provider 必须与持久化配置同源")
        XCTAssertFalse(Db.offlineJdb, "db 侧变更必须触发 Db.reset（离线标记清除）")
        XCTAssertEqual(store.dataEpoch, e0 + 1, "db 变更必须 bumpData")

        // 非 db 侧变更（主题）→ 不触发 reset
        Db.markOffline("jdb", ms: 60_000)
        _ = await store.updateSettingsNow { s in s.themeName = "sepia" }
        XCTAssertTrue(Db.offlineJdb, "非 db 变更不得触发 Db.reset")

        // cdn 变更 → 快照盒同步 + applyHostOnly
        _ = await store.updateSettingsNow { s in s.shtMirrorHost = "new-mirror.example" }
        XCTAssertEqual(AppBootstrap.box.settings.shtMirrorHost, "new-mirror.example")
        XCTAssertEqual(CdnRewrite.shtHost, "new-mirror.example", "cdn 变更需 applyHostOnly")
        CdnRewrite.shtHost = nil

        // pending chain（800ms 防抖未到）→ flushPendingEdits 立即落盘 + 副作用
        store.edit { $0.remoteUser = "u_flush" }
        store.edit { $0.remotePort = "3309" }
        await store.flushPendingEdits()
        XCTAssertEqual(MySQLPool.shared.settingsProvider?()?.user, "u_flush")
        XCTAssertEqual(MySQLPool.shared.settingsProvider?()?.port, 3309)
    }

    // MARK: 6. 真实 MySQL fixture（CI 注入 env；本地无 env → Skip）

    func testRealMySQLFixtureQueryAndCheck() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JDLV_TEST_MYSQL_HOST"] else {
            throw XCTSkip("本地无 MySQL fixture（CI ios job 注入 JDLV_TEST_MYSQL_*）")
        }
        let port = Int(env["JDLV_TEST_MYSQL_PORT"] ?? "3306") ?? 3306
        let user = env["JDLV_TEST_MYSQL_USER"] ?? "root"
        let pass = env["JDLV_TEST_MYSQL_PASS"] ?? ""

        var s = AppSettings()
        s.remoteHost = host
        s.remotePort = String(port)
        s.remoteUser = user
        s.remotePass = pass
        s.remoteJdb = "jdlv_app_it"
        s.remoteSht = "jdlv_app_it"
        s.dbSsl = false
        s.connectTimeout = 5
        s.queryTimeout = 8

        AppBootstrap.box.update(s)
        AppBootstrap.injectRuntime()

        // 生产链路经 Db 门面（与 App 相同入口）：check + query
        let jdbOk = await Db.check("jdb")
        XCTAssertTrue(jdbOk, "Db.check(jdb) 应在 fixture MySQL 上成功")
        let shtOk = await Db.check("sht")
        XCTAssertTrue(shtOk, "Db.check(sht) 应在 fixture MySQL 上成功")
        let rows = try await Db.query("jdb", "select 1")
        XCTAssertEqual(rows.count, 1, "SqlPolicy admin.ping 模板应放行 select 1")
        // 全字段等值复验（真实链路上 provider 即持久化映射）
        let p = MySQLPool.shared.settingsProvider?()
        XCTAssertEqual(p?.host, host)
        XCTAssertEqual(p?.port, port)
        XCTAssertEqual(p?.user, user)
        XCTAssertEqual(p?.pass, pass)
        XCTAssertEqual(p?.jdbDb, "jdlv_app_it")
    }
}
