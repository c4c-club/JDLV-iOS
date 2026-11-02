import SwiftUI

// 6 Tab 固定顺序（Android TOP_DESTS）：搜索/浏览/女优/98t/收藏/设置。
// P1 为骨架：每 Tab 一页占位文字；后续阶段替换为各 Feature 页面。

struct AppRoot: View {
    private let theme = AppTheme.fallback()

    private struct TabDef {
        let route: String
        let label: String
        let icon: String
    }

    // 图标与 Android outlined/filled 语义对应（SF Symbols）
    private static let tabs: [TabDef] = [
        TabDef(route: "search", label: "搜索", icon: "magnifyingglass"),
        TabDef(route: "browse", label: "浏览", icon: "square.grid.2x2"),
        TabDef(route: "actors", label: "女优", icon: "face.smiling"),
        TabDef(route: "sht", label: "98t", icon: "bubble.left.and.bubble.right"),
        TabDef(route: "favs", label: "收藏", icon: "star"),
        TabDef(route: "settings", label: "设置", icon: "gearshape"),
    ]

    var body: some View {
        TabView {
            ForEach(Self.tabs, id: \.route) { tab in
                PlaceholderPage(label: tab.label)
                    .tabItem {
                        Label(tab.label, systemImage: tab.icon)
                    }
                    .accessibilityIdentifier("tab_\(tab.route)")
            }
        }
        .tint(theme.accent)
        .environment(\.appTheme, theme)
    }
}

private struct PlaceholderPage: View {
    @Environment(\.appTheme) private var theme
    let label: String

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            Text(label)
                .font(.system(size: Tx.titleM.size, weight: Tx.titleM.weight))
                .foregroundColor(theme.text)
        }
    }
}
