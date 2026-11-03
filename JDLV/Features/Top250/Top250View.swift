import SwiftUI
import JDLVCore

//
//  Top250View.swift —— TOP250 完整页（10 §5 Top250Screen 移植）。
//
//  顶栏（自绘 Row，导航栏隐藏）：返回按钮 + 「🏆 TOP250」（TitleM）+ 副标题
//  「共 {total} 部 · 当前：全部/{year}年」（全角冒号）。年份 chips（「全部」+「{y} ({n})」
//  横向滚动）；LazyVGrid 列数 = viewMode==1 → 1；否则 ≥600pt/regular → 3；否则 2；
//  MovieCard 复用（0 小图 400:520 / 1 大图 800:520）；key = "t250_{id}"；点击 → movie/{id}；
//  LoadMoreFooter（per=40）+ ListNavTools。空态「该年份 TOP250 无数据」；骨架 2 列。
//

struct Top250View: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize

    @StateObject private var vm: Top250VM

    init() {
        _vm = StateObject(wrappedValue: Top250VM.makeDefault())
    }

    private var items: [Row] { vm.items ?? [] }

    /// 列数（§5.4）：viewMode==1 → 1 列；否则屏宽最短边 ≥600 或 regular → 3 列；否则 2 列
    private var gridColumns: Int {
        if vm.viewMode == 1 { return 1 }
        let short = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return (short >= 600 || hSize == .regular) ? 3 : 2
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: gridColumns)
    }

    var body: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { Task { await vm.refresh() } },
            firstLoading: vm.loading,
            empty: items.isEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: Top250Copy.emptyText,
            skeletonColumns: 2,
            loadMore: LoadMoreConfig(
                loaded: items.count, total: vm.total, loadingMore: vm.loadingMore,
                hasMore: vm.hasMore,
                onLoadNext: { Task { await vm.loadNext() } }),
            showNavTools: true,
            pageLoaded: items.count,
            pageTotal: vm.total,
            pagePer: vm.per,
            goPage: { p in Task { await vm.goPage(p) } }
        ) {
            topBar
            yearChips
            grid
        }
        .toolbar(.hidden, for: .navigationBar)   // 自绘顶栏（对位 Android 非 TopAppBar）
        .onAppear {
            if vm.store == nil { vm.store = store }
            Task { await vm.bind() }
        }
        // 刷新结果 Toast（仅手动下拉路径写入；消费后清位）
        .onReceive(vm.refreshChannel.$value) { r in
            guard let r else { return }
            services.showToast(r.toastText)
            vm.refreshChannel.consume()
        }
        .accessibilityIdentifier("top250_page")
    }

    // MARK: 顶栏（返回 + 标题 + 副标题）

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    router.pop()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 20))
                        .foregroundColor(theme.text)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                AppText(Top250Copy.title, lvl: .titleM)
                Spacer(minLength: 0)
            }
            AppText(Top250VM.subtitle(total: vm.total, year: vm.year), lvl: .meta,
                    color: theme.text2)
                .padding(.horizontal, 48)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: 年份 chips（首项「全部」+「{y} ({n})」；失败只剩「全部」）

    private var yearChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                AppToggleChip(label: Top250Copy.allYears, selected: vm.year.isEmpty) {
                    Task { await vm.setYear("") }
                }
                .accessibilityIdentifier("top250_year_all")
                ForEach(yearEntries, id: \.year) { e in
                    AppToggleChip(label: Top250Copy.yearChip(e.year, e.count),
                                  selected: vm.year == e.year) {
                        Task { await vm.setYear(e.year) }
                    }
                    .accessibilityIdentifier("top250_year_\(e.year)")
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
    }

    /// 年份行（year 为空的行跳过；Q 列 c / demo 列 n 双口径）
    private var yearEntries: [(year: String, count: Int64)] {
        vm.years.map { Top250VM.yearEntry($0) }.filter { !$0.year.isEmpty }
    }

    // MARK: 列表（MovieCard 复用；key = t250_{id}；点击 → movie/{id}）

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, m in
                MovieCard(m: m, viewMode: vm.viewMode, read: false, fav: false) {
                    router.push(.movie(m.s("id")))
                }
                .accessibilityIdentifier("t250_\(m.s("id"))")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
