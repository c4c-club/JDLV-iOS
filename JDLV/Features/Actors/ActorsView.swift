import SwiftUI
import JDLVCore

//
//  ActorsView.swift —— 女优列表页（09 A 节 ActorsScreen 移植）。
//
//  - ListScaffold 统一外壳内嵌 **固定 3 列** LazyVGrid（1:1 ActorCard，不受视图模式影响）；
//    网格内容边距 h10/v6、格间距 10。
//  - header（随列表滚动）= 搜索条（300ms 防抖 + 回车提交）+ 性别/排序两个下拉。
//  - footer = LoadMoreFooter（per=30；total 恒 -1 → 「已加载 N 条」/ PageChip「N / ?」）；
//    右下角 ListNavTools（页码 chip + 回顶按钮）。
//  - 空态文案逐字「远程库暂无女优数据 (离线时显示本地索引)」；骨架 3 列。
//

struct ActorsView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @StateObject private var vm: ActorsVM
    @State private var searchText = ""
    @State private var debounceTask: Task<Void, Never>? = nil

    init() {
        _vm = StateObject(wrappedValue: ActorsVM.makeDefault())
    }

    private var items: [Row] { vm.items ?? [] }

    /// 3 列 1:1（columnsOverride = 3，不受视图模式影响）
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    }

    var body: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { Task { await vm.refresh() } },
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

    // MARK: header（搜索条 + 性别/排序下拉，随列表滚动）

    private var actorsHeader: some View {
        VStack(spacing: 6) {
            SearchBarCompact(
                text: $searchText,
                placeholder: ActorsCopy.searchPlaceholder,
                onSearch: { Task { await submitSearch() } })
                .accessibilityIdentifier("actors_searchbar")
            HStack(spacing: 8) {
                DropdownBox(
                    label: ActorsCopy.genderLabel,
                    options: ActorsCopy.genderOptions.map {
                        DropdownOption(label: $0.label, value: $0.value)
                    },
                    current: vm.gender,
                    onSelect: { v in Task { await vm.setGender(v) } })
                DropdownBox(
                    label: ActorsCopy.sortLabel,
                    options: ActorsCopy.sortOptions.map {
                        DropdownOption(label: $0.label, value: $0.value)
                    },
                    current: vm.sort,
                    onSelect: { v in Task { await vm.setSort(v) } })
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: 3 列网格（ActorCard 点击 → nav("actor/{id}")）

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                ActorCard(a: a) {
                    router.push(.actor(a.s("id")))
                }
            }
        }
        .padding(.horizontal, 10)
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
