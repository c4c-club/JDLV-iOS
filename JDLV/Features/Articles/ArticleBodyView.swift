import SwiftUI
import UIKit
import JDLVCore

//
//  ArticleBodyView.swift —— 资讯正文分块渲染 + HTML 清洗 + 番号可点
//  （10 §3 ArticleBody/ArticleHtml/ArticleNumberLinking 逐条移植；不用 WKWebView）。
//
//  分块规则（§3.1）：
//  - 按 <img> 正则 `(?i)<img[^>]+src=["']([^"']+)["'][^>]*>` 切块 → ABlock.T(文本) / ABlock.I(图片)；
//  - 文本片段去标签后为空 → 丢弃（避免空段落占位）；
//  - 外链图（CdnRewrite.kindOf == .external）→ 16:9 虚线占位块（dash [9,7]）居中两行
//    「🔗 外链图」+「点击在浏览器打开」，点击系统浏览器打开；不进灯箱、不重写 URL；
//  - 普通图 → Img.articleCover 非空 → PosterImage 16:9，点击回传原始图序（灯箱定位）。
//
//  sanitize 三条清洗正则（§3.2，保留标签结构与文字，防浅色主题白底白字）：
//  1. 删除全部 <font>/</font> 标签；2. 删除内联 color/background(-color) 样式；
//  3. 删除 bgcolor 属性。
//
//  番号识别（§3.3）：正则 `[A-Za-z]{2,6}-?\d{2,6}`，候选长度 ≥5 才有效；
//  样式 primary + 加粗 + 无下划线；点击回调 onNumber（→ movieByNumber → 跳影片/Toast）。
//  iOS 实现：AttributedString link（自定义 scheme）+ OpenURLAction 拦截。
//

// MARK: - 块模型 + HTML 解析（ArticleHtml 对位）

/// 正文块：t = 文本片段（清洗去标签后）/ i = 图片 src（原始序号供灯箱定位）
enum ABlock: Equatable {
    case text(String)
    case image(src: String, rawIndex: Int)
}

enum ArticleHtml {

    /// img 分块正则（§3.1 逐字）
    static let imgRegex = try! NSRegularExpression(
        pattern: "(?i)<img[^>]+src=[\"']([^\"']+)[\"'][^>]*>")
    /// 番号正则（§3.3：候选 ≥5 位才有效）
    static let numberRegex = try! NSRegularExpression(pattern: "([A-Za-z]{2,6})-?(\\d{2,6})")

    /// parseArticleBlocks：按 img 正则切块；文本片段去标签为空丢弃
    static func parseBlocks(_ html: String) -> [ABlock] {
        var blocks: [ABlock] = []
        var rawIndex = 0
        let ns = html as NSString
        let matches = imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let frag = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                appendText(frag, to: &blocks)
            }
            if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
                let src = ns.substring(with: m.range(at: 1))
                blocks.append(.image(src: src, rawIndex: rawIndex))
                rawIndex += 1
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            appendText(ns.substring(from: cursor), to: &blocks)
        }
        return blocks
    }

    /// 文本片段：sanitize → 去标签 → 空白丢弃
    private static func appendText(_ frag: String, to blocks: inout [ABlock]) {
        let plain = plainText(frag)
        if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(plain))
        }
    }

    /// sanitizeHtml 三条清洗正则（§3.2 逐字；仅删标签/样式，不动正文）
    static func sanitize(_ html: String) -> String {
        var s = html
        // 1) 删除全部 <font>/</font> 标签
        s = regexRemove("(?i)</?\\s*font[^>]*>", s)
        // 2) 删除内联颜色样式
        s = regexRemove("(?i)(color|background|background-color)\\s*:\\s*[^;\"']*;?", s)
        // 3) 删除 bgcolor 属性
        s = regexRemove("(?i)\\s*bgcolor=(\"[^\"]*\"|'[^']*'|[^\\s>]+)", s)
        return s
    }

    private static func regexRemove(_ pattern: String, _ s: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }

    /// 片段 → 纯文本：sanitize → br/块级闭合标签 → 换行 → 去其余标签 → 实体反转义 →
    /// 压平 3+ 空行 → 首尾空白修剪
    static func plainText(_ frag: String) -> String {
        var s = sanitize(frag)
        s = regexReplace("(?i)<br\\s*/?>", s, "\n")
        s = regexReplace("(?i)</p>|</div>|</li>", s, "\n")
        s = regexRemove("<[^>]+>", s)
        s = decodeEntities(s)
        // 压平 3+ 连续换行 → 2（HTML 块级间距）
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexReplace(_ pattern: String, _ s: String, _ template: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    /// 常用实体反转义（HTML 五大 + nbsp/apos/数字实体）
    static func decodeEntities(_ s: String) -> String {
        var t = s
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (e, v) in named { t = t.replacingOccurrences(of: e, with: v) }
        // 数字实体 &#123; / &#x1F;
        let re = try! NSRegularExpression(pattern: "&#(\\d+);|&#x([0-9a-fA-F]+);")
        let ns = t as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            var scalar: UInt32 = 0
            if m.range(at: 1).location != NSNotFound {
                scalar = UInt32(ns.substring(with: m.range(at: 1))) ?? 0
            } else if m.range(at: 2).location != NSNotFound {
                scalar = UInt32(ns.substring(with: m.range(at: 2)), radix: 16) ?? 0
            }
            if let u = Unicode.Scalar(scalar) { out += String(Character(u)) }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// articleImages：全部 <img src> 按出现顺序
    static func articleImages(_ html: String) -> [String] {
        let ns = html as NSString
        return imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
            .filter { $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound }
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// lightboxImages：排除外链 + articleCover 非空过滤；（原始序 → 过滤序）映射表供点击定位
    static func lightboxImages(_ html: String) -> (images: [String], rawToFiltered: [Int?]) {
        let all = articleImages(html)
        var images: [String] = []
        var rawToFiltered: [Int?] = []
        for src in all {
            let mapped = ArticleImg.articleCover(src)
            if !isExternal(src), !mapped.isEmpty {
                rawToFiltered.append(images.count)
                images.append(mapped)
            } else {
                rawToFiltered.append(nil)
            }
        }
        return (images, rawToFiltered)
    }

    /// Img.isExternal：CdnRewrite.kindOf == EXTERNAL（instagram/x.com 等）
    static func isExternal(_ src: String) -> Bool {
        CdnRewrite.kindOf(src) == .external
    }

    /// 番号候选（§3.3：≥5 位才有效；NSRegularExpression 匹配天然不重叠 → 同区间一个 span）
    static func numberCandidates(in text: String) -> [(range: NSRange, number: String)] {
        let ns = text as NSString
        return numberRegex
            .matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                guard m.range.location != NSNotFound else { return nil }
                let cand = ns.substring(with: m.range)
                return cand.count >= 5 ? (m.range, cand) : nil
            }
    }

    /// 正文纯文本长度（「该篇以图片为主」判定用：去标签纯文本 <20 字）
    static func plainBodyLength(_ html: String) -> Int {
        plainText(html).trimmingCharacters(in: .whitespacesAndNewlines).count
    }
}

// MARK: - ArticleBodyView（分块渲染）

struct ArticleBodyView: View {
    let html: String
    /// 番号点击（→ VM.resolveNumber → push movie / Toast 未收录）
    var onNumber: (String) -> Void
    /// 普通图点击（回传原始图序；调用方接灯箱）
    var onImageClick: (Int) -> Void

    @Environment(\.appTheme) private var theme

    /// 文本块排版（§3.2：16pt；行距 = 额外 4pt + 倍数 1.75 → lineSpacing 16pt）
    static let bodyFontSize: CGFloat = 16
    static let bodyLineSpacing: CGFloat = ArticleBodyView.bodyFontSize * 1.75 + 4
        - ArticleBodyView.bodyFontSize

    var body: some View {
        let blocks = ArticleHtml.parseBlocks(html)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let t): textBlock(t)
                case .image(let src, let rawIndex): imageBlock(src: src, rawIndex: rawIndex)
                }
            }
        }
    }

    // MARK: 文本块（番号 span primary 粗体无下划线；长按可选中）

    private func textBlock(_ t: String) -> some View {
        Text(numberLinked(t))
            .textSelection(.enabled)
            .font(.system(size: Self.bodyFontSize))
        .lineSpacing(Self.bodyLineSpacing)
        .foregroundColor(theme.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "jdlv-number" {
                // 番号在 scheme 后的 opaque 段（URL.host 会小写化，破坏原文大小写）
                let raw = url.absoluteString.dropFirst("jdlv-number:".count)
                let decoded = raw.removingPercentEncoding ?? String(raw)
                if !decoded.isEmpty { onNumber(decoded) }
                return .handled
            }
            return .systemAction
        })
    }

    /// 番号 run：primary 色 + 加粗 + 无下划线 + 可点（scheme + opaque 段携带原文番号）
    func numberLinked(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        for cand in ArticleHtml.numberCandidates(in: text) {
            // AttributedString(text) 与原串共享 String.Index → NSRange 直接换算
            guard let r = Range(cand.range, in: text) else { continue }
            if attr[r].link == nil {   // 同区间只套一个 span
                attr[r].foregroundColor = theme.accent
                attr[r].font = .system(size: Self.bodyFontSize, weight: .bold)
                attr[r].underlineStyle = nil
                attr[r].link = Self.numberURL(cand.number)
            }
        }
        return attr
    }

    /// 番号 → 可点 URL（opaque 形态 "jdlv-number:<番号>"；percent 编码防特殊字符）
    static func numberURL(_ number: String) -> URL? {
        let enc = number.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? number
        return URL(string: "jdlv-number:" + enc)
    }

    // MARK: 图片块（外链图占位不进灯箱；普通图 16:9 可点）

    @ViewBuilder
    private func imageBlock(src: String, rawIndex: Int) -> some View {
        if ArticleHtml.isExternal(src) {
            externalPlaceholder(src)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        } else {
            let url = ArticleImg.articleCover(src)
            if !url.isEmpty {
                Button {
                    onImageClick(rawIndex)
                } label: {
                    PosterImage(url: url, aspect: 16.0 / 9.0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)   // clickableNoRipple
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            // articleCover 解析为空 → 不渲染（与灯箱过滤口径一致）
        }
    }

    /// 外链图 16:9 虚线占位（文案两条逐字；点击系统浏览器打开，无浏览器/URI 无效静默忽略）
    private func externalPlaceholder(_ src: String) -> some View {
        Button {
            openExternally(src)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [9, 7]))
                    .foregroundColor(theme.line)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                VStack(spacing: 2) {
                    AppText("🔗 外链图", lvl: .bodyS)
                    AppText("点击在浏览器打开", lvl: .meta)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 系统 ACTION_VIEW 对位（主线程轻调用；失败静默）
    private func openExternally(_ src: String) {
        guard let u = URL(string: src.trimmingCharacters(in: .whitespaces)) else { return }
        UIApplication.shared.open(u, options: [:], completionHandler: nil)
    }
}
