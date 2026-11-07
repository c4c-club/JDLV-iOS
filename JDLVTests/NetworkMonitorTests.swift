import XCTest
@testable import JDLV
import JDLVCore

//
//  NetworkMonitorTests.swift —— A5/R5 网络状态与横幅合并契约测试（R-V7 单测面）。
//
//  覆盖：
//  - 假 monitor 注入 offline → AppServices 两库横幅 flag 全亮 + network 盒 false +
//    netEpoch/dataEpoch 不变（离线不触发任何刷新）；
//  - Db.markOffline（分库标记）→ syncOfflineFlags 合并：仅 jdb 离线时单侧亮；
//  - 恢复（online）→ 两 flag 复位 + Db 离线标记清 + restored 横幅置位 + netEpoch +1 +
//    dataEpoch 不变（不自动重拉）；
//  - fakeNetworkArg 解析（offline/online/缺失）。
//
//  6 秒自消时序由 AppServices.showRestored 驱动（UI 横幅断言在 R8 UI suite）。
//

final class NetworkMonitorTests: XCTestCase {

    private static var wipedTags: Set<String> = []

    private func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "test_netmon_\(tag)"
        if !Self.wipedTags.contains(tag) {
            UserDefaults().removePersistentDomain(forName: name)
            Self.wipedTags.insert(tag)
        }
        return UserDefaults(suiteName: name)!
    }

    override func setUp() {
        super.setUp()
        OfflineGate.reset(now: 0)
    }

    override func tearDown() async throws {
        await MainActor.run {
            AppServices.shared.setOffline(jdb: false, sht: false)
            AppBootstrap.network.set(true)
        }
        try await super.tearDown()
    }

    // MARK: offline 注入 → 两库横幅 + epoch 不变

    @MainActor
    func testOfflineInjectionLightsBothBannersWithoutDataRefresh() async {
        let store = SettingsStore(defaults: freshDefaults("offline"))
        AppBootstrap.network.set(true)
        AppServices.shared.setOffline(jdb: false, sht: false)
        let e0 = store.dataEpoch
        let n0 = store.netEpoch

        NetworkMonitor.shared.apply(false, store: store)

        XCTAssertTrue(AppServices.shared.offlineJdb, "网络离线必须亮 javdb 横幅")
        XCTAssertTrue(AppServices.shared.offlineSht, "网络离线必须亮 98t 横幅")
        XCTAssertFalse(AppBootstrap.network.online, "Db 层 hasNetwork 盒必须翻 false")
        XCTAssertTrue(AppServices.shared.offlineLabel.contains("javdb"))
        XCTAssertTrue(AppServices.shared.offlineLabel.contains("98t"))
        XCTAssertEqual(store.netEpoch, n0, "离线迁移不得 bumpNet")
        XCTAssertEqual(store.dataEpoch, e0, "离线迁移不得 bumpData")
        XCTAssertFalse(AppServices.shared.restored, "离线不得触发恢复横幅")
    }

    // MARK: Db 分库标记合并（仅 jdb）

    @MainActor
    func testDbOfflineMarkMergesPerDb() async {
        let store = SettingsStore(defaults: freshDefaults("perdb"))
        AppServices.shared.setOffline(jdb: false, sht: false)

        Db.markOffline("jdb", ms: 60_000)
        AppServices.shared.syncOfflineFlags(networkOnline: true)

        XCTAssertTrue(AppServices.shared.offlineJdb, "Core jdb 离线标记必须并入横幅")
        XCTAssertFalse(AppServices.shared.offlineSht, "sht 在线不得误亮")
        XCTAssertFalse(AppServices.shared.restored, "单库离线不得触发恢复横幅")
    }

    // MARK: 恢复 → 复位 + restored + netEpoch

    @MainActor
    func testRestoreClearsFlagsAndBumpsNetOnly() async {
        let store = SettingsStore(defaults: freshDefaults("restore"))
        let e0 = store.dataEpoch
        let n0 = store.netEpoch

        // 先置离线（网络 + Db 双源）
        NetworkMonitor.shared.apply(false, store: store)
        Db.markOffline("jdb", ms: 60_000)
        AppServices.shared.syncOfflineFlags(networkOnline: false)
        XCTAssertTrue(AppServices.shared.offlineJdb)

        // 恢复
        NetworkMonitor.shared.apply(true, store: store)

        XCTAssertFalse(AppServices.shared.offlineJdb, "恢复必须复位横幅")
        XCTAssertFalse(AppServices.shared.offlineSht)
        XCTAssertFalse(Db.offlineJdb, "恢复必须清 Core 离线标记")
        XCTAssertTrue(AppServices.shared.restored, "恢复必须置恢复横幅")
        XCTAssertEqual(store.netEpoch, n0 + 1, "恢复必须 bumpNet")
        XCTAssertEqual(store.dataEpoch, e0, "恢复不得 bumpData（不自动重拉）")
    }

    // MARK: fake arg 解析

    func testFakeNetworkArgParsing() {
        XCTAssertNil(NetworkMonitor.fakeNetworkArgOrNil(for: []))
        XCTAssertEqual(NetworkMonitor.fakeNetworkArgOrNil(for: ["-JDLV_FAKE_NETWORK", "offline"]), "offline")
        XCTAssertEqual(NetworkMonitor.fakeNetworkArgOrNil(for: ["-JDLV_FAKE_NETWORK", "online"]), "online")
        XCTAssertNil(NetworkMonitor.fakeNetworkArgOrNil(for: ["-JDLV_FAKE_NETWORK"]))
    }
}
