import XCTest
@testable import JDLV
import JDLVCore

//
//  KeychainLaunchTests.swift —— A7+A8/R7 Keychain 可观测 + LaunchMode/setupRequired 契约测试。
//
//  覆盖：
//  - Keychain 读失败 → secretReadFailed 置位（绝不静默当空口令）；
//  - Keychain 写失败 → updateSettingsNow = FAILED + 内存不变 + 文案可读；恢复后重试成功；
//  - 部分写（第 3 键失败）→ 已写键回滚（原子性）；
//  - LaunchMode.parse 四形态（无参 / -JDLV_DEMO / -JDLV_DEMO 0 / -JDLV_DEMO 1）；
//  - setupRequired 加固：端口非法/库名空 → 必须引导；合法配置放行；
//  - AppBootstrap.mysqlSettings 与 setupRequired 口径一致（口令不可用 → nil）。
//

final class KeychainLaunchTests: XCTestCase {

    private static var wipedTags: Set<String> = []

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_keylaunch_\(tag)"
        if !Self.wipedTags.contains(tag) {
            UserDefaults().removePersistentDomain(forName: name)
            Self.wipedTags.insert(tag)
        }
        return UserDefaults(suiteName: name)!
    }

    override func setUp() {
        super.setUp()
        KeychainStore.fault = KeychainStore.Fault()
        KeychainStore.delete("settings:local_pass")
        KeychainStore.delete("settings:remote_pass")
        KeychainStore.delete("lock_secret")
    }

    override func tearDown() async throws {
        KeychainStore.fault = KeychainStore.Fault()
        try await super.tearDown()
    }

    // MARK: 读失败可观测

    @MainActor
    func testReadFaultSurfacesInsteadOfSilentEmpty() async {
        KeychainStore.fault.read = true
        let store = SettingsStore(defaults: freshDefaults("readfault"))
        // R4 P6：Keychain 读取已移后台 —— 等 loaded（毫秒级；5s 上限防挂）
        let deadline = Date().addingTimeInterval(5)
        while !store.loaded && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(store.loaded, "后台 Keychain 读取必须在 5s 内完成")
        XCTAssertTrue(store.secretReadFailed, "读失败必须显式置位")
        XCTAssertFalse(store.secretReadMessage.isEmpty, "必须有可读文案")
        // 口令不可用 → setupRequired（不是「网络不可达」）
        XCTAssertTrue(store.setupRequired)
    }

    // MARK: 写失败 → FAILED 且不吞

    @MainActor
    func testWriteFailureFailsSaveWithoutMemoryChange() async {
        let store = SettingsStore(defaults: freshDefaults("writefault"))
        KeychainStore.fault.write = true
        let r = await store.autoSave { s in
            s.remoteUser = "u2"
            s.remotePass = "new-pass"
        }
        XCTAssertEqual(r, .failed)
        XCTAssertEqual(store.lastSaveResult, .failed, "autoSave 必须把 FAILED 写进三态状态")
        XCTAssertEqual(store.settings.remotePass, "", "内存口令不得变成未落盘值")
        XCTAssertFalse(store.secretWriteMessage.isEmpty, "写失败必须有可读文案")

        KeychainStore.fault.write = false
        let r2 = await store.updateSettingsNow { s in s.remotePass = "new-pass" }
        XCTAssertEqual(r2, .saved, "故障解除后重试必须成功")
        XCTAssertEqual(store.settings.remotePass, "new-pass")
    }

    // MARK: 部分写回滚（原子性）

    @MainActor
    func testPartialWriteRollsBackWrittenKeys() async throws {
        let store = SettingsStore(defaults: freshDefaults("partial"))
        // 前置：写入三个口令旧值
        _ = await store.updateSettingsNow { s in
            s.localPass = "old-local"
            s.remotePass = "old-remote"
            s.lockSecret = "old-lock"
        }
        XCTAssertEqual(try XCTUnwrap(KeychainStore.getResult(SecretKeyStr.local).get()), "old-local")
        XCTAssertEqual(try XCTUnwrap(KeychainStore.getResult(SecretKeyStr.lock).get()), "old-lock")

        // 第 3 键失败 → 前两键必须回滚
        KeychainStore.fault.failKeys = ["lock_secret"]
        let r = await store.updateSettingsNow { s in
            s.localPass = "new-local"
            s.remotePass = "new-remote"
            s.lockSecret = "new-lock"
        }
        XCTAssertEqual(r, .failed)
        XCTAssertEqual(try XCTUnwrap(KeychainStore.getResult(SecretKeyStr.local).get()), "old-local",
                       "已写键必须回滚")
        XCTAssertEqual(try XCTUnwrap(KeychainStore.getResult(SecretKeyStr.remote).get()), "old-remote",
                       "已写键必须回滚")
        XCTAssertEqual(try XCTUnwrap(KeychainStore.getResult(SecretKeyStr.lock).get()), "old-lock")
    }

    /// 测试键名（KeychainStore.SecretKey 是 SettingsStore 私有）
    private enum SecretKeyStr {
        static let local = "settings:local_pass"
        static let remote = "settings:remote_pass"
        static let lock = "lock_secret"
    }

    // MARK: R7 P1 安装代际清零（jdlv_install_id + 首启 purge）

    /// R4 P6 后台读轮询（代际用例共用；5s 上限防挂）
    @MainActor
    private func waitLoaded(_ store: SettingsStore, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !store.loaded && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 断言 Keychain 条目不存在（.success(nil)）；读失败 = 未按预期删除
    private func assertKeyGone(_ key: String, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .success(let v) = KeychainStore.getResult(key) else {
            XCTFail("\(label) 读失败（期望条目不存在）", file: file, line: line)
            return
        }
        XCTAssertNil(v, "\(label) 必须被代际 purge", file: file, line: line)
    }

    @MainActor
    func testFreshInstallPurgesLegacySecrets() async {
        // 旧代际残留：三键都有值（等价卸载前写入；Keychain 不随 App 删除清空）
        XCTAssertTrue(KeychainStore.set("old-local", forKey: SecretKeyStr.local))
        XCTAssertTrue(KeychainStore.set("old-remote", forKey: SecretKeyStr.remote))
        XCTAssertTrue(KeychainStore.set("old-lock", forKey: SecretKeyStr.lock))
        let defaults = freshDefaults("gen_fresh")   // 无 settings JSON、无 jdlv_install_id
        XCTAssertNil(defaults.string(forKey: SecretVault.installIDKey))

        let store = SettingsStore(defaults: defaults)
        await waitLoaded(store)

        // DB 口令按空处理（设置页显示「未设置」）；lock 默认未启用 → 一并清；标记已写
        XCTAssertEqual(store.settings.localPass, "", "重装代际 local 口令必须为空")
        XCTAssertEqual(store.settings.remotePass, "", "重装代际 remote 口令必须为空")
        assertKeyGone(SecretKeyStr.local, "local_pass")
        assertKeyGone(SecretKeyStr.remote, "remote_pass")
        assertKeyGone(SecretKeyStr.lock, "lock_secret")
        XCTAssertNotNil(defaults.string(forKey: SecretVault.installIDKey),
                        "purge 成功后必须写入安装代际标记")
        XCTAssertFalse(store.secretPurgePending)
    }

    @MainActor
    func testSecondLaunchKeepsSecrets() async {
        let defaults = freshDefaults("gen_second")
        let store1 = SettingsStore(defaults: defaults)
        await waitLoaded(store1)                    // 首启：purge + 写代际标记
        let r = await store1.updateSettingsNow { s in s.remotePass = "keep-me" }
        XCTAssertEqual(r, .saved)

        // 同一 defaults 再建实例 = 正常重启（标记存在）→ 口令必须保留
        let store2 = SettingsStore(defaults: defaults)
        await waitLoaded(store2)
        XCTAssertEqual(store2.settings.remotePass, "keep-me",
                       "正常重启不得误清口令（代际标记必须生效）")
        guard case .success(let v) = KeychainStore.getResult(SecretKeyStr.remote) else {
            return XCTFail("remote getResult failed")
        }
        XCTAssertEqual(v, "keep-me")
    }

    @MainActor
    func testUpgradeWithoutInstallIDPurgesOnce() async {
        // 老用户升级：有 settings JSON、无 jdlv_install_id、Keychain 有值 → 清一次
        let defaults = freshDefaults("gen_upgrade")
        XCTAssertTrue(KeychainStore.set("old-local", forKey: SecretKeyStr.local))
        XCTAssertTrue(KeychainStore.set("old-remote", forKey: SecretKeyStr.remote))
        XCTAssertTrue(KeychainStore.set("old-lock", forKey: SecretKeyStr.lock))
        // 模拟旧版本落盘数据（不含 lock_enabled → 解不出 = false → 连 lock 一起清）
        let seedData = AppSettings.encodeStorageJSON(["remote_host": "10.0.0.1"])!
        defaults.set(seedData, forKey: AppSettings.storageDefaultsKey)

        let store1 = SettingsStore(defaults: defaults)
        await waitLoaded(store1)
        XCTAssertEqual(store1.settings.remoteHost, "10.0.0.1", "非口令配置必须保留")
        XCTAssertEqual(store1.settings.remotePass, "", "升级代际必须清一次口令")
        assertKeyGone(SecretKeyStr.local, "local_pass")
        assertKeyGone(SecretKeyStr.remote, "remote_pass")
        assertKeyGone(SecretKeyStr.lock, "lock_secret")
        XCTAssertNotNil(defaults.string(forKey: SecretVault.installIDKey))

        // 老用户重输口令后再启动：不再清（一次性语义）
        let store2 = SettingsStore(defaults: defaults)
        await waitLoaded(store2)
        let r = await store2.updateSettingsNow { s in s.remotePass = "re-entered" }
        XCTAssertEqual(r, .saved)
        let store3 = SettingsStore(defaults: defaults)
        await waitLoaded(store3)
        XCTAssertEqual(store3.settings.remotePass, "re-entered",
                       "第二次启动后不得再清（新输入必须保留）")
    }

    @MainActor
    func testPurgeFailureRetriesNextLaunch() async {
        let defaults = freshDefaults("gen_purgefail")
        XCTAssertTrue(KeychainStore.set("old-local", forKey: SecretKeyStr.local))
        XCTAssertTrue(KeychainStore.set("old-remote", forKey: SecretKeyStr.remote))

        KeychainStore.fault.failDelete = true
        let store = SettingsStore(defaults: defaults)
        await waitLoaded(store)
        XCTAssertNil(defaults.string(forKey: SecretVault.installIDKey),
                     "purge 失败不得写代际标记")
        XCTAssertTrue(store.secretPurgePending, "purge 失败必须置 pending 态")
        XCTAssertTrue(store.secretReadFailed, "必须走现有 secretReadFailed 文案通道")
        XCTAssertFalse(store.secretReadMessage.isEmpty, "必须有可读文案")
        XCTAssertEqual(store.settings.remotePass, "", "本会话必须按无口令处理")

        // 下次启动（故障解除）：ensureGeneration 重试成功
        KeychainStore.fault.failDelete = false
        let store2 = SettingsStore(defaults: defaults)
        await waitLoaded(store2)
        XCTAssertNotNil(defaults.string(forKey: SecretVault.installIDKey), "重试成功必须写标记")
        XCTAssertFalse(store2.secretPurgePending)
        assertKeyGone(SecretKeyStr.local, "local_pass")
        assertKeyGone(SecretKeyStr.remote, "remote_pass")
    }

    // MARK: LaunchMode 四形态

    func testLaunchModeParseFourVariants() {
        XCTAssertEqual(LaunchMode.parse([]), .production, "无参 = 生产")
        XCTAssertEqual(LaunchMode.parse(["-JDLV_DEMO"]), .production, "缺值 = 生产")
        XCTAssertEqual(LaunchMode.parse(["-JDLV_DEMO", "0"]), .production, "0 = 生产（修复旧歧义）")
        XCTAssertEqual(LaunchMode.parse(["-JDLV_DEMO", "1"]), .demo, "严格 1 = 演示")
        XCTAssertEqual(LaunchMode.parse(["other", "-JDLV_DEMO", "1", "x"]), .demo)
    }

    // MARK: setupRequired 加固

    func testSetupRequiredRejectsInvalidPortAndEmptyDbs() {
        var s = AppSettings()
        s.remoteHost = "10.0.0.5"   // R4：默认 host 为空 → setupRequired；先注入合法 host
        s.remoteUser = "u"
        s.remotePass = "p"
        XCTAssertFalse(s.setupRequired, "默认 host/port/dbs 合法")

        s.remotePort = "0"
        XCTAssertTrue(s.setupRequired, "端口 0 必须引导")
        s.remotePort = "99999"
        XCTAssertTrue(s.setupRequired, "端口越界必须引导")
        s.remotePort = "abc"
        XCTAssertTrue(s.setupRequired, "端口非数字必须引导")
        s.remotePort = "3307"
        s.remoteJdb = ""
        XCTAssertTrue(s.setupRequired, "空库名必须引导")
        s.remoteJdb = "javdb"

        s.dbSrc = "local"
        s.localUser = "root"
        s.localPort = "0"
        XCTAssertTrue(s.setupRequired, "local 端口非法必须引导")
        s.localPort = "3306"
        XCTAssertFalse(s.setupRequired)
    }

    // MARK: 映射与 setupRequired 口径一致

    func testMappingNilWhenPassUnavailable() {
        var s = AppSettings()
        s.remoteUser = "u"
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "口令空 = 未配置（与 setupRequired 同口径）")
        s.remotePass = "p"
        s.remotePort = "abc"
        XCTAssertNil(AppBootstrap.mysqlSettings(s), "端口非法必须 nil")
    }
}
