import XCTest
import Security
import JDLVCore
@testable import JDLV

// R5 P2：SettingsStore 串行持久化单测（13 §6.1 扩展）。
//
// 覆盖（03_PHASE2 §3 四场景 + 确定性 barrier）：
//  - 慢写 A + 快写 B → 最终持久化 B（合并/串行）；
//  - 慢写 B + 快写 A → 最终持久化 A；
//  - 写失败 → saveState/.failed + secretWriteMessage 可见，重试可成功；
//  - 连续 50 次快速修改 → 最终值与最后一次一致；
//  - retrySecretLoads 后台读路径（MainActor 无同步 Keychain 调用）。
//
// 确定性：全部经 await store.persistTail?.value（FIFO 写链尾）做 barrier，不靠 sleep 碰运气。
// fake writer 记录调用序列（key+value）与可控延迟/故障。
@MainActor
final class SettingsPersistSerialTests: XCTestCase {

    /// 可控 Keychain 写 fake：记录 (key, value) 序列；延迟/失败逐调用可配
    private final class FakeKeychainWriter: KeychainWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(key: String, value: String)] = []
        /// 每次调用的延迟（纳秒）；空数组 = 0
        var delaysNs: [UInt64] = []
        /// 第 n 次（0-based）调用是否失败
        var failAt: Set<Int> = []

        func set(_ value: String, forKey key: String) async -> Result<Void, KeychainStore.KeyStatus> {
            lock.lock()
            let idx = recorded.count
            let delay = delaysNs.isEmpty ? 0 : (idx < delaysNs.count ? delaysNs[idx] : 0)
            let fail = failAt.contains(idx)
            lock.unlock()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            lock.lock()
            recorded.append((key, value))
            lock.unlock()
            if fail {
                return .failure(KeychainStore.KeyStatus(osStatus: errSecAuthFailed))
            }
            return .success(())
        }

        func values(forKey key: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded.filter { $0.key == key }.map { $0.value }
        }

        var allKeys: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded.map { $0.key }
        }
    }

    private var wiped: Set<String> = []

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_persist_serial_\(tag)"
        if !wiped.contains(tag) {
            UserDefaults().removePersistentDomain(forName: name)
            wiped.insert(tag)
        }
        return UserDefaults(suiteName: name)!
    }

    override func setUp() {
        super.setUp()
        KeychainStore.fault = KeychainStore.Fault()
    }

    override func tearDown() {
        KeychainStore.fault = KeychainStore.Fault()
        super.tearDown()
    }

    /// 确定性 barrier：等待写链尾完成
    private func awaitChainTail(_ store: SettingsStore) async {
        await store.persistTail?.value
    }

    // MARK: 场景 1：慢 A + 快 B → 最终 B

    func testSlowFirstThenFastSecond_persistsLatest() async {
        let fake = FakeKeychainWriter()
        fake.delaysNs = [200_000_000, 10_000_000]   // A 慢 200ms，B 快 10ms
        let store = SettingsStore(defaults: freshDefaults("slowAB"), keychainWriter: fake)

        store.updateSettings { $0.localPass = "A" }
        store.updateSettings { $0.localPass = "B" }
        await awaitChainTail(store)

        XCTAssertEqual(fake.values(forKey: "settings:local_pass").last, "B",
                       "慢写 A 在先快写 B 在后 → 最终持久化 B")
        XCTAssertEqual(store.settings.localPass, "B")
    }

    // MARK: 场景 2：慢 B + 快 A → 最终 A

    func testSlowSecondThenFastFirst_persistsLatest() async {
        let fake = FakeKeychainWriter()
        let store = SettingsStore(defaults: freshDefaults("slowBA"), keychainWriter: fake)

        // B 先请求但排队等待（先排一个慢占位写，模拟链上前置慢节点）
        fake.delaysNs = [10_000_000, 200_000_000]
        store.updateSettings { $0.localPass = "placeholder" }
        store.updateSettings { $0.localPass = "B" }   // 合并进占位节点
        // A 快：链上已无待执行合并节点（执行中已清标记）→ 新节点 10ms
        try? await Task.sleep(nanoseconds: 30_000_000)   // 让占位节点进入执行（清合并标记）
        store.updateSettings { $0.localPass = "A" }
        await awaitChainTail(store)

        XCTAssertEqual(fake.values(forKey: "settings:local_pass").last, "A",
                       "B 在链上先执行、A 后执行 → 最终持久化 A")
        XCTAssertEqual(store.settings.localPass, "A")
    }

    // MARK: 场景 3：写失败可见 + 重试成功

    func testWriteFailureVisibleAndRetrySucceeds() async {
        let fake = FakeKeychainWriter()
        fake.failAt = [0]   // 第一次 local_pass 写失败（原子回滚路径）
        let store = SettingsStore(defaults: freshDefaults("fail"), keychainWriter: fake)

        let r = await store.updateSettingsNow { $0.localPass = "X" }
        XCTAssertEqual(r, .failed, "Keychain 写失败 → FAILED")
        if case .failed = store.saveState {} else {
            XCTFail("saveState 必须 .failed，实际 \(store.saveState)")
        }
        XCTAssertFalse(store.secretWriteMessage.isEmpty, "写失败文案必须可见")
        XCTAssertEqual(store.settings.localPass, "", "通道二写失败后内存不更新（原语义：写成功才更新）")

        // 重试（无故障）→ 成功
        fake.failAt = []
        let r2 = await store.updateSettingsNow { $0.localPass = "X" }
        XCTAssertEqual(r2, .saved, "重试可成功")
        if case .saved = store.saveState {} else {
            XCTFail("重试后 saveState 必须 .saved，实际 \(store.saveState)")
        }
        XCTAssertEqual(fake.values(forKey: "settings:local_pass"), ["X", "X"],
                       "第一次（失败）+ 重试各一次物理调用，最终值 X")
    }

    // MARK: 场景 4：连续 50 次快速修改 → 最终值与最后一次一致

    func testFiftyRapidEditsFinalWins() async {
        for round in 0..<5 {   // 重复 5 轮（确定性 barrier 下等价重复验证）
            let fake = FakeKeychainWriter()
            let store = SettingsStore(defaults: freshDefaults("rapid\(round)"), keychainWriter: fake)
            for i in 1...50 {
                store.updateSettings { $0.localPass = "v\(i)" }
            }
            await awaitChainTail(store)
            XCTAssertEqual(store.settings.localPass, "v50", "round \(round)：内存终值")
            let wrote = fake.values(forKey: "settings:local_pass")
            XCTAssertEqual(wrote.last, "v50", "round \(round)：Keychain 终值")
            XCTAssertLessThanOrEqual(wrote.count, 50, "round \(round)：合并后不得超出请求数")
        }
    }

    // MARK: 场景 5：通道一合并 —— 链上待执行节点期间的新请求只写一次

    func testCoalescingSinglePhysicalWrite() async {
        let fake = FakeKeychainWriter()
        fake.delaysNs = [50_000_000]
        let store = SettingsStore(defaults: freshDefaults("coalesce"), keychainWriter: fake)
        store.updateSettings { $0.localPass = "v1" }   // 节点排队，50ms 慢写
        store.updateSettings { $0.localPass = "v2" }   // 合并（不排新节点）
        store.updateSettings { $0.localPass = "v3" }   // 合并
        await awaitChainTail(store)

        XCTAssertEqual(fake.values(forKey: "settings:local_pass"), ["v3"],
                       "链上待执行期间的连续修改合并为一次物理写，只写最新值")
        XCTAssertEqual(store.persistGeneration, 3, "代际按请求递增")
    }

    // MARK: 场景 6：retrySecretLoads 后台读（主线程无同步 Keychain）

    func testRetrySecretLoadsReadsInBackgroundAndUpdates() async {
        KeychainStore.fault.read = true   // init 后台读全部失败 → secretReadFailed
        let store = SettingsStore(defaults: freshDefaults("retry"))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !store.secretReadFailed {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(store.secretReadFailed, "读故障注入 → secretReadFailed")

        KeychainStore.setResult("rp_it", forKey: "settings:remote_pass")
        KeychainStore.fault.read = false
        store.retrySecretLoads()   // R5 P2：内部后台读取，不再在 MainActor 同步调 getResult
        let dl = Date().addingTimeInterval(3)
        while Date() < dl, store.secretReadFailed {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(store.secretReadFailed, "重试成功 → 清失败态")
        XCTAssertEqual(store.settings.remotePass, "rp_it", "重试后采用 Keychain 真实值")
        KeychainStore.delete("settings:remote_pass")
    }

    // MARK: 场景 7：init 后台读 no-clobber 不受通道写干扰

    func testSerialChainKeepsUserDefaultsFinalState() async {
        let fake = FakeKeychainWriter()
        let store = SettingsStore(defaults: freshDefaults("udfinal"), keychainWriter: fake)
        // 交错两通道：通道一（合并、无等待）+ 通道二（挂起）
        store.updateSettings { $0.viewMode = 1 }
        let r = await store.updateSettingsNow { $0.perPage = 36 }
        XCTAssertEqual(r, .saved)
        await awaitChainTail(store)
        // 最后一次落盘的 UserDefaults JSON 必须含两个修改（FIFO 链保证不全丢）
        let data = store.defaults.data(forKey: AppSettings.storageDefaultsKey)
        XCTAssertNotNil(data)
        let dict = (try? JSONSerialization.jsonObject(with: data!) as? [String: Any]) ?? [:]
        XCTAssertEqual(dict["view_mode"] as? Int, 1, "通道一修改在链上不丢")
        XCTAssertEqual(dict["per_page"] as? Int, 36, "通道二修改在链上不丢")
    }
}
