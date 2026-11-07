import SwiftUI

@main
struct JDLVApp: App {
    @StateObject private var store: SettingsStore

    init() {
        // A1/R1：@main 最早时机完成生产 Bootstrap（Db.configure + CdnRewrite 注入 +
        // store.$settings 订阅）；同一实例交给 SwiftUI，避免双实例。
        let s = SettingsStore()
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
