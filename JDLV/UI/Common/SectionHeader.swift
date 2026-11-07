import SwiftUI

//
//  SectionHeader.swift —— 设计系统 v2 段头（13 §3.3：标题 + 可选「查看全部」）。
//
//  与 HomeView 现 homeSection 段头同视觉（titleM 标题 + meta accent「查看全部」），
//  抽成组件供 16 页复用；触控高 ≥ touchMin。
//

struct SectionHeader: View {
    let title: String
    var actionTitle: String = ""
    var onAction: (() -> Void)? = nil
    /// accessibilityIdentifier 前缀（如 viewall_recent）
    var actionId: String = ""

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            AppText(title, lvl: .titleM)
            Spacer(minLength: 8)
            if !actionTitle.isEmpty, let onAction {
                Button(action: onAction) {
                    AppText(actionTitle, lvl: .meta, color: theme.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: ComponentMetrics.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(actionId.isEmpty ? "section_action" : actionId)
            }
        }
        .padding(.horizontal, ComponentMetrics.pageMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
