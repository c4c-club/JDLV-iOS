import SwiftUI

//
//  CardShell.swift —— 设计系统 v2 卡片容器（13 §3.3：背景/描边/圆角/阴影/裁剪）。
//
//  契约：调用方通过 `.frame(width:height:)`（通常来自 CardGrid 的 cellW/cardH）
//  决定外壳尺寸；CardShell 对内容做 .clipShape，内容不得溢出（问题 5/6 根因：
//  背景按自然宽度绘制 + 外层 frame 不裁剪 → 互相压盖）。
//
//  视觉与旧 cardChrome 一致：bg1 底 + 1pt line 描边 + 圆角 12 + 2pt 投影。
//

struct CardShell<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content

    @Environment(\.appTheme) private var theme

    var body: some View {
        content()
            .padding(padding)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner).fill(theme.bg1))
            .overlay(
                RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner)
                    .stroke(theme.line, lineWidth: ComponentMetrics.cardStroke)
            )
            .clipShape(RoundedRectangle(cornerRadius: ComponentMetrics.cardCorner))
            .shadow(color: .black.opacity(0.12),
                    radius: ComponentMetrics.cardElevation,
                    y: ComponentMetrics.cardElevation / 2)
    }
}
