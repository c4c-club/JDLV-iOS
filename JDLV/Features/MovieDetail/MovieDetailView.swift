import SwiftUI
import UIKit
import JDLVCore

//
//  MovieDetailView.swift —— 影片详情页（08 B 节 MovieDetailScreen 逐区块移植）。
//
//  区块顺序（B.1）：顶栏（番号/「影片详情」+ 收藏 ★）→ 状态四态（loading/error/空/正文）
//  → ① 标题区 → ② 横版封面（800:538，点击开灯箱）→ ③ 信息行 + summary + 反查行 +
//  已读按钮 → ④ 演员（♀粉 ♂蓝 小卡横滑）→ ⑤ 剧照（横滑）→ ⑥ 磁力卡 → ⑦ 相关资讯
//  → 尾部 24dp。
//
//  - 灯箱（B.3）：gallery = [封面] + 剧照 同组连续翻页；封面 → index 0；
//    剧照第 i 张 → galleryIndexOfPreview(i)；空 urls 居中「无图」。
//  - 反查行（B.4 JumpLines）：值缺失「—」不可点；有值 primary 下划线、行高 ≥48 整行可点，
//    点击 → push .lookup(payload)（每次压一层、返回逐层回详情）。
//  - 磁力卡（B.7）：整卡点击 → UIPasteboard 复制完整磁力链接 + Toast「已复制磁力链接」。
//  - 已读按钮：点击复制番号 → 已读 Toast「已复制」/ 未读 Toast「已标记已读」并 markRead。
//

struct MovieDetailView: View {
    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme
    let mid: String

    @StateObject private var vm: MovieDetailVM
    @State private var lightboxOpen = false
    @State private var lightboxIndex = 0

    init(mid: String) {
        self.mid = mid
        _vm = StateObject(wrappedValue: MovieDetailVM.makeDefault())
    }

    // MARK: 派生

    private var m: Row? { vm.movie }
    private var number: String { m?.s("number") ?? "" }
    private var score: Double { m?.d("score") ?? 0 }

    /// 磁力区头部文案（B.7：空态按 derived 是否含「离线」分流）
    private var magnetsHeaderText: String {
        if !vm.magnets.isEmpty { return MovieDetailCopy.magnetsTitle(vm.magnets.count) }
        return vm.derived.contains("离线")
            ? MovieDetailCopy.magnetsEmptyOffline
            : MovieDetailCopy.magnetsEmptyRemote
    }

    var body: some View {
        Group {
            if vm.loading {
                LoadingBox()
            } else if let e = vm.error {
                ErrorBox(text: e, onRetry: { Task { await vm.load() } })
            } else if m == nil {
                EmptyBox(text: MovieDetailCopy.emptyNotCollected)
            } else {
                content
            }
        }
        .background(theme.bg0.ignoresSafeArea())
        .navigationTitle(number.isEmpty ? MovieDetailCopy.navTitleFallback : number)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                FavButton(fav: vm.fav) { Task { await vm.toggleFav() } }
            }
        }
        .onAppear { Task { await vm.bind(mid: mid) } }
        .onDisappear { vm.release() }   // B.10 release：返回销毁重置；再进 bind 自动重载
        .fullScreenCover(isPresented: $lightboxOpen) {
            Lightbox(urls: vm.gallery, initialIndex: lightboxIndex) { lightboxOpen = false }
        }
        .accessibilityIdentifier("secondary_page")
    }

    // MARK: 正文（LazyColumn 16dp 内边距，区块顺序逐字）

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                titleBlock          // ① 标题区
                coverBlock          // ② 横版封面
                infoBlock           // ③ 信息行 + summary + 反查行 + 已读按钮
                actorsBlock         // ④ 演员
                previewsBlock       // ⑤ 剧照
                magnetsBlock        // ⑥ 磁力卡
                articlesBlock       // ⑦ 相关资讯
                Color.clear.frame(height: 24)   // 尾部 24dp
            }
            .padding(16)
        }
    }

    // MARK: ① 标题区（B.2：TitleM 3 行 + 番号/评分次行）

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            let t = m?.s("title") ?? ""
            AppText(t.isEmpty ? " " : t, lvl: .titleM, maxLines: 3)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AppText(number, lvl: .bodyS, color: theme.accent, fontWeight: .bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if score > 0 {
                    AppText("★ \(Fmt.score(score))", lvl: .bodyS, color: theme.accent2,
                            fontWeight: .bold)
                }
            }
        }
    }

    // MARK: ② 横版封面（B.3：800:538 整张不裁，点击开灯箱 index 0）

    private var coverBlock: some View {
        Group {
            if vm.coverTappable {
                Button {
                    lightboxIndex = 0
                    lightboxOpen = true
                } label: {
                    PosterImage(
                        url: MovieImg.movieCover(m?.s("cover_url") ?? "", mid),
                        aspect: 800.0 / 538.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)   // 无涟漪
            } else {
                PosterImage(url: "", aspect: 800.0 / 538.0)
            }
        }
        .padding(.top, 12)
    }

    // MARK: ③ 信息行 + summary + 反查行 + 已读按钮（B.4）

    private var infoBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if score > 0 {
                infoLine(MovieDetailCopy.infoScore,
                         MovieDetailCopy.scoreValue(
                            score: Fmt.score(score), reviews: m?.i("reviews_count") ?? 0))
            }
            if let rd = m?.s("release_date"), !rd.isEmpty {
                infoLine(MovieDetailCopy.infoRelease, rd)
            }
            if let du = m?.s("duration"), !du.isEmpty {
                infoLine(MovieDetailCopy.infoDuration, du)
            }
            let want = m?.i("want_watch_count") ?? 0
            if want > 0 {
                infoLine(MovieDetailCopy.infoWant, String(want))
            }
            let watched = m?.i("watched_count") ?? 0
            if watched > 0 {
                infoLine(MovieDetailCopy.infoWatched, String(watched))
            }
            if m?.b("has_cnsub") == true {
                // 单独一行 Meta「✓ 中文字幕」（tertiary 色）
                AppText(MovieDetailCopy.cnsubLine, lvl: .meta, color: theme.accent2)
                    .padding(.top, 4)
            }
            if let sm = m?.s("summary"), !sm.isEmpty {
                AppText(sm, lvl: .meta)
                    .padding(.top, 8)
            }
            jumpLines
            readButton
        }
        .padding(.top, 12)
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        AppText("\(label): \(value)", lvl: .meta)
            .padding(.top, 4)
    }

    // 反查行（JumpLines：标签全角冒号；缺值「—」不可点；有值下划线整行可点 ≥48）
    private var jumpLines: some View {
        let rows = m.map { MovieDetailVM.jumpLinks(m: $0) } ?? []
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, link in
                jumpRow(link)
            }
            tagLine
        }
        .padding(.top, 8)
    }

    private func jumpRow(_ link: MovieJumpLink) -> some View {
        Group {
            if let payload = link.payload {
                Button {
                    router.push(.lookup(payload))
                } label: {
                    HStack(spacing: 0) {
                        AppText(link.label, lvl: .meta)
                        AppText(link.value, lvl: .meta, color: theme.accent, underline: true,
                                maxLines: 1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: ComponentMetrics.buttonMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)   // 无涟漪
            } else {
                HStack(spacing: 0) {
                    AppText(link.label, lvl: .meta)
                    AppText(link.value, lvl: .meta)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ComponentMetrics.buttonMin)
            }
        }
    }

    // 标签行：「标签：」前缀 + 每标签 12pt primary 下划线小文本（不用 chip 外壳）
    @ViewBuilder
    private var tagLine: some View {
        let links = MovieDetailVM.tagLinks(tags: vm.tags)
        if !links.isEmpty {
            (HStack(alignment: .firstTextBaseline, spacing: 0) {
                AppText(MovieDetailCopy.jumpTagPrefix, lvl: .meta)
                FlowHStack(spacing: 10) {
                    ForEach(Array(links.enumerated()), id: \.offset) { _, tag in
                        Button {
                            router.push(.lookup(tag.payload))
                        } label: {
                            AppText(tag.name, lvl: .meta, color: theme.accent, underline: true,
                                    maxLines: 1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: ComponentMetrics.buttonMin))
        }
    }

    // 已读按钮（FilledTonalButton，位于反查行下 8pt）
    private var readButton: some View {
        Button {
            UIPasteboard.general.string = number   // readMark 实际只返回番号（B.4 注）
            Task { await vm.onReadButtonPressed() }
        } label: {
            AppText(vm.read ? MovieDetailCopy.readButtonRead : MovieDetailCopy.readButtonUnread,
                    lvl: .bodyS, color: theme.accent, fontWeight: .medium, maxLines: 1)
                .padding(.horizontal, 16)
                .frame(minHeight: ComponentMetrics.buttonMin)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.15)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityIdentifier("movie_read_button")
    }

    // MARK: ④ 演员（♀粉 ♂蓝 小卡横滑；actors 为空整块隐藏）

    @ViewBuilder
    private var actorsBlock: some View {
        if !vm.actors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                AppText(MovieDetailCopy.actorsTitle, lvl: .bodyS, fontWeight: .bold)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(vm.actors.enumerated()), id: \.offset) { _, a in
                            actorChip(a)
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    private func actorChip(_ a: Row) -> some View {
        let male = a.i("gender") == 1
        let color = male ? Self.maleBlue : theme.accent2   // 女 = tertiary（粉系）/ 男 = 蓝
        let name = a.s("actor_name").isEmpty ? a.s("name") : a.s("actor_name")
        let aid = a.s("actor_id")
        return Button {
            if !aid.isEmpty { router.push(.actor(aid)) }
        } label: {
            AppText((male ? MovieDetailCopy.maleSign : MovieDetailCopy.femaleSign) + name,
                    lvl: .meta, color: color, fontWeight: .medium, maxLines: 1)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.35), lineWidth: ComponentMetrics.cardStroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(aid.isEmpty)
    }

    /// ♂ 蓝系（主题无 secondary token，固定蓝；♀ 用 theme.accent2 = tertiary 粉系）
    private static let maleBlue = Color(red: 0x4C / 255.0, green: 0x7D / 255.0, blue: 0xF0 / 255.0)

    // MARK: ⑤ 剧照（横滑；previews 为空整块隐藏）

    @ViewBuilder
    private var previewsBlock: some View {
        if !vm.previews.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // 14sp 加粗（B.6）
                Text(MovieDetailCopy.previewsTitle(vm.previews.count))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(theme.text)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(vm.previews.enumerated()), id: \.offset) { i, p in
                            Button {
                                lightboxIndex = vm.galleryIndexOfPreview(i)
                                lightboxOpen = true
                            } label: {
                                PosterImage(url: MovieImg.preview(p), aspect: 3.0 / 2.0)
                                    .frame(width: 160)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
    }

    // MARK: ⑥ 磁力卡（B.7：整卡点击复制 + Toast）

    private var magnetsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.magnets.isEmpty {
                // 空态 12sp onSurfaceVariant
                AppText(magnetsHeaderText, lvl: .meta)
            } else {
                // 14sp 加粗（B.7）
                Text(magnetsHeaderText)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(theme.text)
            }
            ForEach(Array(vm.magnets.enumerated()), id: \.offset) { _, mag in
                magnetCard(mag)
            }
        }
        .padding(.top, 16)
    }

    private func magnetCard(_ mag: Row) -> some View {
        Button {
            UIPasteboard.general.string = MovieDetailVM.magnetLink(mag)
            vm.onMagnetCopied()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // 主行：magnet:?xt=urn:btih:{hash}（Monospace 12，最多 2 行省略）
                    Text(MovieDetailVM.magnetLink(mag))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 角标：{fmtSize}{ · 中字}
                    AppText(MovieDetailVM.magnetBadge(mag), lvl: .meta, color: theme.accent,
                            maxLines: 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accent.opacity(0.12)))
                }
                if MovieDetailVM.magnetHasSecondLine(mag) {
                    AppText(MovieDetailVM.magnetSecondLine(mag), lvl: .meta, maxLines: 1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)   // 无涟漪整卡可点
        .accessibilityIdentifier("magnet_card")
    }

    // MARK: ⑦ 相关资讯（无关联整块隐藏；点行 push article）

    @ViewBuilder
    private var articlesBlock: some View {
        if !vm.relatedArticles.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                AppText(MovieDetailCopy.articlesTitle, lvl: .bodyS, fontWeight: .semibold)
                    .padding(.bottom, 4)
                ForEach(Array(vm.relatedArticles.enumerated()), id: \.offset) { _, art in
                    Button {
                        router.push(.article(art.s("id")))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            AppText(art.s("title").isEmpty ? " " : art.s("title"),
                                    lvl: .bodyS, maxLines: 2, textAlign: .leading)
                            let sub = [art.s("category_name"),
                                       String(art.s("released_at").prefix(10))]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            if !sub.isEmpty {
                                AppText(sub, lvl: .meta, maxLines: 1)
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 16)
        }
    }
}

// MARK: - FlowHStack（标签行换行流式布局；iOS 16 Layout 对位 Android FlowRow）

struct FlowHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
