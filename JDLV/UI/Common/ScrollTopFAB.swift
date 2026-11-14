import SwiftUI

//
//  ScrollTopFAB.swift —— R4 P5 统一回顶 FAB（裸 ScrollView/List 页面用；
//  列表页走 PageScaffold 内 ListNavTools，二者共用同一视觉与 a11y id）。
//
//  - 阈值显隐：页面自持 @State showScrollTop（ScrollOffsetReader + scrollTopOffsetWatcher）；
//  - bottomInset：底部避让（TabBar 页 = 环境值 56；push 详情页 = 0）+ 基础 16；
//  - a11y：accessibilityIdentifier("scroll_top")（§8.5 UI 测试锚点）。
//

/// 统一回顶 FAB
struct ScrollTopFAB: View {
    /// true = 显示（页面滚动越过阈值）
    var visible: Bool
    var onTap: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        if visible {
            Button {
                onTap()
            } label: {
                AppText(AppCopy.scrollTopIcon, lvl: .body, color: .white, fontWeight: .bold)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .transition(.opacity)
            .accessibilityIdentifier("scroll_top")
        }
    }
}

/// 滚动 offset 源（放 ScrollView 内容首行；space = coordinateSpace 名）
struct ScrollOffsetReader: View {
    var space: String

    var body: some View {
        Color.clear
            .frame(height: 0)
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: PageScrollOffsetKey.self,
                    value: geo.frame(in: .named(space)).minY)
            })
    }
}

extension View {
    /// 阈值布尔翻转（PageScaffold 同口径：只在越过阈值时写 @State，不每帧写）
    func scrollTopOffsetWatcher(show: Binding<Bool>) -> some View {
        onPreferenceChange(PageScrollOffsetKey.self) { y in
            let should = y < ListScaffoldConst.scrollTopOffset
            if should != show.wrappedValue {
                withAnimation(.easeInOut(duration: 0.18)) { show.wrappedValue = should }
            }
        }
    }

    /// 右下角挂载回顶 FAB（bottom = bottomInset + 16）
    func scrollTopOverlay(visible: Bool, bottomInset: CGFloat = 0,
                          onTap: @escaping () -> Void) -> some View {
        overlay(alignment: .bottomTrailing) {
            ScrollTopFAB(visible: visible, onTap: onTap)
                .padding(.trailing, 12)
                .padding(.bottom, bottomInset + 16)
        }
    }
}
