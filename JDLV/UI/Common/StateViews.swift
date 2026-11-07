import SwiftUI

//
//  StateViews.swift —— 设计系统 v2 状态视图（13 §3.3：SF Symbol + 标题 + 说明 + 按钮）。
//
//  iOS 16 无 ContentUnavailableView（iOS 17+），自绘同构语义。
//  与既有 StatusBoxes.swift（EmptyBox/ErrorBox/LoadingBox）并存：新页面统一用
//  StateViews；StatusBoxes 保留给未迁移页面，R12 前不删除。
//

struct LoadingState: View {
    var title: String = "加载中"
    var hint: String = ""

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
            AppText(title, lvl: .bodyS, color: theme.text2)
            if !hint.isEmpty {
                AppText(hint, lvl: .meta, color: theme.text2, textAlign: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("state_loading")
    }
}

struct EmptyState: View {
    let title: String
    var hint: String = ""
    var systemImage: String = "tray"
    var actionTitle: String = ""
    var onAction: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundColor(theme.text2.opacity(0.7))
            AppText(title, lvl: .body, color: theme.text2)
            if !hint.isEmpty {
                AppText(hint, lvl: .meta, color: theme.text2, textAlign: .center)
                    .padding(.horizontal, 24)
            }
            if !actionTitle.isEmpty, let onAction {
                Button(action: onAction) {
                    AppText(actionTitle, lvl: .bodyS, color: theme.accent, fontWeight: .medium)
                        .padding(.horizontal, 16)
                        .frame(minHeight: ComponentMetrics.touchMin)
                        .background(Capsule().fill(theme.accent.opacity(0.15)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("state_empty")
    }
}

struct ErrorState: View {
    let message: String
    var onRetry: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundColor(theme.yellow)
            AppText(message, lvl: .bodyS, color: theme.text2, textAlign: .center)
                .padding(.horizontal, 24)
            if let onRetry {
                Button(action: onRetry) {
                    AppText("重试", lvl: .bodyS, color: .white, fontWeight: .medium)
                        .padding(.horizontal, 24)
                        .frame(minHeight: ComponentMetrics.touchMin)
                        .background(Capsule().fill(theme.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("state_error")
    }
}
