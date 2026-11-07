import SwiftUI
import JDLVCore

//
//  ActorDetailView.swift —— 女优详情页（09 B 节 ActorDetailScreen 对位
//  + 13 §4.5 设计系统 v2）。
//
//  - 状态四态（B2）：loading && actor==null → LoadingBox；error && actor==null → ErrorBox；
//    actor==null → EmptyBox「未找到该女优」；否则内容。
//  - 头部信息区（B3）：头像 96×96（AspectImage 1:1 不拉伸）+ 右侧列（姓名 Bold 17 /
//    name_zht 次级灰 / InfoRow 7 标签：别名/影片数/生日/身高/人气/均分/推特）。
//  - 作品区（B4/B5，13 §4.5）：「出演影片 (共 N 部)」+ CardGrid 2 列 MovieCard 小图
//    （等宽等高）+ LoadMoreFooter + PageChip overlay。
//  - 排序 × 方向 × 标签筛选（B5）：sort/id 提示逐字；标签面板 FilterDropdown → .sheet
//    （TAG_LIMIT=60 + 「加载更多标签（已显示 N）」全角括号 + 「完成」）。
//

struct ActorDetailView: View {
    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.containerWidth) private var envWidth
    let aid: String

    @StateObject private var vm: ActorDetailVM
    @State private var showTagPanel = false

    init(aid: String) {
        self.aid = aid
        _vm = StateObject(wrappedValue: ActorDetailVM.makeDefault())
    }

    // MARK: 派生

    private var name: String { vm.actor?.s("name") ?? "" }
    private var pageWidth: CGFloat { resolvedContainerWidth(envWidth, hSize: hSize) }

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
        .navigationTitle(name.isEmpty ? ActorDetailCopy.navTitleFallback : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                FavButton(fav: vm.fav) { Task { await vm.toggleFav() } }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            PageChip(loaded: vm.items.count, total: vm.total, per: ActorDetailVM.per,
                     goPage: { p in Task { await vm.goPage(p) } })
                .padding(.trailing, 12)
                .padding(.bottom, 16)
        }
        .sheet(isPresented: $showTagPanel) {
            NavigationStack { tagSheet }
                .presentationDetents([.large])
        }
        .onAppear { Task { await vm.bind(aid: aid) } }
        .onDisappear { vm.release() }
        .accessibilityIdentifier("secondary_page")
    }

    // MARK: 正文（单 ScrollView + 单 LazyVStack）

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                headerBlock          // B3 头部信息区
                moviesBlock          // B4 出演影片
                Color.clear.frame(height: 30)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    // MARK: B3 头部信息区（头像 96×96 AspectImage + 右侧列）

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            AspectImage(url: MovieImg.actorAvatar(vm.actor?.s("avatar_url") ?? ""),
                        ratio: 1, radius: 10)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 2) {
                AppText(name.isEmpty ? " " : name, lvl: .titleM, maxLines: 2, fontWeight: .bold)
                let zht = vm.actor?.s("name_zht") ?? ""
                if !zht.isEmpty {
                    AppText(zht, lvl: .meta)   // 次级灰（Meta 默认 onSurfaceVariant）
                }
                infoRows
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// InfoRow 7 标签（"$k: $v"；v 为空整行不显示，B3 逐字）
    @ViewBuilder
    private var infoRows: some View {
        let a = vm.actor
        VStack(alignment: .leading, spacing: 2) {
            if let alias = a?.s("other_name"), !alias.isEmpty {
                infoLine(ActorDetailCopy.infoAlias, alias)
            }
            let total = vm.total
            if total > 0 {
                infoLine(ActorDetailCopy.infoVideos, String(total))
            }
            if let birthday = a?.s("birthday"), !birthday.isEmpty {
                infoLine(ActorDetailCopy.infoBirthday, birthday)
            }
            if let height = a?.s("height"), !height.isEmpty {
                infoLine(ActorDetailCopy.infoHeight, height)
            }
            let pop = a?.i("popularity") ?? 0
            if pop > 0 {
                infoLine(ActorDetailCopy.infoPopularity, String(pop))
            }
            let avg = a?.d("avg_score_all") ?? 0
            if avg > 0 {
                infoLine(ActorDetailCopy.infoAvgScore, String(format: "%.2f", avg))
            }
            if let twitter = a?.s("twitter"), !twitter.isEmpty {
                infoLine(ActorDetailCopy.infoTwitter, twitter)
            }
        }
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        AppText("\(label): \(value)", lvl: .meta, maxLines: 1)
    }

    // MARK: B4/B5 出演影片区（排序/方向/标签 + CardGrid 2 列 MovieCard 小图）

    private var moviesBlock: some View {
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
                let cellW = GridMath.cellWidth(pageWidth: pageWidth - 24, columns: 2)
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }

    /// 排序/方向/标签入口行（B5：DropdownBox 保留——既有 36pt 控件、B21 口径）
    private var toolbarRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                DropdownBox(
                    label: ActorDetailCopy.sortLabel,
                    options: ActorDetailCopy.sortOptions.map {
                        DropdownOption(label: $0.label, value: $0.value)
                    },
                    current: vm.sort,
                    onSelect: { v in Task { await vm.setSort(v) } })
                DropdownBox(
                    label: ActorDetailCopy.ascLabel,
                    options: ActorDetailCopy.ascOptions.map {
                        DropdownOption(label: $0.label, value: $0.value)
                    },
                    current: vm.asc ? "asc" : "desc",
                    onSelect: { v in Task { await vm.setAsc(v == "asc") } })
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

    // MARK: 标签筛选 sheet（B5：chips + 加载更多 + 完成）

    private var tagSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                AppText(ActorDetailCopy.tagsPanelTitle, lvl: .bodyS, fontWeight: .bold)
                // chips：全部（tagId 空）+ 每标签 "{name} ({count})"；点选即查询，再点取消
                FlowHStack(spacing: 8) {
                    AppToggleChip(label: ActorDetailCopy.tagsAll, selected: vm.tagId.isEmpty) {
                        Task { await vm.setTag("") }
                    }
                    ForEach(Array(vm.tags.enumerated()), id: \.offset) { _, t in
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
                // 底部确认按钮「完成」（≥48）
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
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.bg1.ignoresSafeArea())
    }
}
