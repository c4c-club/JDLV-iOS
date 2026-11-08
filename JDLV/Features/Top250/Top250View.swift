import SwiftUI
import JDLVCore

//
//  Top250View.swift —— TOP250 完整页（10 §5 Top250Screen 对位 + 13 §4.11 设计系统 v2）。
//
//  v2：PageScaffold（单 ScrollView + 单 LazyVStack + .refreshable + overlay 页码）；
//  navigationTitle("TOP 250") + 副标题（共 {total} 部 · 当前：全部/{year}年，全角冒号）
//  随列表滚动；年份 chips（「全部」+「{y} ({n})」横向滚动）；行卡 Top250Row 112pt
//  （排名徽标 + 缩略图 72×96 + 番号/标题 + 评分）；footer = LoadMoreFooter（per=40）。
//  空态「该年份 TOP250 无数据」；骨架 1 列。
//

struct Top250View: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @StateObject private var vm: Top250VM

    init() {
        _vm = StateObject(wrappedValue: Top250VM.makeDefault())
    }

    private var items: [Row] { vm.items ?? [] }

    var body: some View {
        PageScaffold(
            onRefresh: { await vm.refresh() },
            firstLoading: vm.loading,
            empty: items.isEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: Top250Copy.emptyText,
            skeletonColumns: 1,
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
            subtitleBar
            yearChips
            list
        }
        .navigationTitle("TOP 250")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    // MARK: 副标题（共 {total} 部 · 当前：全部/{year}年）

    private var subtitleBar: some View {
        AppText(Top250VM.subtitle(total: vm.total, year: vm.year), lvl: .meta,
                color: theme.text2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ComponentMetrics.pageMargin)
            .padding(.top, 4)
            // 页面身份锚点打在文本节点（staticText 必成 a11y 节点；容器 id 不可靠）
            .accessibilityIdentifier("top250_page")
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
            .padding(.horizontal, ComponentMetrics.pageMargin)
        }
        .padding(.vertical, 4)
    }

    /// 年份行（year 为空的行跳过；Q 列 c / demo 列 n 双口径）
    private var yearEntries: [(year: String, count: Int64)] {
        vm.years.map { Top250VM.yearEntry($0) }.filter { !$0.year.isEmpty }
    }

    // MARK: 行卡列表（Top250Row 112pt；点击 → movie/{id}）

    private var list: some View {
        VStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, m in
                Top250Row(m: m) {
                    router.push(.movie(m.s("id")))
                }
                .accessibilityIdentifier("t250row_\(i)")
            }
        }
        .padding(.horizontal, ComponentMetrics.pageMargin)
        .padding(.vertical, 6)
    }
}

// MARK: - Top250Row（13 §4.11：排名 + 缩略图 72×96 + 番号/标题 + 评分；行高 112）

struct Top250Row: View {
    let m: Row
    var onClick: () -> Void

    @Environment(\.appTheme) private var theme

    private var rank: String { m.s("rank").isEmpty ? m.s("ranking") : m.s("rank") }
    private var number: String { m.s("number") }
    private var title: String { m.s("title") }
    /// 封面（MovieImg.movieCover；thumb 无效不回退裸 id）
    private var coverUrl: String {
        let t = m.s("cover_url").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : MovieImg.movieCover(t, m.s("id"))
    }

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .center, spacing: 10) {
                AppText(rank.isEmpty ? " " : "#\(rank)", lvl: .bodyS, color: theme.accent,
                        maxLines: 1, fontWeight: .bold)
                    .frame(width: 40, alignment: .center)
                AspectImage(url: coverUrl, ratio: 72.0 / 96.0, radius: 8)
                    .frame(width: 72, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    AppText(number.isEmpty ? " " : number, lvl: .bodyS, color: theme.accent,
                            maxLines: 1, fontWeight: .bold, tight: true)
                    AppText(title.isEmpty ? " " : title, lvl: .meta, maxLines: 2,
                            textAlign: .leading, tight: true, reservesSpace: true)
                    if m.d("score") > 0 {
                        AppText("★ \(Fmt.score(m.d("score")))", lvl: .meta,
                                color: theme.accent2, tight: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(height: 112, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
        .clipShape(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner))
        .accessibilityIdentifier("top250_row")
    }
}
