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
