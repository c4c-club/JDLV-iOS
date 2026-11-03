import SwiftUI

//
//  Banners.swift —— 顶部横幅 + Toast（07 A5）。
//
//  - OfflineBanner（离线横幅，按库粒度）：Surface(accent2 18% 底)、文字 12pt accent2、
//    padding 16h/8v、fillMaxWidth。文案逐字：
//    「⚠ 远程库不可达：{offlineLabel} — 正在显示缓存数据 (恢复后下拉刷新)」
//    offlineLabel = listOfNotNull("javdb".takeIf{jdb}, "98t".takeIf{sht}).join(" · ")，
//    不允许一刀切"远程数据库不可达"。
//  - RestoredBanner（恢复横幅）：accent 20% 底、12pt text、padding 16h/8v；
//    文案逐字「✓ 网络已恢复 — 下拉刷新查看最新数据」；显示 6 秒自消（AppServices
//    showRestored 里 Task.sleep 驱动），且不触发列表自动重拉。
//  - ToastHost：全局 Toast（SnackbarHost 对位）：底部胶囊，显示后约 2s 自动 clearToast。
//

// MARK: - 离线横幅（按库拼接 javdb · 98t）

struct OfflineBanner: View {
    var offlineJdb: Bool
    var offlineSht: Bool

    @Environment(\.appTheme) private var theme

    private var offlineLabel: String {
        var parts: [String] = []
        if offlineJdb { parts.append("javdb") }
        if offlineSht { parts.append("98t") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if !offlineLabel.isEmpty {
            AppText(AppCopy.offlineBanner(offlineLabel), lvl: .meta, color: theme.accent2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.accent2.opacity(0.18))
        }
    }
}

// MARK: - 恢复横幅（6 秒自消由 AppServices 驱动）

struct RestoredBanner: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        AppText(AppCopy.restoredBanner, lvl: .meta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(theme.accent.opacity(0.20))
    }
}

// MARK: - ToastHost（全局单一 Toast 通道的消费端）

struct ToastHost: View {
    /// 显式传入（overlay 挂在 TabView 之外，environmentObject 注入对 overlay 兄弟层不保证可见）
    @ObservedObject var services: AppServices
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let msg = services.toast {
                AppText(msg, lvl: .meta, color: theme.text, textAlign: .center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.bg2))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: services.toast)
    }
}
