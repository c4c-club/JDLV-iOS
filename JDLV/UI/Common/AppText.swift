import SwiftUI

//
//  AppText.swift —— 全 App 唯一文本出口（07 §全局排版契约 / theme/Type.kt 对位）。
//
//  - 五级 Tx：TitleL 20/28 Bold、TitleM 16/22 SemiBold、Body 15/22、BodyS 13/19、
//    Meta 12/17（Meta 默认色 onSurfaceVariant，其余 onSurface）。
//  - 最小 12pt；禁止对文字做 alpha<0.9 降透明（唯一例外：列表"已读"标题 60%，
//    由调用方显式传 theme.text.opacity(0.6)，本组件不做任何自动降透明）。
//  - Android lineHeight 对位：SwiftUI 无直接行高 API，用 lineSpacing(lineHeight -
//    fontSize) 近似（追加行间距口径，两端视觉一致；与桌面端 _rebuild 口径一致的
//    倍数换算只在 Reader 段落里做精确值）。
//

/// 文本组件（Android `AppText(text, lvl, color, maxLines, minLines, overflow,
/// textAlign, fontWeight, textDecoration)` 对位；overflow 恒为截断省略）。
struct AppText: View {
    let text: String
    var lvl: Tx = .body
    /// nil → 按 lvl 默认（Meta → onSurfaceVariant / 其余 onSurface）
    var color: Color? = nil
    var maxLines: Int = Int.max
    /// minLines 占位（两行占位等高，ShtCard 标题用；iOS 16 lineLimit(reservesSpace:)）
    var minLines: Int = 0
    var textAlign: TextAlignment = .leading
    /// 覆盖 lvl 默认字重（如 Meta Medium）
    var fontWeight: Font.Weight? = nil
    var underline: Bool = false

    @Environment(\.appTheme) private var theme

    init(_ text: String,
         lvl: Tx = .body,
         color: Color? = nil,
         maxLines: Int = Int.max,
         minLines: Int = 0,
         textAlign: TextAlignment = .leading,
         fontWeight: Font.Weight? = nil,
         underline: Bool = false) {
        self.text = text
        self.lvl = lvl
        self.color = color
        self.maxLines = maxLines
        self.minLines = minLines
        self.textAlign = textAlign
        self.fontWeight = fontWeight
        self.underline = underline
    }

    /// 解析后的默认色（Meta → text2 / 其余 text）
    private var resolvedColor: Color {
        color ?? (lvl == .meta ? theme.text2 : theme.text)
    }

    private var base: some View {
        Text(text)
            .font(.system(size: lvl.size, weight: fontWeight ?? lvl.weight))
            .lineSpacing(max(0, lvl.lineHeight - lvl.size))
            .foregroundColor(resolvedColor)
            .multilineTextAlignment(textAlign)
            .underline(underline, color: resolvedColor)
    }

    var body: some View {
        if minLines > 0 {
            base.lineLimit(minLines, reservesSpace: true)
        } else if maxLines == Int.max {
            base
        } else {
            base.lineLimit(maxLines)
        }
    }
}
