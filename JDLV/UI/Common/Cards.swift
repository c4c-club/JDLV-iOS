import SwiftUI
import JDLVCore

//
//  Cards.swift —— MovieCard 三档 / ShtCard / ActorCard / ViewAllCard（07 B11/B13/B14/B15、08 A.4）。
//
//  Card 规格（四卡同款）：1pt outlineVariant(theme.line) 描边 + 2pt 投影 + surface(theme.bg1) 底。
//  "已读"灰化是全局唯一允许的 alpha<0.9 文本（60%）——标题用 theme.text.opacity(0.6)。
//  元信息四段拼接顺序与条件逐字（AppCopy.movieMetaParts / shtMetaParts）。
//

// MARK: - 卡片容器（1pt 描边 + 2pt 投影 + surface 底）

struct CardChrome: ViewModifier {
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner).fill(theme.bg1))
            .overlay(
                RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner)
                    .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke)
            )
            .shadow(color: .black.opacity(0.12),
                    radius: ComponentMetrics.cardElevation,
                    y: ComponentMetrics.cardElevation / 2)
    }
}

extension View {
    func cardChrome() -> some View { modifier(CardChrome()) }
}

// MARK: - 已读小圆点（6pt primary）

private struct ReadDot: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        Circle().fill(theme.accent).frame(width: 6, height: 6)
    }
}

// MARK: - MovieCard（viewMode 0 小图 / 1 大图 / 2 列表行）

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
            PosterImage(url: coverUrl, half: true)
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
        .frame(minHeight: 72, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 网格模式（viewMode 0 小图 400:520 右半 / 1 大图 800:520 整张）：Column(padding 8)

    private var gridCell: some View {
        VStack(alignment: .leading, spacing: 0) {
            PosterImage(url: coverUrl,
                        half: viewMode == 0,           // 小图取右半（受 coverHalf 设置）
                        aspect: viewMode == 1 ? 800.0 / 520.0 : 400.0 / 520.0)
            Group {
                HStack(spacing: 4) {
                    if read { ReadDot() }
                    AppText(number, lvl: viewMode == 1 ? .body : .bodyS,
                            color: theme.accent, maxLines: 1, fontWeight: .bold)
                    Spacer(minLength: 4)
                    if score > 0 {
                        AppText("★ \(Fmt.score(score))", lvl: .meta, color: theme.accent2)
                    }
                }
                AppText(title.isEmpty ? " " : title, lvl: .bodyS, color: titleColor,
                        maxLines: viewMode == 1 ? 3 : 2, textAlign: .leading)
                    .padding(.top, 2)
                AppText(metaText, lvl: .meta, maxLines: 1)
                    .padding(.top, 4)
            }
            .padding(.horizontal, ComponentMetrics.cardPadding)
            .padding(.top, 6)
            .padding(.bottom, ComponentMetrics.cardPadding)
        }
    }
}

// MARK: - ShtCard（98t 帖子卡：大图 1.6:1 / 小图·列表 4:5）

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
    private var coverAspect: CGFloat { viewMode == 1 ? 1.6 : 4.0 / 5.0 }

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    if read { ReadDot() }
                    // maxLines 2 minLines 2（两行占位等高）
                    AppText(title.isEmpty ? " " : title, lvl: .bodyS,
                            color: read ? theme.text.opacity(0.6) : theme.text,
                            maxLines: 2, minLines: 2, textAlign: .leading)
                }
                .padding(.horizontal, ComponentMetrics.cardPadding)
                .padding(.top, ComponentMetrics.cardPadding)
                if coverUrl.isEmpty {
                    ShtCoverPlaceholder(t: t, aspect: coverAspect)
                        .padding(ComponentMetrics.cardPadding)
                } else {
                    PosterImage(url: coverUrl,
                                half: viewMode == 0,      // 小图也按"取右半"设置生效
                                aspect: coverAspect)
                        .padding(ComponentMetrics.cardPadding)
                }
                AppText(metaText, lvl: .meta, maxLines: 1)
                    .padding(.horizontal, ComponentMetrics.cardPadding)
                    .padding(.bottom, ComponentMetrics.cardPadding)
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
    var aspect: CGFloat = 4.0 / 5.0
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
            RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner).fill(theme.bg3)
            VStack(spacing: 2) {
                AppText(icon, lvl: .titleM, color: theme.text2)
                let ch = t.s("title").first.map(String.init) ?? ""
                if !ch.isEmpty {
                    AppText(ch, lvl: .meta, color: theme.text2)
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}

// MARK: - ActorCard（B15：头像 1:1 + "N 部" + ·★均分）

struct ActorCard: View {
    let a: Row
    var onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: .leading, spacing: 0) {
                PosterImage(url: a.s("avatar_url"), aspect: 1)   // Img.actorAvatar()
                    .padding(ComponentMetrics.cardPadding)
                VStack(alignment: .leading, spacing: 2) {
                    AppText(a.s("name").isEmpty ? " " : a.s("name"), lvl: .meta,
                            maxLines: 1, fontWeight: .medium)
                    AppText(AppCopy.actorMetaLine(
                        videosCount: a.i("videos_count"),
                        avgScoreAll: a.d("avg_score_all")), lvl: .meta, maxLines: 1)
                }
                .padding(.horizontal, ComponentMetrics.cardPadding)
                .padding(.bottom, ComponentMetrics.cardPadding)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardChrome()
    }
}

// MARK: - ViewAllCard（07 C4：行尾"查看全部"占位卡 180×200，虚线框）

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
            .frame(width: 180, height: 200)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
