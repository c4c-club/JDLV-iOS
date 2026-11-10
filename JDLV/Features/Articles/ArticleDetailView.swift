import SwiftUI
import JDLVCore

//
//  ArticleDetailView.swift —— 资讯详情页（10 §2.5 逐区块移植；正文原生分块渲染，不用 WebView）。
//
//  状态：首载且无 row → 居中转圈；error 且无 row → ErrorBox（ErrText + 重试）；
//  row==null（查询成功但无此 id）→「未找到该资讯」。
//
//  正文区（竖向滚动）：① 16:9 封面（点击灯箱 index 0）→ ② 标题 TitleL + 元信息
//  （分类/作者/来源:{origin_name}/released_at 前 10 位，空段跳过）→ ③ 1dp 分隔线 +
//  8pt → ④ ArticleBody 分块（<img> 正则切块；外链图占位；番号可点 → movieByNumber →
//  push movie / Toast「未收录番号 N」）→ ⑤ 相关影片（articleMovies 非空才显示；
//  封面 66×88 + 标题 + number · release_date；整行点击 → movie/{movie_id}）→ 尾部 24pt。
//
//  灯箱：gallery = [顶部封面(若有)] + 正文可进灯箱图（外链图排除、解析为空的排除）；
//  封面 index 0；正文第 i 张（原始序）→ rawToFiltered + 封面偏移。
//

struct ArticleDetailView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var services: AppServices
    @Environment(\.appTheme) private var theme

    let aid: String

    @StateObject private var vm: ArticleDetailVM
    @State private var lightboxOpen = false
    @State private var lightboxIndex = 0

    init(aid: String) {
        self.aid = aid
        _vm = StateObject(wrappedValue: ArticleDetailVM.makeDefault())
    }

    /// 顶栏标题：文章标题（1 行省略）；未加载时「资讯」
    private var navTitle: String {
        let t = vm.row?.s("title") ?? ""
        return t.isEmpty ? ArticlesCopy.navTitleFallback : t
    }

    /// 「该篇以图片为主」判定：去标签纯文本 <20 字 且 HTML 含 <img
    private var isImageMain: Bool {
        vm.html.contains("<img") && ArticleHtml.plainBodyLength(vm.html) < 20
    }

    var body: some View {
        Group {
            if vm.loading && vm.row == nil {
                LoadingBox()
            } else if vm.error != nil && vm.row == nil {
                ErrorBox(text: vm.error ?? "", onRetry: { Task { await vm.load(aid: aid) } })
            } else if vm.row == nil {
                EmptyBox(text: ArticlesCopy.notFoundText)
            } else {
                content
            }
        }
        .background(theme.bg0.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await vm.load(aid: aid) } }
        .onDisappear { vm.release() }   // 返回销毁重置；再进 load 自动重载
        .fullScreenCover(isPresented: $lightboxOpen) {
            Lightbox(urls: vm.lightboxGallery, initialIndex: lightboxIndex) { lightboxOpen = false }
        }
        .accessibilityIdentifier("article_detail")
    }

    // MARK: 正文区

    // R4 P5：回顶（同 MovieDetail；detail 无 TabBar → inset 0）
    @State private var showScrollTop = false

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ScrollOffsetReader(space: "article_detail_space")
                LazyVStack(alignment: .leading, spacing: 0) {
                    coverBlock          // ① 16:9 封面
                    titleBlock          // ② 标题 + 元信息
                    dividerBlock        // ③ 1dp 分隔线 + 8pt
                    bodyBlock           // ④ 分块正文
                    relatedMoviesBlock  // ⑤ 相关影片
                    Color.clear.frame(height: 24)   // 尾部 24pt
                }
                .id("article_detail_top")
            }
            .coordinateSpace(name: "article_detail_space")
            .scrollTopOffsetWatcher(show: $showScrollTop)
            .scrollTopOverlay(visible: showScrollTop, bottomInset: 0) {
                withAnimation { proxy.scrollTo("article_detail_top", anchor: .top) }
            }
        }
    }

    // ① 16:9 封面（Img.articleCover；有点击 → 灯箱 index 0）
    @ViewBuilder
    private var coverBlock: some View {
        if !vm.coverUrl.isEmpty {
            Button {
                lightboxIndex = 0
                lightboxOpen = true
            } label: {
                PosterImage(url: vm.coverUrl, aspect: 16.0 / 9.0)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // ② 标题 TitleL(20) + 元信息 1 行（Meta，空段跳过 " · " 连接）
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            let t = vm.row?.s("title") ?? ""
            AppText(t.isEmpty ? " " : t, lvl: .titleL)
                .padding(.top, 12)
            let meta = AppCopy.joinMeta(
                vm.row.map { ArticleDetailVM.metaParts($0) } ?? [])
            if !meta.isEmpty {
                AppText(meta, lvl: .meta, maxLines: 1)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
    }

    // ③ 1dp 分隔线（outlineVariant）+ 8pt
    private var dividerBlock: some View {
        Rectangle()
            .fill(theme.line)
            .frame(height: 1)
            .padding(.top, 12)
            .padding(.bottom, 8)
    }

    // ④ 正文分块（边缘文案：该篇以图片为主 / (无正文)）
    @ViewBuilder
    private var bodyBlock: some View {
        if vm.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            AppText(ArticlesCopy.noBodyText, lvl: .meta)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        } else {
            if isImageMain {
                AppText(ArticlesCopy.imageMainNote, lvl: .meta)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            ArticleBodyView(
                html: vm.html,
                onNumber: { n in Task { await tapNumber(n) } },
                onImageClick: { raw in tapBodyImage(raw) })
        }
    }

    // ⑤ 相关影片（articleMovies 非空才显示；movie_id 空白不跳）
    @ViewBuilder
    private var relatedMoviesBlock: some View {
        if !vm.relatedMovies.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                AppText(ArticlesCopy.relatedMoviesTitle, lvl: .bodyS, fontWeight: .semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                ForEach(Array(vm.relatedMovies.enumerated()), id: \.offset) { _, r in
                    relatedMovieRow(r)
                }
            }
            .padding(.top, 12)
        }
    }

    private func relatedMovieRow(_ r: Row) -> some View {
        let mid = r.s("movie_id")
        let title = r.s("title").isEmpty ? r.s("number") : r.s("title")
        let sub = ArticleDetailVM.relatedMovieSub(r)
        return Button {
            if !mid.isEmpty { router.push(.movie(mid)) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                PosterImage(url: ArticleImg.articleCover(r.s("thumb_url")))
                    .frame(width: 66, height: 88)
                VStack(alignment: .leading, spacing: 4) {
                    AppText(title.isEmpty ? " " : title, lvl: .bodyS,
                            maxLines: 2, textAlign: .leading)
                    if !sub.isEmpty {
                        AppText(sub, lvl: .meta, maxLines: 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(mid.isEmpty)
        .accessibilityIdentifier("article_related_movie")
    }

    // MARK: 交互

    /// 番号点击：movieByNumber → push movie/{id}；未收录 → Toast「未收录番号 N」
    private func tapNumber(_ number: String) async {
        if let mid = await vm.resolveNumber(number) {
            router.push(.movie(mid))
        }
    }

    /// 正文图点击：原始图序 → 灯箱过滤序 + 封面偏移
    private func tapBodyImage(_ rawIndex: Int) {
        guard let idx = vm.galleryIndexOfBodyImage(rawIndex) else { return }
        lightboxIndex = idx
        lightboxOpen = true
    }
}
