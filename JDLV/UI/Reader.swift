import SwiftUI

//
//  Reader.swift —— 阅读器壳（10 §1 全节：ReaderStyleSheet 完整 Aa 弹层 + ReaderBody
//  渲染 + 阅读进度锚点；桌面端 _rebuild 移植口径）。
//
//  P9d 完整交互：
//  - 预设：RD_FONTS / RD_BGS / RD_FGS / RD_ALTS（label → 值逐字）。
//  - 默认值（Prefs）：rdFontPt=16、rdLineHeight=2.0、rdParagraph=1.0、rdFontFamily=""、
//    rdBgColor=""、rdFgColor=""、rdAlt=false、rdAltA=""、rdAltB="#9aa0ad"。
//  - clamp：字号 10..28（±2）、行距 1.2..3.0（±0.1）、段距 0.4..2.5（±0.1）。
//  - ReaderStyleSheet（顶栏 "Aa" 打开的底部弹层）：标题「阅读设置」Bold 15；调节按钮
//    A+/A-/行距+/行距-/段距+/段距-（34pt 高、12sp）；StyleRow（label 13sp 宽 90 +
//    FilterChip 12sp）字体/背景/字色；「段落交错色」Switch（开且色 B 空时默认 #9aa0ad）；
//    开启后追加「色A (偶数段)」「色B (奇数段)」（RD_ALTS）；底部留 28。
//  - ReaderStyleStore：rd_* 键经 SettingsStore.updateSettings 持久化（setter 先写 state
//    再落盘，不从 prefs 回读）。
//  - ReaderBody：容器圆角 10 + 背景色（rdBgColor，透明→不画）+ padding 12；
//    段距 gapDp = rdParagraph × rdFontPt × 1.333；文本块颜色优先级：块内 c >
//    交错色（偶 rdAltA / 奇 rdAltB，空回退主题字色）> rdFgColor（空→onSurface）；
//    b=="1"/"true" 加粗；字号 = rdFontPt × (sz>0 ? sz/15 : 1)；行高 = rdFontPt × rdLineHeight；
//    图片段前后各 6pt；altIndex 只对文本段自增（图片段不参与奇偶计数）。
//  - 首行缩进 2em：NSAttributedString + NSParagraphStyle.firstLineHeadIndent = 2 × 字号
//    （P9 校准： UILabel 承载，行距用 targetLineHeight − font.lineHeight 精确换算）。
//  - 阅读进度（滚动锚点）：progressTid 非空时每段挂 id("rd_blk_{i}") + 可见段跟踪
//    （LazyVStack onAppear/onDisappear），外层 onDisappear 存 UserDefaults（ReaderProgress），
//    重进 scrollTo("rd_blk_{n}", anchor: .top) 恢复。
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
    var uiFontDesign: Font.Design {
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

// MARK: - ReaderBody（正文渲染；P9d：精确首行缩进 + 进度锚点）

struct ReaderBody: View {
    var style: ReaderStyle
    let blocks: [ReaderBlock]
    /// 非空 → 启用阅读进度锚点（每段挂 id("rd_blk_{i}") + 可见段跟踪）
    var progressTid: String = ""
    /// 顶层可见段变化回调（外层 onDisappear 存 ReaderProgress；nil = 全部滚出）
    var onVisibleChange: ((Int?) -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var visibleBlocks: Set<Int> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { idx in
                blockView(blocks[idx], altIndex: altIndexOf(idx), idx: idx)
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
    private func blockView(_ block: ReaderBlock, altIndex: Int, idx: Int) -> some View {
        Group {
            if block.isImage {
                // 图片段：前后各 6pt，FillWidth 等宽显示
                PosterImage(url: block.i ?? "", aspect: 1.5)
                    .padding(.vertical, 6)
            } else if block.isText {
                textBlock(block, altIndex: altIndex)
            }
        }
        .id(progressTid.isEmpty ? nil : "rd_blk_\(idx)")
        .onAppear {
            guard !progressTid.isEmpty else { return }
            visibleBlocks.insert(idx)
            reportTop()
        }
        .onDisappear {
            guard !progressTid.isEmpty else { return }
            visibleBlocks.remove(idx)
            reportTop()
        }
    }

    private func reportTop() {
        onVisibleChange?(visibleBlocks.min())
    }

    private func textBlock(_ block: ReaderBlock, altIndex: Int) -> some View {
        let sz = block.sz ?? 0
        let pt = style.rdFontPt * (sz > 0 ? sz / 15.0 : 1)
        // 颜色优先级：块内 c > 交错色（偶 rdAltA / 奇 rdAltB，空回退）> rdFgColor > onSurface
        let color: UIColor = {
            if let c = ReaderStyle.parseColor(block.c ?? "") { return c }
            let altHex = altIndex % 2 == 0 ? style.rdAltA : style.rdAltB
            if style.rdAlt, let c = ReaderStyle.parseColor(altHex) { return c }
            if let c = ReaderStyle.parseColor(style.rdFgColor) { return c }
            return UIColor(theme.text)
        }()
        return ReaderParagraph(
            text: block.t ?? "",
            fontPt: CGFloat(pt),
            lineHeight: CGFloat(style.rdLineHeight),
            bold: block.isBold,
            design: style.uiFontDesign,
            color: color)
            // 段距（pt）= rdParagraph × rdFontPt × 1.333，加在每段 bottom（10 §1.4）
            .padding(.bottom, style.paragraphGapPt)
    }
}

// MARK: - 段落承载（UILabel + NSParagraphStyle：首行缩进 2em / 行高公式精确换算）

struct ReaderParagraph: UIViewRepresentable {
    let text: String
    let fontPt: CGFloat
    /// 行高倍数（行高 = rdFontPt × rdLineHeight）
    let lineHeight: CGFloat
    let bold: Bool
    let design: Font.Design
    let color: UIColor

    func makeUIView(context: Context) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        return l
    }

    func updateUIView(_ label: UILabel, context: Context) {
        let weight: UIFont.Weight = bold ? .bold : .regular
        let base = UIFont.systemFont(ofSize: fontPt, weight: weight)
        let font: UIFont
        switch design {
        case .serif:
            font = UIFont(descriptor: base.fontDescriptor.withDesign(.serif), size: fontPt)
        case .monospaced:
            font = UIFont(descriptor: base.fontDescriptor.withDesign(.monospaced), size: fontPt)
        default:
            font = base
        }
        let ps = NSMutableParagraphStyle()
        // 行高 = rdFontPt × rdLineHeight（三端口径）：lineSpacing = 目标行高 − 字体自然行高
        ps.lineSpacing = max(0, fontPt * lineHeight - font.lineHeight)
        // 首行缩进 2em（em = 字号）；正文行 headIndent 0
        ps.firstLineHeadIndent = fontPt * 2
        ps.headIndent = 0
        // 段距：单段一 Label → 段后间距由 SwiftUI 层 padding 承担（对齐 Android
        // 每 Text padding bottom）；此处恒 0 防单段双计
        ps.paragraphSpacing = 0
        ps.paragraphSpacingBefore = 0
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: ps,
            ])
    }
}

// MARK: - 阅读进度（滚动锚点；键 rd_pos_{tid}）

enum ReaderProgress {
    static func key(tid: String) -> String { "rd_pos_\(tid)" }

    /// 存顶层可见段索引（外层 onDisappear 调）
    static func save(tid: String, blockIndex: Int) {
        guard !tid.isEmpty else { return }
        UserDefaults.standard.set(blockIndex, forKey: key(tid))
    }

    /// 读锚点段索引（外层 onAppear 后 scrollTo("rd_blk_{n}", anchor: .top)）
    static func load(tid: String) -> Int? {
        guard !tid.isEmpty else { return nil }
        return UserDefaults.standard.object(forKey: key(tid)) as? Int
    }

    static func clear(tid: String) {
        guard !tid.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: key(tid))
    }
}

// MARK: - ReaderStyleStore（rd_* 设置持久化；setter 先写 state 再落盘，不从 prefs 回读）

@MainActor
final class ReaderStyleStore: ObservableObject {
    @Published var style: ReaderStyle
    private(set) weak var store: SettingsStore?

    /// init 从 SettingsStore 回读 rd_*（缺省 → ReaderStyle 默认值）
    init(store: SettingsStore? = nil) {
        self.store = store
        var s = ReaderStyle()
        if let d = store?.settings {
            s = Self.from(d)
        }
        self.style = s
    }

    /// 视图 onAppear 挂 SettingsStore（StateObject init 时环境尚不可用的对位）；
    /// 只在首次 attach 生效（不覆盖会话内已做的修改）
    func attach(_ store: SettingsStore?) {
        guard self.store == nil else { return }
        self.store = store
        if let d = store?.settings {
            style = Self.from(d)
        }
    }

    private static func from(_ d: AppSettings) -> ReaderStyle {
        var s = ReaderStyle()
        s.rdFontPt = Double(d.rdFontPt)
        s.rdLineHeight = Double(d.rdLineHeight)
        s.rdParagraph = Double(d.rdParagraph)
        s.rdFontFamily = d.rdFontFamily
        s.rdBgColor = d.rdBgColor
        s.rdFgColor = d.rdFgColor
        s.rdAlt = d.rdAlt
        s.rdAltA = d.rdAltA
        s.rdAltB = d.rdAltB
        return s
    }

    private func persist() {
        let s = style
        store?.updateSettings { d in
            d.rdFontPt = Int(s.rdFontPt)
            d.rdLineHeight = Float(s.rdLineHeight)
            d.rdParagraph = Float(s.rdParagraph)
            d.rdFontFamily = s.rdFontFamily
            d.rdBgColor = s.rdBgColor
            d.rdFgColor = s.rdFgColor
            d.rdAlt = s.rdAlt
            d.rdAltA = s.rdAltA
            d.rdAltB = s.rdAltB
        }
    }

    // 调节按钮（10 §1.3：范围 clamp 在 ReaderStyle 内）
    func fontUp() { style.fontUp(); persist() }
    func fontDown() { style.fontDown(); persist() }
    func lineUp() { style.lineUp(); persist() }
    func lineDown() { style.lineDown(); persist() }
    func paraUp() { style.paraUp(); persist() }
    func paraDown() { style.paraDown(); persist() }

    /// 单选行（值完全相等即选中；写 rdFontFamily/rdBgColor/rdFgColor）
    func setFontFamily(_ v: String) { style.rdFontFamily = v; persist() }
    func setBgColor(_ v: String) { style.rdBgColor = v; persist() }
    func setFgColor(_ v: String) { style.rdFgColor = v; persist() }
    func setAltA(_ v: String) { style.rdAltA = v; persist() }
    func setAltB(_ v: String) { style.rdAltB = v; persist() }

    /// 段落交错色 Switch（开且 rdAltB 空时自动补默认：rdAltA=""、rdAltB="#9aa0ad"）
    func setAlt(_ on: Bool) {
        if on { style.enableAlt() } else { style.rdAlt = false }
        persist()
    }
}

// MARK: - ReaderStyleSheet（10 §1.3：Aa 底部弹层，逐字文案）

struct ReaderStyleSheet: View {
    /// 外层持 ReaderStyleStore（跨弹层打开保持；持久化经 SettingsStore）
    @ObservedObject var rs: ReaderStyleStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("阅读设置")
                    .font(.system(size: 15, weight: .bold))   // Bold 15
                    .foregroundColor(theme.text)
                adjustRow
                styleRow("字体", options: ReaderStyle.fonts,
                         current: rs.style.rdFontFamily) { rs.setFontFamily($0) }
                styleRow("背景", options: ReaderStyle.bgs,
                         current: rs.style.rdBgColor) { rs.setBgColor($0) }
                styleRow("字色", options: ReaderStyle.fgs,
                         current: rs.style.rdFgColor) { rs.setFgColor($0) }
                altSwitchRow
                if rs.style.rdAlt {
                    styleRow("色A (偶数段)", options: ReaderStyle.alts,
                             current: rs.style.rdAltA) { rs.setAltA($0) }
                    styleRow("色B (奇数段)", options: ReaderStyle.alts,
                             current: rs.style.rdAltB) { rs.setAltB($0) }
                }
                Color.clear.frame(height: 28)   // 底部留 28
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.bg0.ignoresSafeArea())
        .presentationDetents([.medium, .large])   // ModalBottomSheet 对位，滑动可关闭
    }

    // MARK: 调节按钮行（FilledTonalButton 34pt、12sp；FlowRow 横排换行）

    private var adjustRow: some View {
        FlowLayout(spacing: 8) {
            adjustButton("A+") { rs.fontUp() }
            adjustButton("A-") { rs.fontDown() }
            adjustButton("行距+") { rs.lineUp() }
            adjustButton("行距-") { rs.lineDown() }
            adjustButton("段距+") { rs.paraUp() }
            adjustButton("段距-") { rs.paraDown() }
        }
    }

    private func adjustButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppText(label, lvl: .meta, color: theme.accent)
                .padding(.horizontal, 12)
                .frame(height: 34)   // FilledTonalButton 34dp
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.accent.opacity(0.35), lineWidth: ComponentMetrics.cardStroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: StyleRow（label 13sp 固定宽 90 + FilterChip 12sp FlowRow；选中 = 值完全相等）

    private func styleRow(_ label: String,
                          options: [(label: String, value: String)],
                          current: String,
                          onPick: @escaping (String) -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            AppText(label, lvl: .meta)
                .frame(width: 90, alignment: .leading)
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.value) { opt in
                    Button { onPick(opt.value) } label: {
                        AppText(opt.label, lvl: .meta,
                                color: current == opt.value ? theme.accent : theme.text,
                                fontWeight: current == opt.value ? .bold : .regular)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(current == opt.value
                                      ? theme.accent.opacity(0.2) : theme.bg1))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(current == opt.value ? theme.accent : theme.line,
                                        lineWidth: current == opt.value ? 1.5 : 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 开关行（段落交错色；13sp + Switch）

    private var altSwitchRow: some View {
        HStack(spacing: 8) {
            AppText("段落交错色", lvl: .meta)
                .frame(width: 90, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { rs.style.rdAlt },
                set: { rs.setAlt($0) }))
                .labelsHidden()
                .tint(theme.accent)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }
}
