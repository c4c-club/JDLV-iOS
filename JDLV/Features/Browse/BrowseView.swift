import SwiftUI
import UIKit
import JDLVCore

//
//  BrowseView.swift —— 浏览页（08 A 节 BrowseScreen 对位 + 13 §4.2 设计系统 v2 重写）。
//
//  v2 结构（问题 7/11 修复）：PageScaffold（单 ScrollView + 单 LazyVStack + 原生
//  .refreshable + overlay 页码）内嵌 CardGrid（等宽等高 + 最后一行占位）。
//  顶部控件 iOS 原生化：navigationTitle("浏览") + toolbar Menu（排序/顺序/视图）
//  + 筛选按钮（badge）→ .sheet FilterSheet（Form）；FilterDropdown 顶部弹层退役。
//  反查摘要条保留内容顶部（filterCount>0，A.2 拼接逐字）。
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
//

// MARK: - BrowseView（VM 归属：外部注入或自持）

struct BrowseView: View {
    /// embedded=true 供反查页复用（对位 Android BrowseScreen embedded 参数）
    var embedded: Bool = false
    /// skipBind=true：不执行 bind（反查由独立 VM 自己 applyFilters）
    var skipBind: Bool = false
    private var externalVM: BrowseVM?
    /// 覆盖导航标题（反查页传 spec.label；默认「浏览」）
    var title: String = "浏览"
    @StateObject private var ownedVM = BrowseVM()

    init(embedded: Bool = false, skipBind: Bool = false, vm: BrowseVM? = nil,
         title: String = "浏览") {
        self.embedded = embedded
        self.skipBind = skipBind
        self.externalVM = vm
        self.title = title
    }

    var body: some View {
        if let vm = externalVM {
            BrowseContent(vm: vm, embedded: embedded, skipBind: skipBind, title: title)
        } else {
            BrowseContent(vm: ownedVM, embedded: embedded, skipBind: skipBind, title: title)
        }
    }
}

// MARK: - BrowseContent

private struct BrowseContent: View {
    @ObservedObject var vm: BrowseVM
    var embedded: Bool
    var skipBind: Bool
    var title: String

    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.containerWidth) private var envWidth

    @State private var showFilter = false

    // MARK: 派生

    private var items: [Row] { vm.items ?? [] }
    private var itemsEmpty: Bool { items.isEmpty }

    private var pageWidth: CGFloat { resolvedContainerWidth(envWidth, hSize: hSize) }

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
        PageScaffold(
            onRefresh: { await vm.refresh() },
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(embedded ? .inline : .large)
        .toolbar { browseToolbar }
        .sheet(isPresented: $showFilter) {
            NavigationStack {
                FiltersPanel(vm: vm) { showFilter = false }
            }
            .presentationDetents([.large])
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
        .accessibilityIdentifier("browse_page")
    }

    // MARK: toolbar（iOS 原生：排序/顺序 Menu + 视图 Menu + 筛选 badge）

    @ToolbarContentBuilder
    private var browseToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                ForEach(Self.sortOptions, id: \.value) { opt in
                    Button {
                        Task { await vm.setSort(opt.value) }
                    } label: {
                        if vm.sort == opt.value {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
                Divider()
                Button {
                    Task { await vm.setSortAsc(false) }
                } label: {
                    if !vm.asc {
                        Label("倒序", systemImage: "checkmark")
                    } else {
                        Text("倒序")
                    }
                }
                Button {
                    Task { await vm.setSortAsc(true) }
                } label: {
                    if vm.asc {
                        Label("正序", systemImage: "checkmark")
                    } else {
                        Text("正序")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("browse_sort_menu")

            Menu {
                Button {
                    vm.setViewMode(0)
                } label: {
                    if vm.viewMode == 0 { Label(AppCopy.viewSmall, systemImage: "checkmark") }
                    else { Text(AppCopy.viewSmall) }
                }
                Button {
                    vm.setViewMode(1)
                } label: {
                    if vm.viewMode == 1 { Label(AppCopy.viewLarge, systemImage: "checkmark") }
                    else { Text(AppCopy.viewLarge) }
                }
                Button {
                    vm.setViewMode(2)
                } label: {
                    if vm.viewMode == 2 { Label(AppCopy.viewList, systemImage: "checkmark") }
                    else { Text(AppCopy.viewList) }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityIdentifier("browse_view_menu")

            Button {
                showFilter = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .overlay(alignment: .topTrailing) {
                        if vm.filterCount > 0 {
                            AppText("\(vm.filterCount)", lvl: .meta, color: .white,
                                    fontWeight: .bold, tight: true)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(theme.accent))
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .accessibilityIdentifier("browse_filter_button")
        }
    }

    // MARK: BrowseHeader（摘要条 + 口径说明 + 头部状态块）

    private var browseHeader: some View {
        VStack(spacing: 6) {
            if let summary = BrowseVM.lookupSummary(vm.f) {
                summaryBar(summary)
            }
            if vm.sort == "id" {
                // 「收录顺序」口径说明（Meta 字号、tertiary 色）
                AppText("库内无更新时间列，已按收录顺序排序", lvl: .meta, color: theme.accent2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ComponentMetrics.pageMargin)
            }
            headerStatus
        }
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
        .padding(.horizontal, ComponentMetrics.pageMargin)
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

    // MARK: 网格（CardGrid 等宽等高）

    private var grid: some View {
        let cols = gridColumns
        let cellW = GridMath.cellWidth(pageWidth: pageWidth, columns: cols)
        let cardH: CGFloat
        switch vm.viewMode {
        case 1: cardH = CardLayout.movieLargeH(cellW: cellW)
        case 2: cardH = 96   // 列表行
        default: cardH = CardLayout.movieSmallH(cellW: cellW)
        }
        return CardGrid(items: items.indices.map { ($0, items[$0]) },
                        columns: cols, cellWidth: cellW, cellHeight: cardH) { pair in
            let (i, m) = pair
            return Group {
                if vm.viewMode == 2 {
                    MovieCard(m: m, viewMode: 2,
                              read: vm.readIds.contains(m.s("id")),
                              fav: vm.favIds.contains(m.s("id")),
                              onClick: { router.push(.movie(m.s("id"))) })
                        .frame(height: 96)
                } else {
                    MovieCard(m: m, viewMode: vm.viewMode,
                              read: vm.readIds.contains(m.s("id")),
                              fav: vm.favIds.contains(m.s("id")),
                              onClick: { router.push(.movie(m.s("id"))) })
                }
            }
            // 触底加载：可见末项进入倒数 3 项内触发（去重由 VM 的 loadingMore/hasMore 把关）
            .accessibilityIdentifier("card_browse_\(i)")
            .onAppear {
                if i >= items.count - 3 {
                    Task { await vm.loadNext() }
                }
            }
        }
        .padding(.horizontal, ComponentMetrics.pageMargin)
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
