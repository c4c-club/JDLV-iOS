import SwiftUI

@main
struct JDLVApp: App {
    @StateObject private var store = SettingsStore()

    var body: some Scene {
        WindowGroup {
            AppGate()
                .environmentObject(store)
        }
    }
}
