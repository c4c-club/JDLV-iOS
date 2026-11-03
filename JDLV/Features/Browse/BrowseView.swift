import SwiftUI
import UIKit
import JDLVCore

//
//  BrowseView.swift —— 浏览页（08 A 节 BrowseScreen 逐字移植）。
//
//  结构：ListScaffold（下拉刷新/骨架/空/错统一外壳）内嵌 MovieGrid（LazyVGrid，
//  header = BrowseHeader，footer = ListScaffold 集成的 LoadMoreFooter，倒数 3 项触底加载）
//  + 右下角 ListNavTools（页码 chip + 回顶 FAB）。
//
//  BrowseHeader（随列表滚动）：反查摘要条（filterCount>0，A.2 拼接逐字）+ 一行横向
//  滚动 toolbar（排序下拉/顺序下拉/筛选按钮带徽标/视图切换/重置）+「收录顺序」口径说明。
//
//  视图三档（viewMode）：0 小图 2 列（最短边 ≥600 或 regular 宽度 3 列）/ 1 大图 1 列 /
//  2 列表行 1 列（「列表」档不在按钮循环内暴露，仅设置可设）。
//
//  入口：BrowseView(vm:embedded:skipBind:) —— browse tab 自持 @StateObject；
//  反查页 LookupView 传独立 VM 实例 + skipBind=true（不污染浏览 tab 筛选状态）。
//
//  空/错/离线态（A.6）：
//  - 主空态（total==0 && items 空）：derived 非空 → 「没有符合条件的影片」+ derived 副文案；
//    否则 → 「没有符合条件的影片」；非 0 命中分支 → 「无匹配结果 (远程 jdb 库可能为空,
//    需先在抓取端上传)」。
//  - 错误文案 ErrText.of 逐字（ErrorBox 原文透传）；ListScaffold 优先级 骨架→错→空→正文。
//  - 头部第二状态块（ListStatusBlock）：有数据时 loading 线性进度条（SWR 保留列表）/
//    error ErrorBox。
//
//  P13 注：封面离线兜底回填（Q.movieCovers）接线点在 BrowseVM.apply（注释占位）。
//

// MARK: - BrowseView（VM 归属：外部注入或自持）

struct BrowseView: View {
    /// embedded=true 供反查页复用（对位 Android BrowseScreen embedded 参数）
    var embedded: Bool = false
    /// skipBind=true：不执行 bind（反查由独立 VM 自己 applyFilters）
    var skipBind: Bool = false
    private var externalVM: BrowseVM?
    @StateObject private var ownedVM = BrowseVM()

    init(embedded: Bool = false, skipBind: Bool = false, vm: BrowseVM? = nil) {
        self.embedded = embedded
        self.skipBind = skipBind
        self.externalVM = vm
    }

    var body: some View {
        if let vm = externalVM {
            BrowseContent(vm: vm, embedded: embedded, skipBind: skipBind)
        } else {
            BrowseContent(vm: ownedVM, embedded: embedded, skipBind: skipBind)
        }
    }
}

// MARK: - BrowseContent

private struct BrowseContent: View {
    @ObservedObject var vm: BrowseVM
    var embedded: Bool
    var skipBind: Bool

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var showFilter = false

    // MARK: 派生

    private var items: [Row] { vm.items ?? [] }
    private var itemsEmpty: Bool { items.isEmpty }

    /// 列数：viewMode 1(大图)/2(列表) → 1 列；0(小图) → 手机 2 列、最短边 ≥600（或 regular）3 列
    private var gridColumns: Int {
        if vm.viewMode != 0 { return 1 }
        let short = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return (short >= 600 || hSize == .regular) ? 3 : 2
    }

    /// 主空态（A.6）：0 命中是空态不是错误
    private var emptyText: String {
        if vm.total == 0 && itemsEmpty { return "没有符合条件的影片" }
        return "无匹配结果 (远程 jdb 库可能为空, 需先在抓取端上传)"
    }

    private var emptyHint: String {
        (vm.total == 0 && itemsEmpty && !vm.derived.isEmpty) ? vm.derived : ""
    }

    // MARK: body

    var body: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { Task { await vm.refresh() } },
            firstLoading: vm.loading,
            empty: itemsEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: emptyText,
            emptyHint: emptyHint,
            skeletonColumns: gridColumns,
            loadMore: LoadMoreConfig(
                loaded: items.count, total: vm.total, loadingMore: vm.loadingMore,
                approx: vm.approx, note: vm.derived, hasMore: vm.hasMore,
                onLoadNext: { Task { await vm.loadNext() } }),
            showNavTools: true,
            pageLoaded: items.count,
            pageTotal: vm.total,
            pagePer: vm.per,
            goPage: { p in Task { await vm.goPage(p) } }
        ) {
            browseHeader
            if !itemsEmpty {
                grid
            }
        }
        .toolbar(.hidden, for: .navigationBar)   // 自绘 BrowseHeader（对位 Android 无 TopAppBar）
        .overlay {
            // 筛选面板：FilterDropdown 顶部下拉弹层（只在展开时 compose）
            FilterDropdown(expanded: showFilter, onDismiss: { showFilter = false }) {
                FiltersPanel(vm: vm) { showFilter = false }
            }
        }
        .onAppear {
            if vm.store == nil { vm.store = store }
            if vm.marks == nil { vm.marks = BrowseMarkSource.default() }
            if !skipBind {
                Task { await vm.bind(dataEpoch: store.dataEpoch) }
            }
        }
        .onChange(of: store.dataEpoch) { v in
            Task { await vm.onDataEpoch(v) }
        }
        // 刷新结果 Toast（仅手动下拉路径写入；消费后清位）
        .onReceive(vm.refreshChannel.$value) { r in
            guard let r else { return }
            services.showToast(r.toastText)
            vm.refreshChannel.consume()
        }
    }

    // MARK: BrowseHeader（摘要条 + toolbar + 口径说明 + 头部状态块）

    private var browseHeader: some View {
        VStack(spacing: 6) {
            if let summary = BrowseVM.lookupSummary(vm.f) {
                summaryBar(summary)
            }
            toolbarRow
            if vm.sort == "id" {
                // 「收录顺序」口径说明（Meta 字号、tertiary 色）
                AppText("库内无更新时间列，已按收录顺序排序", lvl: .meta, color: theme.accent2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            headerStatus
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// 反查摘要条：Surface 圆角条 + 右侧 32pt 关闭（contentDescription「清除反查」）
    private func summaryBar(_ summary: String) -> some View {
        HStack(spacing: 4) {
            AppText(summary, lvl: .meta, maxLines: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await vm.clearFilters() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundColor(theme.text2)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("清除反查")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.accent.opacity(0.15)))
    }

    /// 一行横向可滚动 toolbar（A.2 五控件从左到右）
    private var toolbarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                DropdownBox(
                    label: "排序", options: Self.sortOptions, current: vm.sort,
                    onSelect: { v in Task { await vm.setSort(v) } })
                DropdownBox(
                    label: "顺序",
                    options: [
                        DropdownOption(label: "倒序", value: "desc"),
                        DropdownOption(label: "正序", value: "asc"),
                    ],
                    current: vm.asc ? "asc" : "desc",
                    onSelect: { v in Task { await vm.setSortAsc(v == "asc") } })
                filterButton
                ViewToggleButton(viewMode: vm.viewMode) { v in vm.setViewMode(v) }
                Button {
                    Task { await vm.clearFilters() }
                } label: {
                    AppText("重置", lvl: .meta, color: theme.accent)
                        .frame(minHeight: ComponentMetrics.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("browse_toolbar")
    }

    /// 筛选按钮：FilledTonalButton + BadgedBox 徽标（filterCount > 0）
    private var filterButton: some View {
        Button {
            showFilter = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14))
                AppText("筛选", lvl: .meta)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: ComponentMetrics.chipHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(theme.accent.opacity(0.35), lineWidth: ComponentMetrics.cardStroke))
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if vm.filterCount > 0 {
                    AppText("\(vm.filterCount)", lvl: .meta, color: .white, fontWeight: .bold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent))
                        .offset(x: 10, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("browse_filter_button")
    }

    /// 头部第二状态块（ListStatusBlock；有数据时随滚动的第二处状态）
    @ViewBuilder
    private var headerStatus: some View {
        if !itemsEmpty {
            if vm.loading {
                // 2dp 顶部线性进度条（有数据时 SWR 保留列表）
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 2)
            }
            if let e = vm.error {
                ErrorBox(text: e, onRetry: { Task { await vm.reload() } })
            }
        }
    }

    // MARK: 网格

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: gridColumns),
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(items.indices, id: \.self) { i in
                let m = items[i]
                MovieCard(
                    m: m,
                    viewMode: vm.viewMode,
                    read: vm.readIds.contains(m.s("id")),
                    fav: vm.favIds.contains(m.s("id")),
                    onClick: { router.push(.movie(m.s("id"))) }   // nav("movie/{id}")
                )
                // 触底加载：可见末项进入倒数 3 项内触发（去重由 VM 的 loadingMore/hasMore 把关）
                .onAppear {
                    if i >= items.count - 3 {
                        Task { await vm.loadNext() }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityIdentifier("browse_grid")
    }

    private static let sortOptions = [
        DropdownOption(label: "发布日期", value: "release_date"),
        DropdownOption(label: "收录顺序", value: "id"),
        DropdownOption(label: "评分", value: "score"),
        DropdownOption(label: "想看人数", value: "want_watch_count"),
    ]
}
