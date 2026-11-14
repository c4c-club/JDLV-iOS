import SwiftUI
import JDLVCore

//
//  Cards.swift —— MovieCard 三档 / ShtCard / ActorCard / ViewAllCard（07 B11/B13/B14/B15
//  + 13 §2.5/§2.6 设计系统 v2 重写）。
//
//  v2 契约（问题 5/6/8 根因修复）：
//  - 图片一律 AspectImage（先定框：ratio 决定布局高；图片只做 overlay，不再撑大布局）。
//  - 卡片填满父容器：CardGrid/横滑行给 frame(cellW, cardH)；卡内部不假设宽度。
//  - 文本块固定高（CardLayout：Movie 76/86、Sht 68/76、Actor 44），标题
//    lineLimit(2, reservesSpace)（AppText tight+reservesSpace），元信息 1 行。
//  - CardShell 承担背景/描边/圆角/阴影/裁剪，内容不得溢出。
//

// MARK: - 卡片容器（v2：CardShell；保留 cardChrome 给未迁移调用方）
// R4 P4：默认无逐卡阴影（每 cell 一次离屏渲染 → 滚动 GPU/CPU 双高）；
// 列表/网格卡片 elevated:false（默认）只留 1pt 描边 + clipShape；详情头部/弹层可 elevated:true。

struct CardChrome: ViewModifier {
    /// true = 保留阴影（详情页头部/弹层等少数场景）
    var elevated: Bool = false

    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        let base = content
            .background(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner).fill(theme.bg1))
            .overlay(
                RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner)
                    .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke)
            )
        if elevated {
            base.shadow(color: .black.opacity(0.12),
                        radius: ComponentMetrics.cardElevation,
                        y: ComponentMetrics.cardElevation / 2)
        } else {
            base
        }
    }
}

extension View {
    func cardChrome(elevated: Bool = false) -> some View { modifier(CardChrome(elevated: elevated)) }
}

// MARK: - 已读小圆点（6pt primary）

private struct ReadDot: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        Circle().fill(theme.accent).frame(width: 6, height: 6)
    }
}

// MARK: - MovieCard（viewMode 0 小图 3:4+76 / 1 大图 16:9+86 / 2 列表行）

struct MovieCard: View {
    let m: Row
    let viewMode: Int
    var read: Bool = false
    var fav: Bool = false
    var onClick: () -> Void

    @Environment(\.appTheme) private var theme

    private var number: String { m.s("number") }
    private var title: String { m.s("title") }
    private var score: Double { m.d("score") }
    private var coverUrl: String { m.s("cover_url") }
    /// 元信息（顺序与条件逐字，B11）
    static func metaParts(m: Row, fav: Bool) -> [String] {
        AppCopy.movieMetaParts(
            releaseDate: m.s("release_date"),
            wantWatch: m.i("want_watch_count"),
            magnets: m.i("magnets_count"),
            fav: fav)
    }
    private var metaText: String { AppCopy.joinMeta(Self.metaParts(m: m, fav: fav)) }
    private var titleColor: Color { read ? theme.text.opacity(0.6) : theme.text }

    var body: some View {
        Button(action: onClick) {
            Group {
                if viewMode == 2 { listRow } else { gridCell }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)   // clickableNoRipple：无系统按压效果
        .cardChrome()
    }

    // MARK: 列表模式（viewMode==2）：Row(minHeight 72, padding 6, spacedBy 8)

    private var listRow: some View {
        HStack(alignment: .top, spacing: 8) {
            AspectImage(url: coverUrl, ratio: 84.0 / 60.0, half: true, radius: 8)
                .frame(width: 84, height: 60)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if read { ReadDot() }
                    AppText(number, lvl: .bodyS, color: theme.accent, maxLines: 1, fontWeight: .bold)
                    Spacer(minLength: 4)
                    if score > 0 {
                        AppText("★ \(Fmt.score(score))", lvl: .meta, color: theme.accent2)
                    }
                }
                AppText(title.isEmpty ? " " : title, lvl: .meta, color: titleColor,
                        maxLines: 1, textAlign: .leading)
                    .padding(.top, 1)
                AppText(metaText, lvl: .meta, maxLines: 1)
                    .padding(.top, 1)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }

    // MARK: 网格模式（v2：AspectImage 定框 + 固定文本块，填满 CardGrid 给的 cell）

    private var gridCell: some View {
        VStack(alignment: .leading, spacing: 0) {
            AspectImage(url: coverUrl,
                        ratio: viewMode == 1 ? 16.0 / 9.0 : 3.0 / 4.0,
                        half: viewMode == 0,           // 小图取右半（受 coverHalf 设置）
                        radius: 0)
            textBlock(height: viewMode == 1 ? ComponentMetrics.textBlockLarge
                                            : ComponentMetrics.textBlockSmall,
                      titleLines: 2)
        }
    }

    /// 固定高文本块：番号行(13 bold) + 标题 2 行预留(13) + 元信息 1 行(12)；
    /// tight 行距贴合 CardLayout 公式（76/86）。
    private func textBlock(height: CGFloat, titleLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if read { ReadDot() }
                AppText(number, lvl: .bodyS, color: theme.accent,
                        maxLines: 1, fontWeight: .bold, tight: true)
                Spacer(minLength: 4)
                if score > 0 {
                    AppText("★ \(Fmt.score(score))", lvl: .meta, color: theme.accent2, tight: true)
                }
            }
            AppText(title.isEmpty ? " " : title, lvl: .bodyS, color: titleColor,
                    maxLines: titleLines, textAlign: .leading,
                    tight: true, reservesSpace: true)
            AppText(metaText, lvl: .meta, maxLines: 1, tight: true)
        }
        .padding(.horizontal, ComponentMetrics.cardPadding)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
    }
}

// MARK: - ShtCard（98t 帖子卡：大图 16:10+76 / 小图·列表 4:5+68）

struct ShtCard: View {
    let t: Row
    /// Img.shtCover() 之后的 URL（调用方算好；空 → 静态占位）
    let coverUrl: String
    let viewMode: Int
    var read: Bool = false
    var fav: Bool = false
    var onClick: () -> Void

    @Environment(\.appTheme) private var theme

    private var title: String { t.s("title") }
    private var metaText: String {
        AppCopy.joinMeta(AppCopy.shtMetaParts(
            postDate: t.s("post_date"),
            boardName: t.s("board_name"),
            magnetCount: t.i("magnet_count"),
            fav: fav))
    }
    private var coverRatio: CGFloat { viewMode == 1 ? 1.6 : 4.0 / 5.0 }

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                // 文本块合计 = CardLayout 的 68/76/86：标题块 40（上）+ meta 块 28（下）
                HStack(alignment: .top, spacing: 4) {
                    if read { ReadDot() }
                    // maxLines 2 reservesSpace（两行占位等高）
                    AppText(title.isEmpty ? " " : title, lvl: .bodyS,
                            color: read ? theme.text.opacity(0.6) : theme.text,
                            maxLines: 2, textAlign: .leading,
                            tight: true, reservesSpace: true)
                }
                .padding(.horizontal, ComponentMetrics.cardPadding)
                .padding(.top, ComponentMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 40, alignment: .topLeading)
                if coverUrl.isEmpty {
                    ShtCoverPlaceholder(t: t, ratio: coverRatio)
                } else {
                    AspectImage(url: coverUrl,
                                ratio: coverRatio,
                                half: viewMode == 0,      // 小图也按"取右半"设置生效
                                radius: 0)
                }
                AppText(metaText, lvl: .meta, maxLines: 1, tight: true)
                    .padding(.horizontal, ComponentMetrics.cardPadding)
                    .padding(.bottom, ComponentMetrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .frame(height: 28, alignment: .bottomLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
    }
}

// MARK: - ShtCoverPlaceholder（B14：无封面帖子静态占位，无重试文案）

struct ShtCoverPlaceholder: View {
    let t: Row
    var ratio: CGFloat = 4.0 / 5.0
    @Environment(\.appTheme) private var theme

    /// magnet_count>0 → 🧲；type/cat_name 含"图" → 🖼；words>0 → 📝；否则 📄
    private var icon: String {
        if t.i("magnet_count") > 0 { return "🧲" }
        if t.s("type").contains("图") || t.s("cat_name").contains("图") { return "🖼" }
        if t.i("words") > 0 { return "📝" }
        return "📄"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0).fill(theme.bg3)
            VStack(spacing: 2) {
                AppText(icon, lvl: .titleM, color: theme.text2)
                let ch = t.s("title").first.map(String.init) ?? ""
                if !ch.isEmpty {
                    AppText(ch, lvl: .meta, color: theme.text2)
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
    }
}

// MARK: - ActorCard（B15：头像 1:1 + "N 部" + ·★均分；v2 文本块固定 44）

struct ActorCard: View {
    let a: Row
    var onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                AspectImage(url: a.s("avatar_url"), ratio: 1, radius: 0)   // Img.actorAvatar()
                VStack(alignment: .leading, spacing: 2) {
                    AppText(a.s("name").isEmpty ? " " : a.s("name"), lvl: .meta,
                            maxLines: 1, fontWeight: .medium, tight: true)
                    AppText(AppCopy.actorMetaLine(
                        videosCount: a.i("videos_count"),
                        avgScoreAll: a.d("avg_score_all")), lvl: .meta, maxLines: 1, tight: true)
                }
                .padding(.horizontal, ComponentMetrics.cardPadding)
                .padding(.top, 4)
                .padding(.bottom, ComponentMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 44, alignment: .topLeading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
    }
}

// MARK: - ViewAllCard（07 C4：行尾"查看全部"占位卡；v2 高度由外部 frame 决定）

struct ViewAllCard: View {
    var onClick: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onClick) {
            ZStack {
                RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [9, 7]))
                    .foregroundColor(theme.text2)
                VStack(spacing: 4) {
                    AppText("›", lvl: .titleL, color: theme.text2)
                    AppText("查看全部", lvl: .meta, color: theme.text2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
