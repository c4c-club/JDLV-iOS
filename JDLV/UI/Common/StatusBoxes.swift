import SwiftUI

//
//  StatusBoxes.swift —— 空/错态唯一控件（07 B5/B6、10 §0.2、08 A.6）。
//
//  - ErrorBox(text, detail, onRetry)：全屏 Column(padding 24, 居中)：
//    「⚠️」TitleL → 8pt → text（BodyS，error 色，居中）→ detail 非空取前 300 字
//    （Meta，top 8，maxLines 4 省略）→ onRetry 非空：图标 16pt + 6pt + 「重试」
//    （FilledTonalButton 风格，top 16，minHeight 48）。
//  - EmptyBox(text, hint, actionText, onAction)：同布局，图标固定「🗂」。
//  - 错误文案来自 ErrText（真实原因），调用方原文透传，本组件不改写。
//

/// 错误态（AppError 对位）。
struct ErrorBox: View {
    let text: String
    var detail: String = ""
    var onRetry: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            AppText(AppCopy.errorIcon, lvl: .titleL)
            Spacer().frame(height: 8)
            AppText(text, lvl: .bodyS, color: theme.red, textAlign: .center)
            if !detail.isEmpty {
                AppText(String(detail.prefix(300)), lvl: .meta, maxLines: 4, textAlign: .center)
                    .padding(.top, 8)
            }
            if onRetry != nil {
                Button {
                    onRetry?()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16))
                        AppText(AppCopy.retryButton, lvl: .bodyS,
                                color: theme.accent, fontWeight: .medium)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: ComponentMetrics.buttonMin)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.15)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 空态（AppEmpty 对位；图标固定 🗂）。
struct EmptyBox: View {
    let text: String
    var hint: String = ""
    var actionText: String = ""
    var onAction: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            AppText(AppCopy.emptyIcon, lvl: .titleL)
            Spacer().frame(height: 8)
            AppText(text, lvl: .bodyS, textAlign: .center)
            if !hint.isEmpty {
                AppText(hint, lvl: .meta, textAlign: .center)
                    .padding(.top, 8)
            }
            if !actionText.isEmpty && onAction != nil {
                Button {
                    onAction?()
                } label: {
                    AppText(actionText, lvl: .bodyS, color: theme.accent, fontWeight: .medium)
                        .padding(.horizontal, 16)
                        .frame(minHeight: ComponentMetrics.buttonMin)
                        .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 全屏居中转圈（07 B3 LoadingBox）。
struct LoadingBox: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            ProgressView().progressViewStyle(.circular)
        }
    }
}
