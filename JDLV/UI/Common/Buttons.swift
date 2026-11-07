import SwiftUI

//
//  Buttons.swift —— 设计系统 v2 主/次按钮（13 §3.3：48pt 高、圆角 12、accent 填充/描边）。
//

struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            AppText(title, lvl: .bodyS, color: .white, fontWeight: .medium)
                .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                .background(RoundedRectangle(cornerRadius: Radius.card)
                    .fill(enabled ? theme.accent : theme.accent.opacity(0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String = ""
    var action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundColor(theme.accent)
                }
                AppText(title, lvl: .bodyS, color: theme.accent, fontWeight: .medium)
            }
            .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(theme.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card)
                .stroke(theme.accent.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Radius token（13 §3.2；Theme.swift 在 JDLVCore 不可依赖 SwiftUI 层，放此处）

/// 设计系统 v2 圆角 token：card 12 / image 10 / chip 8 / sheet 16。
enum Radius {
    static let card: CGFloat = 12
    static let image: CGFloat = 10
    static let chip: CGFloat = 8
    static let sheet: CGFloat = 16
}
