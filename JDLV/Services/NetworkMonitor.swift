import Foundation
import Network
import JDLVCore

//
//  NetworkMonitor.swift —— NWPathMonitor 接线（A5/R5）。
//
//  - 系统网络状态 → AppBootstrap.network 盒（Db 层 hasNetwork 前置检查的真数据源）
//    + AppServices 离线横幅；
//  - offline→online 恢复：清 Core 离线标记 + showRestored（6s 自消）+ bumpNet；
//    【不 bumpData、不自动重拉】；
//  - UI 测试注入：launch argument `-JDLV_FAKE_NETWORK=offline|online`
//    （不起真 monitor，直接置盒 —— 横幅/首页 isOnline 可确定性断言）。
//

@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    /// UI 测试注入值（nil = 正常模式）
    static func fakeNetworkArg() -> String? {
        fakeNetworkArgOrNil(for: ProcessInfo.processInfo.arguments)
    }

    /// 解析器（可注入参数列表，单测用）
    static func fakeNetworkArgOrNil(for args: [String]) -> String? {
        guard let i = args.firstIndex(of: "-JDLV_FAKE_NETWORK"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 当前网络可用（AppServices/HomeView 订阅）
    @Published private(set) var online = true

    private let monitor = NWPathMonitor()
    private var started = false

    /// App 启动时调用（AppBootstrap.start）
    func start(store: SettingsStore) {
        guard !started else { return }
        started = true

        if let fake = Self.fakeNetworkArg() {
            apply(fake != "offline", store: store)
            return
        }

        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.apply(satisfied, store: store)
            }
        }
        monitor.start(queue: DispatchQueue(label: "jdlv.netmon"))
    }

    // MARK: 状态迁移（可单测注入）

    func apply(_ isOnline: Bool, store: SettingsStore) {
        let was = online
        online = isOnline
        AppBootstrap.network.set(isOnline)
        guard was != isOnline else {
            // 首次/未变化：仅同步横幅与网络盒
            AppServices.shared.syncOfflineFlags(networkOnline: isOnline)
            return
        }
        if isOnline {
            // 恢复：清 Core 离线标记 → 横幅复位 + 恢复横幅 6s 自消 + bumpNet
            Db.clearOffline()
            AppServices.shared.syncOfflineFlags(networkOnline: true)
            store.bumpNet()
        } else {
            AppServices.shared.syncOfflineFlags(networkOnline: false)
        }
    }
}
