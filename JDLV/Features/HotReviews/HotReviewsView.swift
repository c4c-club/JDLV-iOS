import SwiftUI
import UIKit
import JDLVCore

//
//  HotReviewsView.swift —— 热评榜页（10 §4 HotReviewsScreen 逐字移植）。
//
//  结构：ListScaffold（骨架 1 列）→ 顶部时间段 chips（横向滚动，6 档逐字
//  全部/上周/月度/季度/年度/最新）→ 批次 chips（keys>1 才显示；行首「批次」标签）→
//  LazyVStack 行卡（#N 徽标 + 影片区可点 push movie + 右列 评分/赞/用户 + 3 行正文）+
//  LoadMoreFooter；右下角 ListNavTools。
//  空态两段式（P7.2）：hasData=false →「远程库暂无热评数据（需抓取端跑热评任务后上传）」；
//  有数据但当前筛选无结果 →「暂无热评」。
//  点行 → 详情弹层（全文 + 复制全文 → UIPasteboard + Toast「已复制评论全文」+
//  跳转影片详情）。
//

struct HotReviewsView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @StateObject private var vm: HotReviewsVM
    /// 弹层当前行（Row 非 Identifiable → offset 包装）
    @State private var sheetItem: SheetItem? = nil

    struct SheetItem: Identifiable {
        let id: Int
        let row: Row
    }

    init() {
        _vm = StateObject(wrappedValue: HotReviewsVM.makeDefault())
    }

    private var items: [Row] { vm.items ?? [] }

    /// 空态文案（两段式：keys 空 = 无数据；否则 = 当前筛选无结果）
    private var emptyText: String {
        vm.hasData ? HotReviewsCopy.emptyFiltered : HotReviewsCopy.emptyNoData
    }

    var body: some View {
        ListScaffold(
            refreshing: vm.refreshing,
            onRefresh: { Task { await vm.refresh() } },
            firstLoading: vm.loading,
            empty: items.isEmpty,
            error: vm.error,
            onRetry: { Task { await vm.reload() } },
            emptyText: emptyText,
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
            periodChips
            batchChips
            list
        }
        .navigationTitle("热评")
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
        // 详情弹层（ModalBottomSheet 对位）
        .sheet(item: $sheetItem) { item in
            HotReviewSheet(row: item.row) { mid in
                sheetItem = nil
                router.push(.movie(mid))
            } onCopy: { text in
                UIPasteboard.general.string = text
                services.showToast(HotReviewsCopy.copiedToast)
            }
            .presentationDetents([.medium, .large])
        }
        .accessibilityIdentifier("hotreviews_page")
    }

    // MARK: 时间段 chips（逐字 6 档，顺序固定；默认 all）

    private var periodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(HotReviewsCopy.periods, id: \.value) { p in
                    AppToggleChip(label: p.label, selected: vm.period == p.value) {
                        Task { await vm.setPeriod(p.value) }
                    }
                    .accessibilityIdentifier("hot_period_\(p.value)")
                }
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 6)
    }

    // MARK: 批次 chips（keys>1 才显示；行首「批次」标签；横滚不可裁剪）

    @ViewBuilder
    private var batchChips: some View {
        if vm.keys.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    AppText(HotReviewsCopy.batchLabel, lvl: .meta)
                        .padding(.leading, 8)
                    ForEach(vm.keys, id: \.self) { k in
                        AppToggleChip(label: k, selected: vm.key == k) {
                            Task { await vm.setKey(k) }
                        }
                        .accessibilityIdentifier("hot_key_\(k)")
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 行卡列表

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, r in
                HotReviewRow(row: r) {
                    router.push(.movie(r.s("movie_id")))
                } onOpen: {
                    sheetItem = SheetItem(id: i, row: r)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HotReviewRow（10 §4.5：#N 徽标 + 影片区可点 + 右列三行 + 3 行正文）

struct HotReviewRow: View {
    let row: Row
    /// 影片区点击（→ push movie；movie_id 空不跳）
    var onMovie: () -> Void
    /// 整卡点击（→ 详情弹层）
    var onOpen: () -> Void

    @Environment(\.appTheme) private var theme

    private var rank: String { row.s("rank") }
    private var movieTitle: String {
        let t = row.s("movie_title")
        return t.isEmpty ? row.s("number") : t
    }
    /// 影片封面 56×78（Img.movieCover(movie_thumb_url, movie_id)；thumb 无效不回退裸 id）
    private var coverUrl: String {
        let t = row.s("movie_thumb_url").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : MovieImg.movieCover(t, row.s("movie_id"))
    }
    /// 评分（非空才显示）
    private var scoreText: String? {
        let s = row.s("score").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : "\(s)★"
    }
    private var likesText: String? { HotReviewsCopy.likesText(row.s("likes_count")) }
    /// 正文前 3 行省略
    private var content3Lines: String {
        row.s("content")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(3)
            .joined(separator: "\n")
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    // 排名徽标：#N（primary 14% 底、圆角 8、padding h8 v4）
                    AppText("#\(rank)", lvl: .bodyS, color: theme.accent, fontWeight: .bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accent.opacity(0.14)))
                    // 影片区（可点 → 跳影片详情）
                    Button(action: onMovie) {
                        HStack(alignment: .top, spacing: 8) {
                            PosterImage(url: coverUrl)
                                .frame(width: 56, height: 78)
                            VStack(alignment: .leading, spacing: 4) {
                                AppText(movieTitle.isEmpty ? " " : movieTitle, lvl: .bodyS,
                                        maxLines: 2, textAlign: .leading)
                                let sub = HotReviewsCopy.rowSub(
                                    number: row.s("number"),
                                    movieScore: HotReviewFmt.score(row.d("movie_score")))
                                if !sub.isEmpty {
                                    AppText(sub, lvl: .meta, maxLines: 1)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(row.s("movie_id").isEmpty)
                    Spacer(minLength: 8)
                    // 右列（右对齐）：评分 / 点赞 / 用户名
                    VStack(alignment: .trailing, spacing: 4) {
                        if let s = scoreText {
                            AppText(s, lvl: .bodyS, color: theme.accent)
                        }
                        if let l = likesText {
                            AppText(l, lvl: .meta)
                        }
                        AppText(row.s("user_name"), lvl: .meta, maxLines: 1)
                    }
                }
                if !row.s("content").isEmpty {
                    AppText(content3Lines, lvl: .bodyS, maxLines: 3, textAlign: .leading)
                        .padding(.top, 6)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .cardChrome()
        .accessibilityIdentifier("hot_review_row")
    }
}

// MARK: - HotReviewSheet（10 §4.6 详情弹层）

struct HotReviewSheet: View {
    let row: Row
    /// 跳转影片详情（movie_id 非空才显示按钮；点击关弹层 → push）
    var onMovie: (String) -> Void
    /// 复制全文（UIPasteboard + Toast 由调用方接）
    var onCopy: (String) -> Void

    @Environment(\.appTheme) private var theme

    private var coverUrl: String {
        let t = row.s("movie_thumb_url").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "" : MovieImg.movieCover(t, row.s("movie_id"))
    }
    private var content: String { row.s("content") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                PosterImage(url: coverUrl)
                    .frame(width: 84, height: 116)
                VStack(alignment: .leading, spacing: 4) {
                    AppText(HotReviewsCopy.sheetTitle(
                        rank: row.s("rank"), title: row.s("movie_title"),
                        number: row.s("number")), lvl: .titleM, maxLines: 3)
                    let meta = HotReviewsCopy.sheetMeta(
                        number: row.s("number"),
                        movieScore: HotReviewFmt.score(row.d("movie_score")))
                    if !meta.isEmpty {
                        AppText(meta, lvl: .meta, maxLines: 1)
                    }
                    AppText(HotReviewsCopy.sheetCommentLine(
                        score: row.s("score"), userName: row.s("user_name")),
                        lvl: .meta, maxLines: 1)
                    AppText(HotReviewsCopy.sheetLikesLine(
                        likes: row.s("likes_count"), createdAt: row.s("created_at")),
                        lvl: .meta, maxLines: 1)
                }
                Spacer(minLength: 0)
            }
            Rectangle()
                .fill(theme.line)
                .frame(height: 1)
                .padding(.top, 12)
            // 完整正文（长按选择复制）；空 → (无正文)
            ScrollView {
                Group {
                    if content.isEmpty {
                        Text(HotReviewsCopy.sheetNoBody)
                            .font(.system(size: Tx.bodyS.size))
                            .foregroundColor(theme.text)
                    } else {
                        Text(content)
                            .font(.system(size: Tx.bodyS.size))
                            .foregroundColor(theme.text)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            // 按钮排（等宽两个）
            HStack(spacing: 12) {
                Button {
                    onCopy(content)
                } label: {
                    AppText(HotReviewsCopy.copyAllButton, lvl: .bodyS,
                            color: theme.accent, fontWeight: .medium)
                        .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(theme.accent.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !row.s("movie_id").isEmpty {
                    Button {
                        onMovie(row.s("movie_id"))
                    } label: {
                        AppText(HotReviewsCopy.jumpMovieButton, lvl: .bodyS,
                                color: .white, fontWeight: .medium)
                            .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg1.ignoresSafeArea())
        .accessibilityIdentifier("hot_review_sheet")
    }
}

// MARK: - HotReviewFmt（评分拼接：Kotlin Double.toString 对位 4.3 / 4.0）

enum HotReviewFmt {
    /// movie_score（MySQL REAL → Double）→ Kotlin "${score}" 形态（4.0 保留一位小数）
    static func score(_ v: Double) -> String {
        guard v > 0 else { return "" }
        if v == v.rounded() && abs(v) < 1_000_000 {
            return String(format: "%.1f", v)
        }
        return String(v)
    }
}
