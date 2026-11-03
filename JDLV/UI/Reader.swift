import SwiftUI

//
//  Reader.swift —— 阅读器壳（P8 范围：ReaderStyleSheet 数据模型 + ReaderBody 基础渲染；
//  10 §1.2/§1.3/§1.4，桌面端 _rebuild 移植口径）。
//
//  本阶段不做 Aa 底部弹层 UI（98t 帖子详情页 P9 接入）；样式模型、预设表（逐字）、
//  clamp 范围、默认值与 ReaderBody 渲染规则先落位：
//  - 预设：RD_FONTS / RD_BGS / RD_FGS / RD_ALTS（label → 值逐字）。
//  - 默认值（Prefs）：rdFontPt=16、rdLineHeight=2.0、rdParagraph=1.0、rdFontFamily=""、
//    rdBgColor=""、rdFgColor=""、rdAlt=false、rdAltA=""、rdAltB="#9aa0ad"。
//  - clamp：字号 10..28（±2）、行距 1.2..3.0（±0.1）、段距 0.4..2.5（±0.1）。
//  - ReaderBody：容器圆角 10 + 背景色（rdBgColor，透明→不画）+ padding 12；
//    段距 gapDp = rdParagraph × rdFontPt × 1.333；文本块颜色优先级：块内 c >
//    交错色（偶 rdAltA / 奇 rdAltB，空回退主题字色）> rdFgColor（空→onSurface）；
//    b=="1"/"true" 加粗；字号 = rdFontPt × (sz>0 ? sz/15 : 1)；行高 = rdFontPt × rdLineHeight；
//    图片段前后各 6pt；altIndex 只对文本段自增（图片段不参与奇偶计数）。
//  - 首行缩进 2em：P8 基础渲染用两个全角空格近似；精确 NSAttributedString headIndent
//    留 P9 校准（移植注意原文允许 NSAttributedString 或自绘）。
//  - parseColor：仅接受长度 7 且 # 开头，否则 nil（严格 7 位 hex）——本文件自带
//    UIColor 解析，不依赖 Theme 的 Color(hex:)（该入口按 8 位含 alpha 语义解析）。
//

import UIKit

// MARK: - ReaderStyleSheet 数据模型

/// 阅读样式（ReaderStyleSheet 的状态模型；键名对齐 Prefs rd* 字段）。
struct ReaderStyle: Equatable {
    var rdFontPt: Double = 16
    var rdLineHeight: Double = 2.0
    var rdParagraph: Double = 1.0
    var rdFontFamily: String = ""
    var rdBgColor: String = ""
    var rdFgColor: String = ""
    var rdAlt: Bool = false
    var rdAltA: String = ""
    var rdAltB: String = "#9aa0ad"

    // MARK: 预设表（10 §1.2，label → 值逐字）

    static let fonts: [(label: String, value: String)] = [
        ("默认", ""), ("衬线·宋", "serif"), ("无衬线·黑", "sans"), ("等宽", "mono"),
    ]
    static let bgs: [(label: String, value: String)] = [
        ("跟随主题", ""), ("纯黑", "#0b0d10"), ("深灰", "#1c1f26"),
        ("米黄", "#f6efdc"), ("浅绿", "#e9f1e6"), ("纯白", "#ffffff"),
    ]
    static let fgs: [(label: String, value: String)] = [
        ("跟随主题", ""), ("白", "#e6e6e6"), ("黑", "#1f1f1f"),
        ("深棕", "#43391f"), ("墨绿", "#2c4a38"), ("深蓝", "#223a52"),
    ]
    static let alts: [(label: String, value: String)] = [
        ("跟随字色", ""), ("白", "#e6e6e6"), ("灰", "#9aa0ad"), ("米黄", "#d9caa3"),
        ("绿", "#7bbf8e"), ("蓝", "#7aa5d8"), ("粉", "#d88fb0"), ("黑", "#1f1f1f"),
        ("深棕", "#43391f"), ("深蓝", "#223a52"),
    ]

    // MARK: 调节（ReaderStyleSheet 按钮；范围 clamp）

    /// 「A+」字号 +2（10..28）
    mutating func fontUp() { rdFontPt = min(max(rdFontPt + 2, 10), 28) }
    /// 「A-」字号 -2
    mutating func fontDown() { rdFontPt = min(max(rdFontPt - 2, 10), 28) }
    /// 「行距+」+0.1（1.2..3.0）
    mutating func lineUp() { rdLineHeight = min(max(rdLineHeight + 0.1, 1.2), 3.0) }
    /// 「行距-」
    mutating func lineDown() { rdLineHeight = min(max(rdLineHeight - 0.1, 1.2), 3.0) }
    /// 「段距+」+0.1（0.4..2.5）
    mutating func paraUp() { rdParagraph = min(max(rdParagraph + 0.1, 0.4), 2.5) }
    /// 「段距-」
    mutating func paraDown() { rdParagraph = min(max(rdParagraph - 0.1, 0.4), 2.5) }

    /// 开启交错色且色 B 为空时补默认：rdAltA=""（跟随字色）、rdAltB="#9aa0ad"（灰）
    mutating func enableAlt() {
        rdAlt = true
        if rdAltB.isEmpty { rdAltB = "#9aa0ad" }
        if rdAltA.isEmpty { rdAltA = "" }
    }

    // MARK: 解析

    /// 段距（pt）= rdParagraph × rdFontPt × 1.333
    var paragraphGapPt: CGFloat { CGFloat(rdParagraph * rdFontPt * 1.333) }

    /// 字体映射（serif→Serif、mono→Monospace、sans→默认系统、其他/空→Default）
    var uiFontDesign: UIFont.Design {
        switch rdFontFamily {
        case "serif": return .serif
        case "mono": return .monospaced
        default: return .default
        }
    }

    /// parseColor：仅接受长度 7 且 # 开头（严格 7 位 hex，否则 nil 回退默认色）
    static func parseColor(_ hex: String) -> UIColor? {
        guard hex.count == 7, hex.hasPrefix("#"),
              let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255.0,
                       green: CGFloat((v >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(v & 0xFF) / 255.0,
                       alpha: 1)
    }
}

// MARK: - 正文块（blocks JSON：键 t/i/b/c/al/sz）

struct ReaderBlock: Equatable, Codable {
    /// 文本段
    var t: String?
    /// 图片段 URL
    var i: String?
    /// 加粗（"1"/"true"）
    var b: String?
    /// 块内显式颜色
    var c: String?
    /// 预留键（ShtDetail D3 blocks 键集）
    var al: String?
    /// 相对字号基准（>0 时字号 = rdFontPt × sz / 15）
    var sz: Double?

    var isBold: Bool { b == "1" || b?.lowercased() == "true" }
    var isText: Bool { !(t ?? "").isEmpty }
    var isImage: Bool { !(i ?? "").isEmpty }
}

// MARK: - ReaderBody（正文渲染，基础版）

struct ReaderBody: View {
    var style: ReaderStyle
    let blocks: [ReaderBlock]

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { idx in
                blockView(blocks[idx], altIndex: altIndexOf(idx))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundLayer)
        .clipShape(RoundedRectangle(cornerRadius: ComponentMetrics.imageCorner))
    }

    /// 背景色：rdBgColor 透明/非法 → 不画（跟随主题）
    private var backgroundLayer: some View {
        Group {
            if let c = ReaderStyle.parseColor(style.rdBgColor) {
                Color(c)
            } else {
                Color.clear
            }
        }
    }

    /// altIndex 只对文本段自增（图片段不参与奇偶计数）
    private func altIndexOf(_ idx: Int) -> Int {
        blocks[..<idx].filter { $0.isText }.count
    }

    @ViewBuilder
    private func blockView(_ block: ReaderBlock, altIndex: Int) -> some View {
        if block.isImage {
            // 图片段：前后各 6pt，FillWidth 等宽显示
            PosterImage(url: block.i ?? "", aspect: 1.5)
                .padding(.vertical, 6)
        } else if block.isText {
            textBlock(block, altIndex: altIndex)
        }
    }

    private func textBlock(_ block: ReaderBlock, altIndex: Int) -> some View {
        let sz = block.sz ?? 0
        let pt = style.rdFontPt * (sz > 0 ? sz / 15.0 : 1)
        // 颜色优先级：块内 c > 交错色（偶 rdAltA / 奇 rdAltB，空回退）> rdFgColor > onSurface
        let color: Color = {
            if let c = ReaderStyle.parseColor(block.c ?? "") { return Color(c) }
            let altHex = altIndex % 2 == 0 ? style.rdAltA : style.rdAltB
            if style.rdAlt, let c = ReaderStyle.parseColor(altHex) { return Color(c) }
            if let c = ReaderStyle.parseColor(style.rdFgColor) { return Color(c) }
            return theme.text
        }()
        // 首行缩进 2em（P8 基础渲染：全角空格近似；精确 headIndent 留 P9）
        let body_ = "　　" + (block.t ?? "")
        return Text(body_)
            .font(.system(size: CGFloat(pt),
                          weight: block.isBold ? .bold : .regular,
                          design: Font.Design(style.uiFontDesign)))
            .lineSpacing(CGFloat(pt * (style.rdLineHeight - 1.0)))
            .foregroundColor(color)
            .padding(.bottom, style.paragraphGapPt)
    }
}

// MARK: - UIFont.Design → SwiftUI Font.Design 桥（保持模型层无 UIKit 依赖外泄）

private extension Font.Design {
    init(_ d: UIFont.Design) {
        switch d {
        case .serif: self = .serif
        case .monospaced: self = .monospace
        case .rounded: self = .rounded
        default: self = .default
        }
    }
}
