import SwiftUI
import JDLVCore

//
//  HomeView.swift —— 搜索 Tab = 首页三段态 + 搜索态（07 C 节 SearchScreen 对位）。
//
//  骨架：ListScaffold 包单个滚动容器（LazyVStack）；搜索条/范围 chips/匹配+视图/
//  引导卡/资讯热评入口/搜索历史全部随列表滚出屏幕（勿固定 header，07 C0/C8 注 1）。
//
//  三态：
//  - setup（C1）：全屏首启引导（不查询）。
//  - 首页态（items==nil && home!=nil）：三段竖排区块（🆕 最近更新 / 🔥 最多想看 /
//    🏆 TOP250），段头「查看全部 ›」三分支：recent/hot → lookup 压栈（label 逐字、
//    sort release_date / want_watch_count），top → push .top250；每段一行横滑
//    MovieCard(宽 180) + ViewAllCard；大图模式（viewMode==1）每段直接平铺 grid。
//  - 结果态（items!=nil && query 非空）：网格 MovieCard（viewMode 1/2 → 1 列；
//    小图 2 列 / 屏宽 regular 3 列）+ 精确范围标注 + 本地索引来源标注（点击改远程）+
//    LoadMoreFooter + ListNavTools 跳页。
//
//  交互：输入 300ms 防抖可取消；范围/模式切换立即重搜；历史 chips（UserDefaults
//  jdlv_search_history 上限 10）；下拉刷新/重试按 query 空否分流（C0）。
//

struct HomeView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var services: AppServices
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize

    @StateObject private var vm: SearchVM
    @State private var history: [String] = SearchHistory.load()
    @State private var skipNextDebounce = false

    init() {
        _vm = StateObject(wrappedValue: SearchVM.makeDefault(
            isOnline: { !AppServices.shared.offlineJdb }))
    }

    // MARK: 派生状态

    private var queryTrim: String {
        vm.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 结果态：items != nil && query 非空（清空关键词回到首页三段）
    private var resultVisible: Bool {
        vm.items != nil && !queryTrim.isEmpty
    }

    private var emptyText: String {
        queryTrim.isEmpty ? SearchCopy.emptyTextIdle : SearchCopy.emptyResult(queryTrim)
    }

    /// 首次引导卡（C2.4：remoteUser 与 localUser 均空白 && items==null）
    private var welcomeVisible: Bool {
        vm.items == nil
            && store.settings.remoteUser.isEmpty
            && store.settings.localUser.isEmpty
    }

    /// 搜索历史（C7：仅首页态 query 空 && home != nil && history 非空）
    private var historyVisible: Bool {
        queryTrim.isEmpty && vm.home != nil && !history.isEmpty
    }

    // MARK: body

    var body: some View {
        Group {
            if vm.setup {
                setupGuide
            } else {
                list
            }
        }
        .background(theme.bg0.ignoresSafeArea())
        .onAppear { vm.bind(to: store, persistMode: persistMode) }
        .onChange(of: vm.query) { _ in
            if skipNextDebounce {
                skipNextDebounce = false
                return
            }
            vm.queryEdited()
        }
        .onChange(of: vm.toast) { consumeToast($0) }
        // 刷新结果通道（publisher 直订，与 BrowseView 同模式；nil 初值被 guard 吞掉）
        .onReceive(vm.refreshResult.$value) { consumeRefresh($0) }
        .onReceive(store.$dataEpoch) { vm.onDataEpoch($0) }
    }

    // MARK: 列表壳（四态 + 下拉刷新 + footer + 右下角工具）

    private var list: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { vm.refreshFromPull() },
            firstLoading: vm.loading,
            empty: vm.home == nil && vm.items == nil,
            error: vm.error,
            onRetry: { vm.refreshFromPull() },
            emptyText: emptyText,
            emptyHint: queryTrim.isEmpty ? "" : SearchCopy.emptyResultHint,
            skeletonColumns: 2,
            loadMore: loadMoreConfig,
            showNavTools: resultVisible && !(vm.items ?? []).isEmpty,
            pageLoaded: vm.items?.count ?? 0,
            pageTotal: vm.total,
            pagePer: vm.per,
            goPage: { p in Task { await vm.goPage(p) } }
        ) {
            LazyVStack(spacing: 0) {
                topBlocks
                if let note = vm.offlineNote {
                    AppText(note, lvl: .meta, color: theme.accent2, textAlign: .center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                if resultVisible {
                    resultSection
                } else if vm.home != nil {
                    homeSections
                }
            }
        }
    }

    // MARK: 顶部块（随列表滚动，C2）

    private var topBlocks: some View {
        VStack(alignment: .leading, spacing: 0) {
            SearchBarCompact(text: $vm.query, onSearch: { doSearch(vm.query) })
            ScopeChipsRow(current: vm.scope) { vm.setScope($0) }
                .padding(.top, 6)
            MatchViewRow(
                mode: vm.mode,
                viewMode: vm.viewMode,
                onMode: { vm.setMode($0) },
                onView: { m in
                    vm.viewMode = m
                    store.updateSettings { $0.viewMode = m }
                }
            )
            .padding(.top, 6)
            if welcomeVisible {
                welcomeCard
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if vm.items == nil {
                HomeEntriesRow(onArticles: { router.push(.articles) },
                               onHotReviews: { router.push(.hotreviews) })
                    .padding(.top, 4)
            }
            if historyVisible {
                historyBlock
            }
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppText(SearchCopy.welcomeTitle, lvl: .bodyS, fontWeight: .bold)
            AppText(SearchCopy.welcomeHint, lvl: .meta)
                .padding(.top, 4)
            Button {
                router.tab = "settings"
            } label: {
                AppText(SearchCopy.welcomeAction, lvl: .bodyS, color: .white, fontWeight: .medium)
                    .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.15)))
    }

    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 6)
            AppText(SearchCopy.historyTitle, lvl: .meta, fontWeight: .bold)
                .padding(.horizontal, 12)
            HistoryChipsRow(items: history) { doSearch($0) }
                .padding(.top, 4)
            Spacer().frame(height: 16)
        }
    }

    // MARK: 首页三段（C4：段头 + 横滑卡片流；大图模式平铺 grid）

    private var homeSections: some View {
        VStack(spacing: 0) {
            homeSection(key: "recent", title: SearchCopy.sectionRecent,
                        rows: vm.home?.recent ?? []) {
                pushLookup(label: "最近更新", sort: "release_date")
            }
            homeSection(key: "hot", title: SearchCopy.sectionHot,
                        rows: vm.home?.hot ?? []) {
                pushLookup(label: "最多想看", sort: "want_watch_count")
            }
            homeSection(key: "top", title: SearchCopy.sectionTop,
                        rows: vm.home?.top ?? []) {
                router.push(.top250)
            }
            Spacer().frame(height: 8)   // home_tail
        }
    }

    @ViewBuilder
    private func homeSection(key: String, title: String, rows: [Row],
                             onViewAll: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AppText(title, lvl: .titleM)
                Spacer(minLength: 8)
                Button(action: onViewAll) {
                    AppText(SearchCopy.viewAll, lvl: .meta, color: theme.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("viewall_\(key)")
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
            .padding(.horizontal, 12)

            if rows.isEmpty {
                AppText(SearchCopy.emptyHomeSection, lvl: .meta)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if vm.viewMode == 1 {
                sectionGrid(rows: rows, keyPrefix: key, onViewAll: onViewAll)
            } else {
                sectionHScroll(rows: rows, keyPrefix: key, onViewAll: onViewAll)
            }
        }
    }

    /// 小图/列表模式：一行横滑，卡片固定宽 180 + 行尾 ViewAllCard（C4）
    private func sectionHScroll(rows: [Row], keyPrefix: String,
                                onViewAll: @escaping () -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(rows.indices, id: \.self) { i in
                    let m = rows[i]
                    MovieCard(m: m, viewMode: 0,
                              read: vm.readIds.contains(m.s("id")),
                              fav: vm.favIds.contains(m.s("id")),
                              onClick: { router.push(.movie(m.s("id"))) })
                        .frame(width: 180)
                        .id("r_\(keyPrefix)_\(m.s("id"))")
                        .accessibilityIdentifier(cardIdentifier(key: keyPrefix, index: i))
                }
                ViewAllCard(onClick: onViewAll)
                    .accessibilityIdentifier("viewall_card_\(keyPrefix)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    /// 大图模式（viewMode==1）：每段影片直接平铺进 grid（C4）
    private func sectionGrid(rows: [Row], keyPrefix: String,
                             onViewAll: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(rows.indices, id: \.self) { i in
                    let m = rows[i]
                    MovieCard(m: m, viewMode: 1,
                              read: vm.readIds.contains(m.s("id")),
                              fav: vm.favIds.contains(m.s("id")),
                              onClick: { router.push(.movie(m.s("id"))) })
                        .id("r_\(keyPrefix)_\(m.s("id"))")
                        .accessibilityIdentifier(cardIdentifier(key: keyPrefix, index: i))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    /// Lazy item key 带段前缀（C4：三段间影片可能重复，裸 id 撞 key）——
    /// SwiftUI 侧以 accessibilityIdentifier 承载同一约定（UI 测试用）
    private func cardIdentifier(key: String, index: Int) -> String {
        index == 0 && key == "recent" ? "home_push_movie" : "home_\(key)_\(index)"
    }

    // MARK: 结果态（C5/C6）

    @ViewBuilder
    private var resultSection: some View {
        let items = vm.items ?? []
        if items.isEmpty {
            // 结果空：Box(height 360) EmptyBox（弯引号原样 + 半角逗号 hint）
            EmptyBox(text: SearchCopy.emptyResult(queryTrim), hint: SearchCopy.emptyResultHint)
                .frame(height: 360)
                .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(items.indices, id: \.self) { i in
                    let m = items[i]
                    MovieCard(m: m, viewMode: vm.viewMode,
                              read: vm.readIds.contains(m.s("id")),
                              fav: vm.favIds.contains(m.s("id")),
                              onClick: { router.push(.movie(m.s("id"))) })
                        .id("s_\(m.s("id"))_\(i)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            exactScopeNote
            localSourceNote
        }
    }

    /// footer 1：精确模式范围标注（mode==exact && derived 空）
    @ViewBuilder
    private var exactScopeNote: some View {
        if vm.mode == "exact" && (vm.derived ?? "").isEmpty {
            AppText(SearchCopy.exactScopeNote, lvl: .meta, color: theme.accent2,
                    textAlign: .center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
    }

    /// footer 2：本地索引来源标注（served=="local" 结构化判定）→ 点击整行改用远程全库
    @ViewBuilder
    private var localSourceNote: some View {
        if vm.served == "local" {
            Button {
                vm.forceRemoteRetry()
            } label: {
                AppText(vm.localNoteText, lvl: .meta, color: theme.accent, textAlign: .center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("local_source_note")
        }
    }

    // MARK: 网格列数（C5：viewMode 1/2 → 1 列；小图 2 列 / 屏宽 regular 3 列）

    private var gridColumns: [GridItem] {
        let count: Int
        if vm.viewMode == 1 || vm.viewMode == 2 {
            count = 1
        } else {
            count = hSize == .regular ? 3 : 2
        }
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    // MARK: LoadMoreFooter 配置（结果态且非空才挂）

    private var loadMoreConfig: LoadMoreConfig? {
        guard resultVisible, let items = vm.items, !items.isEmpty else { return nil }
        return LoadMoreConfig(
            loaded: items.count,
            total: vm.total,
            loadingMore: vm.loadingMore,
            approx: false,
            note: vm.derived ?? "",
            hasMore: vm.hasMore,
            onLoadNext: { Task { await vm.loadNext() } })
    }

    // MARK: 首启引导态（C1 逐字）

    private var setupGuide: some View {
        VStack(spacing: 0) {
            Text(SearchCopy.setupTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(theme.text)
            Spacer().frame(height: 10)
            Text(SearchCopy.setupHint)
                .font(.system(size: 13))
                .foregroundColor(theme.text2)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 18)
            Button {
                router.tab = "settings"
            } label: {
                Text(SearchCopy.setupAction)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 动作

    /// doSearch（C3）：trim、空忽略；写历史后立即搜（值有变才跳过下一次防抖，
    /// 防重复提交时残留 skip 标记吞掉下一次真实输入的防抖）
    private func doSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if vm.query != q {
            skipNextDebounce = true
            vm.query = q
        }
        vm.resetDebounce()
        SearchHistory.add(q)
        history = SearchHistory.load()
        Task { await vm.search() }
    }

    /// 段头「查看全部」反查压栈（A4：LookupSpec → encode → lookup 路由压栈）
    private func pushLookup(label: String, sort: String) {
        let spec = LookupSpec(filters: Filters(), label: label, sort: sort)
        router.push(.lookup(LookupCodec.encode(spec)))
    }

    private func persistMode(_ m: String) {
        store.updateSettings { $0.searchMode = (m == "exact") ? 0 : 1 }
    }

    private func consumeToast(_ t: String?) {
        guard let t else { return }
        services.showToast(t)
        vm.consumeToast()
    }

    private func consumeRefresh(_ r: RefreshResult?) {
        guard let r else { return }
        services.showToast(r.toastText)
        vm.refreshResult.consume()
    }
}
