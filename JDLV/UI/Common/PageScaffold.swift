import SwiftUI

//
//  PageScaffold.swift —— 设计系统 v2 统一页面壳（13 §3.3：单 ScrollView + 单 LazyVStack）。
//
//  修复口径（问题 7 根因 ListScaffold.swift:90-108）：
//  - ListNavTools 不再作为 ScrollView 的兄弟节点 + maxHeight .infinity（争高 → 下半屏空白），
//    改为 `.overlay(alignment: .bottomTrailing)` 挂在 ScrollView 上。
//  - 下拉刷新用 iOS 原生 .refreshable（删除自定义 offset 状态机，不参与布局）。
//  - 四态不包 VStack：Group 直接作为 ScrollView 内容优先级分支。
//  - 结构：ScrollView { LazyVStack(alignment:.leading, spacing:0) { content(); footer } }。
//
//  回顶：scrollOffset 监听仅用于回顶 FAB 显隐（PreferenceKey 只读，不驱动刷新）。
//

struct PageScaffold<Content: View>: View {
    var onRefresh: (() async -> Void)? = nil
    var firstLoading: Bool = false
    var empty: Bool = false
    var error: String? = nil
    var onRetry: (() -> Void)? = nil
    var emptyText: String
    var emptyHint: String = ""
    var skeletonColumns: Int = 2

    /// LoadMoreFooter 集成（nil = 无分页 footer）
    var loadMore: LoadMoreConfig? = nil

    /// 右下角 PageChip + 回顶（false = 不挂）
    var showNavTools: Bool = false
    var pageLoaded: Int = 0
    var pageTotal: Int64 = -1
    var pagePer: Int = 40
    var goPage: ((Int) -> Void)? = nil

    @ViewBuilder var content: () -> Content

    @Environment(\.appTheme) private var theme
    // R4 P4：滚动状态降频 —— 不再每帧写 CGFloat @State（整页 body 重求值的根因）；
    // 只在越过回顶阈值时翻转布尔，showScrollTop 只影响 FAB 显隐，不驱动内容。
    @State private var showScrollTop = false

    var body: some View {
        ScrollViewReader { proxy in
            scrollView(proxy)
                .overlay(alignment: .bottomTrailing) {
                    if showNavTools {
                        ListNavTools(loaded: pageLoaded, total: pageTotal, per: pagePer,
                                     goPage: goPage,
                                     showScrollTop: showScrollTop) {
                            withAnimation { proxy.scrollTo(ListScaffoldConst.topAnchor, anchor: .top) }
                        }
                    }
                }
        }
        .background(theme.bg0.ignoresSafeArea())
    }

    private func scrollView(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if let onRefresh {
                core
                    .refreshable { await onRefresh() }
            } else {
                core
            }
        }
    }

    private var core: some View {
        GeometryReader { geo in
            ScrollView {
                offsetReader
                stateBody
            }
            .coordinateSpace(name: ListScaffoldConst.space)
            .onPreferenceChange(PageScrollOffsetKey.self) { y in
                let should = y < ListScaffoldConst.scrollTopOffset
                if should != showScrollTop {
                    withAnimation(.easeInOut(duration: 0.18)) { showScrollTop = should }
                }
            }
            .environment(\.containerWidth, geo.size.width)
            // R4 P3：真实容器宽度向上发 preference —— 页面在 PageScaffold 实例上
            // .onPreferenceChange 接住后写入 @State（body 内读到的不再是 393 兜底）
            .preference(key: PageContainerWidthKey.self, value: geo.size.width)
        }
    }

    /// 四态优先级：骨架 → 错 → 空 → 正文（正文 = content + LoadMoreFooter）
    @ViewBuilder
    private var stateBody: some View {
        if firstLoading && empty {
            SkeletonGrid(columns: skeletonColumns)
        } else if let e = error {
            ErrorBox(text: e, onRetry: onRetry)
        } else if empty {
            EmptyBox(text: emptyText, hint: emptyHint)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
                if let cfg = loadMore {
                    LoadMoreFooter(config: cfg)
                }
            }
            .id(ListScaffoldConst.topAnchor)
        }
    }

    /// 顶部锚点：offset 源 + 回顶目标
    private var offsetReader: some View {
        Color.clear
            .frame(height: 0)
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: PageScrollOffsetKey.self,
                    value: geo.frame(in: .named(ListScaffoldConst.space)).minY)
            })
    }
}

/// PageScaffold 常量（与旧 ListScaffold 的 LS 命名空间分开，避免互相耦合）
enum ListScaffoldConst {
    static let space = "ps_space"
    static let topAnchor = "ps_top"
    /// 回顶 FAB 显隐阈值（≈滚过 3 行）
    static let scrollTopOffset: CGFloat = -360
}

/// 滚动 offset（过顶为正）
struct PageScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 真实容器宽度（R4 P3：PageScaffold 内 GeometryReader 发出，页面上收；
/// 替代 393 硬编码兜底 —— 320/375/402/430pt 的 cell 宽一律以实测为准）
struct PageContainerWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
