import Foundation

//
//  SaveState.swift —— 全局保存状态模型（13 §2.4/§5.4：替换每卡 SaveStateBus）。
//
//  六条写通道（updateSettings/updateSettingsNow/autoSave/edit/editNow/flushPendingEdits
//  /applyLockChange/applyLimitChange/saveAndSniff）统一：入口 .saving → 出口
//  .saved/.noChange/.failed；5 秒 watchdog 超时 .failed("保存超时")（R8 接线）。
//

enum SaveState: Equatable {
    case idle
    case saving(Date)
    case saved(Date)
    case noChange(Date)
    case failed(String, Date)

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}

import SwiftUI

//
//  SaveStatusView —— 全局唯一保存状态行（SettingsView 顶部一条；各卡不再挂）。
//
//  saving → ProgressView + 「保存中…」；saved → 「已保存 HH:mm:ss」绿；
//  noChange → 「无变化」灰；failed → 红 + 「重试」。
//

struct SaveStatusView: View {
    let state: SaveState
    var onRetry: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case .idle:
                EmptyView()
            case .saving:
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(width: 12, height: 12)
                AppText("保存中…", lvl: .meta, color: theme.text2)
            case .saved(let at):
                AppText("已保存 \(Self.time(at))", lvl: .meta, color: .saveOk)
            case .noChange(let at):
                AppText("无变化 \(Self.time(at))", lvl: .meta, color: theme.text2)
            case .failed(let msg, _):
                AppText(msg, lvl: .meta, color: theme.red)
                if let onRetry {
                    Button(action: onRetry) {
                        AppText("重试", lvl: .meta, color: theme.accent, fontWeight: .medium)
                            .padding(.horizontal, 8)
                            .frame(minHeight: ComponentMetrics.touchMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("settings_save_state")
        .animation(.easeInOut(duration: 0.2), value: state)
    }

    /// R4 P10：formatter 复用（DateFormatter iOS7+ 线程安全）
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func time(_ d: Date) -> String {
        fmt.string(from: d)
    }
}

private extension Color {
    /// 已保存绿（与旧 SaveStateLine 的 0x2E7D32 一致）
    static let saveOk = Color(red: 0x2E / 255.0, green: 0x7D / 255.0, blue: 0x32 / 255.0)
}
