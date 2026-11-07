import SwiftUI
import JDLVCore

//
//  ActorsView.swift —— 女优列表页（09 A 节 ActorsScreen 对位 + 13 §4.4 设计系统 v2）。
//
//  v2：PageScaffold（单 ScrollView + 单 LazyVStack + .refreshable + overlay 页码）
//  内嵌 **固定 3 列** CardGrid（1:1 ActorCard，cardH = cellW + 44，等宽等高 + 占位）；
//  性别/排序 iOS 原生 toolbar Menu；搜索条随列表滚动（300ms 防抖 + 回车提交）。
//  footer = LoadMoreFooter（per=30；total 恒 -1 → 「已加载 N 条」/ PageChip「N / ?」）。
//  空态文案逐字「远程库暂无女优数据 (离线时显示本地索引)」；骨架 3 列。
//

struct ActorsView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.containerWidth) private var envWidth

    @StateObject private var vm: ActorsVM
    @State private var searchText = ""
    @State private var debounceTask: Task<Void, Never>? = nil

    init() {
        _vm = StateObject(wrappedValue: ActorsVM.makeDefault())
    }

    private var items: [Row] { vm.items ?? [] }
    private var pageWidth: CGFloat { resolvedContainerWidth(envWidth, hSize: hSize) }

    var body: some View {
        PageScaffold(
            onRefresh: { await vm.refresh() },
            firstLoading: vm.loading,
            empty: items.isEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: ActorsCopy.emptyText,
            skeletonColumns: 3,
            loadMore: LoadMoreConfig(
                loaded: items.count, total: vm.total, loadingMore: vm.loadingMore,
                approx: false, hasMore: vm.hasMore,
                onLoadNext: { Task { await vm.loadNext() } }),
            showNavTools: true,
            pageLoaded: items.count,
            pageTotal: vm.total,
            pagePer: vm.per,
            goPage: { p in Task { await vm.goPage(p) } }
        ) {
            actorsHeader
            if !items.isEmpty {
                grid
            }
        }
        .navigationTitle("女优")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { actorsToolbar }
        .onAppear {
            if vm.store == nil { vm.store = store }
            Task { await vm.bind() }
        }
        .onChange(of: searchText) { _ in scheduleDebouncedSearch() }
        // 刷新结果 Toast（仅手动下拉路径写入；消费后清位）
        .onReceive(vm.refreshChannel.$value) { r in
            guard let r else { return }
            services.showToast(r.toastText)
            vm.refreshChannel.consume()
        }
        .onReceive(store.$dataEpoch) { v in
            Task { await vm.onDataEpoch(v) }
        }
        .accessibilityIdentifier("tab_root_actors")
    }

    // MARK: toolbar（性别/排序 iOS 原生 Menu）

    @ToolbarContentBuilder
    private var actorsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Menu {
                ForEach(ActorsCopy.genderOptions, id: \.value) { opt in
                    Button {
                        Task { await vm.setGender(opt.value) }
                    } label: {
                        if vm.gender == opt.value {
                            Label(opt.label, systemImage: "checkmark")
                        } else {
                            Text(opt.label)
                        }
                    }
                }
            } label: {
                Image(systemName: "person.2")
            }
            .accessibilityIdentifier("actors_gender_menu")

            Menu {
                ForEach(ActorsCopy.sortOptions, id: \.value) { opt in
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
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("actors_sort_menu")
        }
    }

    // MARK: header（搜索条，随列表滚动）

    private var actorsHeader: some View {
        SearchBarCompact(
            text: $searchText,
            placeholder: ActorsCopy.searchPlaceholder,
            onSearch: { Task { await submitSearch() } })
            .accessibilityIdentifier("actors_searchbar")
            .padding(.top, 6)
    }

    // MARK: 3 列网格（CardGrid 等宽等高；ActorCard 点击 → nav("actor/{id}")）

    private var grid: some View {
        let cellW = GridMath.cellWidth(pageWidth: pageWidth, columns: 3)
        return CardGrid(items: items.indices.map { ($0, items[$0]) },
                        columns: 3, cellWidth: cellW,
                        cellHeight: CardLayout.actorH(cellW: cellW)) { pair in
            let (i, a) = pair
            return ActorCard(a: a) {
                router.push(.actor(a.s("id")))
            }
            .accessibilityIdentifier("card_actors_\(i)")
        }
        .padding(.horizontal, ComponentMetrics.pageMargin)
        .padding(.vertical, 6)
    }

    // MARK: 搜索（回车立即提交；输入 300ms 防抖）

    private func submitSearch() async {
        debounceTask?.cancel()
        await vm.search(searchText)
    }

    private func scheduleDebouncedSearch() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await vm.search(searchText)
        }
    }
}
