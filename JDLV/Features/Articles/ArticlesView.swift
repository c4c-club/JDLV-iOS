import SwiftUI
import JDLVCore

//
//  ArticlesView.swift —— 资讯列表页（10 §2.2 ArticlesScreen 对位 + 13 §4.8 设计系统 v2）。
//
//  v2：PageScaffold（单 ScrollView + 单 LazyVStack + .refreshable + overlay 页码）；
//  header = SearchBarCompact（placeholder 逐字「搜索资讯标题 / 正文…」）+ 分类 chips
//  （横向滚动；首项固定「全部」，仅 categories 非空才显示）；行卡 ArticleRow 96pt
//  （缩略图 72×96、标题 2 行、元信息 1 行）；footer = LoadMoreFooter（per=24）。
//  空态文案两处相同：「暂无资讯 (需抓取端跑资讯任务并上传)」。
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
        PageScaffold(
            onRefresh: { await vm.refresh() },
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
            .padding(.horizontal, ComponentMetrics.pageMargin)
        }
    }

    // MARK: 行卡列表（ArticleRow 96pt 固定行高）

    private var list: some View {
        VStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                ArticleCard(a: a) {
                    router.push(.article(a.s("id")))
                }
            }
        }
        .padding(.horizontal, ComponentMetrics.pageMargin)
        .padding(.vertical, 6)
    }

    private func submitSearch() async {
        await vm.search(searchText)
    }
}

// MARK: - ArticleCard（13 §4.8：ArticleRow 96pt——缩略图 72×96 全出血、标题 2 行、元信息 1 行；
// 无图分类首字/「资」占位；「N 字」元信息）

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
                    .frame(width: 72, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    AppText(title.isEmpty ? " " : title, lvl: .bodyS,
                            maxLines: 2, textAlign: .leading,
                            fontWeight: .semibold, tight: true, reservesSpace: true)
                    AppText(metaText, lvl: .meta, maxLines: 1, tight: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 96, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
        .clipShape(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner))
        .accessibilityIdentifier("article_card")
    }

    // 左：封面 72×96；无封面 → 同尺寸占位块 + 分类首字/「资」
    @ViewBuilder
    private var cover: some View {
        if coverUrl.isEmpty {
            ZStack {
                Rectangle().fill(theme.bg3)
                AppText(placeholderChar, lvl: .titleM, color: theme.text2)
            }
        } else {
            AspectImage(url: coverUrl, ratio: 72.0 / 96.0, radius: 0)
        }
    }
}
