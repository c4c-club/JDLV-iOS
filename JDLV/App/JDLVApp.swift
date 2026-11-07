import SwiftUI

@main
struct JDLVApp: App {
    @StateObject private var store: SettingsStore

    init() {
        let args = ProcessInfo.processInfo.arguments
        // A9/R8：UI 测试隔离钩子（Keychain service 覆盖 / 独立 defaults suite / 种子设置）
        KeychainStore.applyLaunchArgFaults(args)
        KeychainStore.applyServiceOverride(args)
        let defaults = SettingsStore.defaultsForLaunch(args)
        SettingsStore.applySeedIfPresent(args, defaults: defaults)
        // A1/R1：@main 最早时机完成生产 Bootstrap（Db.configure + CdnRewrite 注入 +
        // 副作用单入口 + 隧道收敛 + 网络监控）；同一实例交给 SwiftUI，避免双实例。
        let s = SettingsStore(defaults: defaults)
        AppBootstrap.start(store: s)
        _store = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        WindowGroup {
            AppGate()
                .environmentObject(store)
        }
    }
}
