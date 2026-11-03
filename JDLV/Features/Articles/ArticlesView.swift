import SwiftUI
import JDLVCore

//
//  ArticlesView.swift —— 资讯列表页（10 §2.2 ArticlesScreen 移植）。
//
//  结构：ListScaffold（骨架 1 列）内 header = SearchBarCompact（placeholder 逐字
//  「搜索资讯标题 / 正文…」）+ 分类 chips（横向滚动；首项固定「全部」）+ ArticleCard 行卡；
//  footer = LoadMoreFooter（per=24）；右下角 ListNavTools（goPage 本地 ceil 钳制）。
//  空态文案两处相同：「暂无资讯 (需抓取端跑资讯任务并上传)」。
//  分类 chips 仅在 st.categories 非空才显示（远程库无分类 → 只剩列表）。
//

struct ArticlesView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @StateObject private var vm: ArticlesVM
    @State private var searchText = ""

    init() {
        _vm = StateObject(wrappedValue: ArticlesVM.makeDefault())
    }

    private var items: [Row] { vm.items ?? [] }

    var body: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { Task { await vm.refresh() } },
            firstLoading: vm.loading,
            empty: items.isEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: ArticlesCopy.emptyText,
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
            articlesHeader
            list
        }
        .navigationTitle("资讯")
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
        .onReceive(store.$dataEpoch) { v in
            Task { await vm.onDataEpoch(v) }
        }
        .accessibilityIdentifier("articles_page")
    }

    // MARK: header（搜索条 + 分类 chips）

    private var articlesHeader: some View {
        VStack(spacing: 6) {
            SearchBarCompact(
                text: $searchText,
                placeholder: ArticlesCopy.searchPlaceholder,
                onSearch: { Task { await submitSearch() } })
                .accessibilityIdentifier("articles_searchbar")
            if !vm.categories.isEmpty {
                categoryChips
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    /// 分类 chips：首项固定「全部」（categoryId=nil）+ 各 category_name（n DESC）
    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                AppToggleChip(label: ArticlesCopy.allCategory, selected: vm.categoryId == nil) {
                    Task { await vm.setCategory(nil) }
                }
                .accessibilityIdentifier("articles_cat_all")
                ForEach(Array(vm.categories.enumerated()), id: \.offset) { _, c in
                    let cid = Int(c.i("category_id"))   // Q.articleCategories 列 INT → VM Int?
                    AppToggleChip(label: c.s("category_name"), selected: vm.categoryId == cid) {
                        Task { await vm.setCategory(cid) }
                    }
                    .accessibilityIdentifier("articles_cat_\(cid)")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: 行卡列表（MovieGrid viewMode=2 固定 1 列行式对位）

    private var list: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                ArticleCard(a: a) {
                    router.push(.article(a.s("id")))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func submitSearch() async {
        await vm.search(searchText)
    }
}

// MARK: - ArticleCard（10 §2.3：左图右文 128×96；无图分类首字/「资」占位；「N 字」元信息）

struct ArticleCard: View {
    let a: Row
    var onClick: () -> Void

    @Environment(\.appTheme) private var theme

    private var title: String { a.s("title") }
    private var categoryName: String { a.s("category_name") }
    /// 封面（Img.articleCover(cover_url 空则 cover_path)）
    private var coverUrl: String {
        ArticleImg.articleCover(a.s("cover_url").isEmpty ? a.s("cover_path") : a.s("cover_url"))
    }
    /// 元信息：分类名/作者名/released_at 前 10 位/{n} 字（word_count>0 才有）
    private var metaText: String { AppCopy.joinMeta(ArticlesVM.cardMetaParts(a)) }
    /// 无封面占位字：分类名首字；分类名为空「资」
    private var placeholderChar: String {
        categoryName.first.map(String.init) ?? "资"
    }

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    AppText(title.isEmpty ? " " : title, lvl: .body,
                            maxLines: 2, textAlign: .leading, fontWeight: .semibold)
                    AppText(metaText, lvl: .meta, maxLines: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(minHeight: 104, maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
        .accessibilityIdentifier("article_card")
    }

    // 左：封面 128×96（4:3）；无封面 → 同尺寸圆角占位块 + 分类首字/「资」
    @ViewBuilder
    private var cover: some View {
        if coverUrl.isEmpty {
            ZStack {
                RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner).fill(theme.bg3)
                AppText(placeholderChar, lvl: .titleM, color: theme.text2)
            }
            .frame(width: 128, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner))
        } else {
            PosterImage(url: coverUrl)
                .frame(width: 128, height: 96)
        }
    }
}
