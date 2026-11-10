import SwiftUI
import JDLVCore

//
//  ActorDetailView.swift —— 女优详情页（09 B 节 ActorDetailScreen 对位
//  + 13 §4.5 设计系统 v2 + R4 P6 版式重构）。
//
//  - 状态四态（B2）：loading && actor==null → LoadingBox；error && actor==null → ErrorBox；
//    actor==null → EmptyBox「未找到该女优」；否则内容。
//  - R4 P6 版式（规划 §8 验收图）：
//    profileCard（头像 88×88 + 姓名 2 行 + name_zht + 4 个 InfoChip + Divider +
//    InfoCell 网格（别名整行/人气/推特；长别名 DisclosureGroup「更多资料」展开可复制））；
//    moviesSection（标题 + Menu 合并排序/方向 + 标签按钮 + CardGrid 2 列 + LoadMoreFooter）；
//    底部 overlay = PageChip + ScrollTopFAB 竖排（不压内容：尾部 96pt 余量）。
//  - 标签 sheet：搜索框 + 已选计数 + LazyVGrid(adaptive 96) + 底部固定「完成」+ tagsHasMore。
//

struct ActorDetailView: View {
    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.containerWidth) private var envWidth
    // R4 P3：二级页环境里没有 PageScaffold 注入 → 自测宽（background GeometryReader 发 preference）
    @State private var measuredWidth: CGFloat = 0
    let aid: String

    @StateObject private var vm: ActorDetailVM
    @State private var showTagPanel = false
    // R4 P5/P6：回顶阈值 + 长别名展开 + 标签搜索词
    @State private var showScrollTop = false
    @State private var aliasExpanded = false
    @State private var tagQuery = ""

    init(aid: String) {
        self.aid = aid
        _vm = StateObject(wrappedValue: ActorDetailVM.makeDefault())
    }

    // MARK: 派生

    private var name: String { vm.actor?.s("name") ?? "" }
    private var pageWidth: CGFloat {
        measuredWidth > 0 ? measuredWidth : resolvedContainerWidth(envWidth, hSize: hSize)
    }

    var body: some View {
        Group {
            if vm.loading && vm.actor == nil {
                LoadingBox()
            } else if vm.error != nil && vm.actor == nil {
                ErrorBox(text: vm.error ?? "", onRetry: { Task { await vm.load(1) } })
            } else if vm.actor == nil {
                EmptyBox(text: ActorDetailCopy.emptyNotFound)
            } else {
                content
            }
        }
        .background(theme.bg0.ignoresSafeArea())
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: PageContainerWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(PageContainerWidthKey.self) { measuredWidth = $0 }
        .navigationTitle(name.isEmpty ? ActorDetailCopy.navTitleFallback : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                FavButton(fav: vm.fav) { Task { await vm.toggleFav() } }
            }
        }
        .sheet(isPresented: $showTagPanel) {
            NavigationStack { tagSheet }
                .presentationDetents([.large])
        }
        .onAppear { Task { await vm.bind(aid: aid) } }
        .onDisappear { vm.release() }
        .accessibilityIdentifier("secondary_page")
    }

    // MARK: 正文（R4 P6：ScrollViewReader + profileCard + moviesSection + 底部余量 96）

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ScrollOffsetReader(space: "actor_detail_space")
                    .id("actor_top")
                LazyVStack(alignment: .leading, spacing: 0) {
                    profileCard
                    moviesSection
                    // 尾部余量：PageChip/FAB 不压最后一行（≥8pt 间距要求）
                    Color.clear.frame(height: 96)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .coordinateSpace(name: "actor_detail_space")
            .scrollTopOffsetWatcher(show: $showScrollTop)
            .overlay(alignment: .bottomTrailing) {
                // R4 P6：PageChip + 回顶 FAB 竖排（detail 无 TabBar → bottom 16）
                VStack(alignment: .trailing, spacing: 10) {
                    PageChip(loaded: vm.items.count, total: vm.total, per: ActorDetailVM.per,
                             goPage: { p in Task { await vm.goPage(p) } })
                    ScrollTopFAB(visible: showScrollTop) {
                        withAnimation { proxy.scrollTo("actor_top", anchor: .top) }
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: 资料卡（R4 P6 版式：88 头像 + chips + Divider + InfoCell 网格）

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AspectImage(url: MovieImg.actorAvatar(vm.actor?.s("avatar_url") ?? ""),
                            ratio: 1, radius: 10)
                    .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 6) {
                    AppText(name.isEmpty ? " " : name, lvl: .titleM, maxLines: 2, fontWeight: .bold)
                        .fixedSize(horizontal: false, vertical: true)
                    let zht = vm.actor?.s("name_zht") ?? ""
                    if !zht.isEmpty {
                        AppText(zht, lvl: .meta)   // 次级灰（Meta 默认 onSurfaceVariant）
                    }
                    infoChips
                }
            }
            Divider()
            infoCells
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.bg1))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 4 个紧凑 InfoChip（影片数/生日/身高/均分；FlowHStack 超宽自动换行）
    @ViewBuilder
    private var infoChips: some View {
        let a = vm.actor
        FlowHStack(spacing: 6) {
            if vm.total > 0 {
                InfoChip(text: "\(ActorDetailCopy.infoVideos) \(vm.total)")
            }
            if let b = a?.s("birthday"), !b.isEmpty {
                InfoChip(text: b)
            }
            if let h = a?.s("height"), !h.isEmpty {
                InfoChip(text: h)
            }
            let avg = a?.d("avg_score_all") ?? 0
            if avg > 0 {
                InfoChip(text: "\(ActorDetailCopy.infoAvgScore) \(String(format: "%.1f", avg))")
            }
        }
    }

    /// 资料格网格：别名整行（超长 → DisclosureGroup 展开）/人气/推特（§8 两列 6pt 间距）
    @ViewBuilder
    private var infoCells: some View {
        let a = vm.actor
        let alias = a?.s("other_name") ?? ""
        let pop = a?.i("popularity") ?? 0
        let twitter = a?.s("twitter") ?? ""
        if !alias.isEmpty || pop > 0 || !twitter.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6),
                                GridItem(.flexible(), spacing: 6)],
                      spacing: 6) {
                if !alias.isEmpty {
                    aliasCell(alias)
                }
                if pop > 0 {
                    InfoCell(label: ActorDetailCopy.infoPopularity, value: String(pop))
                }
                if !twitter.isEmpty {
                    InfoCell(label: ActorDetailCopy.infoTwitter, value: twitter)
                }
            }
        }
    }

    /// 别名：>24 字（≈2 行）→ DisclosureGroup「更多资料」展开 + textSelection 可复制；
    /// 短别名直接 2 行截断。整行 = gridCellColumns(2)。
    @ViewBuilder
    private func aliasCell(_ alias: String) -> some View {
        if alias.count > 24 {
            DisclosureGroup(aliasExpanded ? ActorDetailCopy.lessInfo : ActorDetailCopy.moreInfo,
                            isExpanded: $aliasExpanded) {
                Text(alias)
                    .font(.system(size: 12))
                    .foregroundColor(theme.text2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                InfoCell(label: ActorDetailCopy.infoAlias,
                         value: String(alias.prefix(24)) + "…", lines: 1)
            }
            .gridCellColumns(2)
        } else {
            InfoCell(label: ActorDetailCopy.infoAlias, value: alias, lines: 2)
                .gridCellColumns(2)
        }
    }

    // MARK: 出演影片区（R4 P6：Menu 合并排序/方向 + 标签按钮 + CardGrid 2 列）

    private var moviesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ActorDetailCopy.moviesTitle(vm.total))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(theme.text)
            // 离线标注（actor 行带 derived → 标题下方 12sp tertiary 原样显示）
            if !vm.derived.isEmpty {
                AppText(vm.derived, lvl: .meta, color: theme.accent2)
            }
            toolbarRow
            if vm.items.isEmpty && vm.error == nil {
                AppText(ActorDetailCopy.emptyMovies, lvl: .meta)
                    .padding(.top, 12)
            } else {
                // R4 P4：content 已有 12pt 水平 padding → 内宽 = pageWidth - 24，
                // GridMath margin 显式传 0，杜绝双重扣（320pt 不裁切）
                let innerW = pageWidth - 24
                let cellW = GridMath.cellWidth(pageWidth: innerW, columns: 2, margin: 0)
                CardGrid(items: vm.items, columns: 2,
                         cellWidth: cellW,
                         cellHeight: CardLayout.movieSmallH(cellW: cellW)) { mv in
                    MovieCard(m: mv, viewMode: 0, onClick: {
                        router.push(.movie(mv.s("id")))
                    })
                }
                LoadMoreFooter(config: LoadMoreConfig(
                    loaded: vm.items.count, total: vm.total,
                    loadingMore: vm.loading && vm.actor != nil,
                    approx: false, hasMore: vm.hasMore,
                    onLoadNext: { Task { await vm.loadNext() } }))
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }

    /// 工具行：单个 Menu（排序 × 方向二级 Section）+ 标签按钮 —— 不再并排 2 个 DropdownBox
    private var toolbarRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Menu {
                    Section(ActorDetailCopy.sortLabel) {
                        ForEach(ActorDetailCopy.sortOptions, id: \.value) { o in
                            Button {
                                Task { await vm.setSort(o.value) }
                            } label: {
                                if vm.sort == o.value {
                                    Label(o.label, systemImage: "checkmark")
                                } else {
                                    Text(o.label)
                                }
                            }
                        }
                    }
                    Section(ActorDetailCopy.ascLabel) {
                        ForEach(ActorDetailCopy.ascOptions, id: \.value) { o in
                            Button {
                                Task { await vm.setAsc(o.value == "asc") }
                            } label: {
                                if (vm.asc ? "asc" : "desc") == o.value {
                                    Label(o.label, systemImage: "checkmark")
                                } else {
                                    Text(o.label)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 14))
                        AppText(sortMenuTitle, lvl: .meta)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: ComponentMetrics.chipHeight)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke))
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("actor_sort_menu")
                if !vm.tags.isEmpty {
                    Button {
                        showTagPanel = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 14))
                            AppText(ActorDetailCopy.tagsEntry, lvl: .meta)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: ComponentMetrics.chipHeight)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accent.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.accent.opacity(0.35),
                                    lineWidth: ComponentMetrics.cardStroke))
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if !vm.tagId.isEmpty {
                                Circle()
                                    .fill(theme.accent)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 6, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("actor_tags_button")
                }
                Spacer(minLength: 0)
            }
            // sort=="id" 提示（tertiary，padding top 2）
            if vm.sort == "id" {
                AppText(ActorDetailCopy.idSortNote, lvl: .meta, color: theme.accent2)
            }
        }
        .padding(.vertical, 2)
    }

    /// Menu 标题 = 当前排序项 label（方向并入菜单二级 Section）
    private var sortMenuTitle: String {
        ActorDetailCopy.sortOptions.first { $0.value == vm.sort }?.label
            ?? ActorDetailCopy.sortLabel
    }

    // MARK: 标签筛选 sheet（R4 P6：搜索 + 已选计数 + adaptive 网格 + 底部固定完成）

    private var tagSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                AppText(ActorDetailCopy.tagsPanelTitle, lvl: .bodyS, fontWeight: .bold)
                // R4：已选计数（tagId 空 = 0）
                AppText(tagsSelectedLine, lvl: .meta, color: theme.accent2)
                    .accessibilityIdentifier("tag_selected_count")
                TextField("搜索标签", text: $tagQuery)
                    .font(.system(size: 14))
                    .foregroundColor(theme.text)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                    .accessibilityIdentifier("tag_search_field")
                // R4：自适应网格（60 标签滚动不卡；搜索过滤）
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    AppToggleChip(label: ActorDetailCopy.tagsAll, selected: vm.tagId.isEmpty) {
                        Task { await vm.setTag("") }
                    }
                    ForEach(filteredTags, id: \.offset) { _, t in
                        AppToggleChip(
                            label: "\(t.s("name")) (\(t.i("c")))",
                            selected: vm.tagId == t.s("id")) {
                            Task { await vm.setTag(t.s("id")) }
                        }
                    }
                }
                // 加载更多标签（仅 tagsHasMore；全角括号逐字）
                if vm.tagsHasMore {
                    Button {
                        Task { await vm.loadMoreTags() }
                    } label: {
                        AppText(vm.tagsLoading
                                ? ActorDetailCopy.tagsLoadingMore
                                : ActorDetailCopy.tagsLoadMore(vm.tags.count),
                                lvl: .meta, color: theme.accent)
                            .frame(minHeight: ComponentMetrics.touchMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.tagsLoading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.bg1.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            // R4：完成按钮固定底部（不再随内容滚动）
            Button {
                showTagPanel = false
            } label: {
                AppText(ActorDetailCopy.done, lvl: .bodyS, color: .white,
                        textAlign: .center, fontWeight: .medium)
                    .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                    .background(RoundedRectangle(cornerRadius: Radius.card).fill(theme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .background(theme.bg1.ignoresSafeArea(edges: .bottom))
        }
    }

    /// 搜索过滤后的标签（空词 = 全量）
    private var filteredTags: [(offset: Int, element: Row)] {
        let q = tagQuery.trimmingCharacters(in: .whitespaces)
        let all = Array(vm.tags.enumerated())
        guard !q.isEmpty else { return all }
        return all.filter { $0.element.s("name").localizedCaseInsensitiveContains(q) }
    }

    /// 已选计数行（含已选标签名）
    private var tagsSelectedLine: String {
        if vm.tagId.isEmpty { return "已选 0 个" }
        let name = vm.tags.first { $0.s("id") == vm.tagId }?.s("name") ?? vm.tagId
        return "已选 1 个 · \(name)"
    }
}

// MARK: - R4 P6 资料子组件（InfoChip / InfoCell）

/// 紧凑信息 chip（头部 4 枚：影片数/生日/身高/均分）
private struct InfoChip: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        AppText(text, lvl: .meta)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.bg3.opacity(0.5)))
    }
}

/// 资料格（label 上 value 下；value lineLimit + minimumScaleFactor(0.8) 防截断溢出）
private struct InfoCell: View {
    let label: String
    let value: String
    var lines: Int = 1
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AppText(label, lvl: .meta, color: theme.text2)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(theme.text)
                .lineLimit(lines)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.35)))
    }
}
