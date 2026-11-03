import SwiftUI
import UIKit

//
//  ListScaffold.swift —— 全 App 列表统一外壳（07 B10、08 A.1、10 §0.1）。
//
//  下拉刷新（自定义四态指示器，替换默认转圈）：
//  - refreshing → 14pt 转圈 + 「正在刷新…」（Meta）
//  - 拉动中 distanceFraction > 0.04 → 「下拉可以刷新」；拉满 ≥1 → 「松开立即刷新」
//  - 指示条：顶部胶囊、bottomStart/End 圆角 14、surfaceContainerHigh(theme.bg2) 底、
//    tonalElevation 3（投影）、padding 16h/7v，fadeIn+expandVertically 对位
//    opacity + move(edge: .top) 过渡。
//
//  内容四态优先级：firstLoading && empty → SkeletonGrid(skeletonColumns)；
//  error != null → ErrorBox(error, onRetry)；empty → EmptyBox(emptyText)；否则 content。
//  （refreshing 与 firstLoading 是两个独立状态：刷新不闪白、不回骨架。）
//
//  集成件：LoadMoreFooter（loadMore 配置非 nil 时自动挂在内容尾）、
//  ListNavTools（showNavTools=true 时右下角 PageChip + 回顶 FAB）。
//  页面自定义 footer/表头扩展直接放进 content（随列表滚动）。
//
//  下拉手势实现口径（iOS 16 无系统级自定义指示器）：ScrollView 顶部锚点 offset 监听，
//  过顶回弹（overscroll）超阈值置 armed，回落时触发 onRefresh —— 与 Android
//  distanceFraction 语义对齐；精确跟手感在 P9 页面接入时校准。
//

/// 内容顶部相对滚动容器的 offset（过顶为正、下滚为负）。
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 仅底部两角圆角（iOS 16 无 UnevenRoundedRectangle，自绘对位 bottomStart/End 14dp）。
struct BottomRoundedCorners: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect,
                          byRoundingCorners: [.bottomLeft, .bottomRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

enum LS {
    static let space = "ls_space"
    static let topAnchor = "ls_top"
    /// 回顶 FAB 显隐阈值（≈滚过 3 行）
    static let scrollTopOffset: CGFloat = -360
}

struct ListScaffold<Content: View>: View {
    var refreshing: Bool
    var onRefresh: () -> Void = {}
    var firstLoading: Bool = false
    var empty: Bool = false
    var error: String? = nil
    var onRetry: (() -> Void)? = nil
    var emptyText: String
    var emptyHint: String = ""
    var skeletonColumns: Int = 2

    /// LoadMoreFooter 集成（nil = 无分页 footer）
    var loadMore: LoadMoreConfig? = nil

    /// ListNavTools 集成（false = 不挂右下角工具）
    var showNavTools: Bool = false
    var pageLoaded: Int = 0
    var pageTotal: Int64 = -1
    var pagePer: Int = 40
    var goPage: ((Int) -> Void)? = nil

    @ViewBuilder var content: () -> Content

    @Environment(\.appTheme) private var theme
    @State private var scrollY: CGFloat = 0
    @State private var armed = false


    private var pullOffset: CGFloat { max(0, scrollY) }
    private var distanceFraction: CGFloat {
        pullOffset / max(ComponentMetrics.refreshThreshold, 1)
    }
    private var indicatorVisible: Bool {
        refreshing || pullOffset > ComponentMetrics.refreshThreshold * 0.04
    }
    private var indicatorText: String {
        if refreshing { return AppCopy.refreshTextRefreshing }
        return distanceFraction >= 1 ? AppCopy.refreshTextRelease : AppCopy.refreshTextPull
    }

    var body: some View {
        ZStack(alignment: .top) {
            theme.bg0.ignoresSafeArea()
            ScrollViewReader { proxy in
                ZStack(alignment: .top) {
                    scrollArea(proxy)
                    refreshIndicator
                }
                if showNavTools {
                    ListNavTools(loaded: pageLoaded, total: pageTotal, per: pagePer,
                                 goPage: goPage,
                                 showScrollTop: scrollY < Self.LS.scrollTopOffset) {
                        withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
    }

    // MARK: 滚动区

    private func scrollArea(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            offsetReader
            stateBody
        }
        .coordinateSpace(name: Self.LS.space)
        .onPreferenceChange(ScrollOffsetKey.self) { handleOffset($0) }
    }

    /// 顶部锚点：offset 源 + 回顶目标
    private var offsetReader: some View {
        Color.clear
            .frame(height: 0)
            .background(GeometryReader { geo in
                Color.clear.preference(
                    key: ScrollOffsetKey.self,
                    value: geo.frame(in: .named(Self.LS.space)).minY)
            })
            .id(Self.LS.topAnchor)
    }

    // MARK: 四态内容（优先级：骨架 → 错 → 空 → 正文）

    @ViewBuilder
    private var stateBody: some View {
        if firstLoading && empty {
            SkeletonGrid(columns: skeletonColumns)
        } else if let e = error {
            ErrorBox(text: e, onRetry: onRetry)
        } else if empty {
            EmptyBox(text: emptyText, hint: emptyHint)
        } else {
            VStack(spacing: 0) {
                content()
                if let cfg = loadMore {
                    LoadMoreFooter(config: cfg)
                }
            }
        }
    }

    // MARK: 下拉刷新指示条

    @ViewBuilder
    private var refreshIndicator: some View {
        if indicatorVisible {
            HStack(spacing: 8) {
                if refreshing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .frame(width: 14, height: 14)
                }
                AppText(indicatorText, lvl: .meta)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                BottomRoundedCorners(radius: 14)
                    .fill(theme.bg2)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: offset 状态机（armed 置位 / 回落触发）

    private func handleOffset(_ y: CGFloat) {
        scrollY = y
        let over = max(0, y)
        if over >= ComponentMetrics.refreshThreshold {
            if !armed && !refreshing { armed = true }
        } else if armed && over < ComponentMetrics.refreshThreshold * 0.35 {
            armed = false
            if !refreshing { onRefresh() }
        } else if over <= 0 {
            armed = false
        }
    }
}
