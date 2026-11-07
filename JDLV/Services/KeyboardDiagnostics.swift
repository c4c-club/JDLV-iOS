import UIKit
import SwiftUI

//
//  KeyboardDiagnostics.swift —— 输入法诊断（R3 问题 1）。
//
//  iOS 平台限制：App 无法编程指定第三方输入法（搜狗/百度）；keyboardType 只能决定
//  键盘类型。诊断页展示 UITextInputMode.activeInputModes 的 primaryLanguage/identifier
//  + 手动切换路径说明（地球键 / iOS 设置添加键盘）。
//

enum KeyboardDiagnostics {
    struct ModeInfo: Equatable {
        let identifier: String
        let primaryLanguage: String
        /// 当前激活键盘数（含系统英文/中文等）
    }

    /// 当前激活输入法快照（UI 侧主线程调用）
    static var activeModes: [ModeInfo] {
        UITextInputMode.activeInputModes.compactMap { m in
            guard let m = m as? UITextInputMode else { return nil }
            let id = (m.value(forKey: "identifier") as? String) ?? String(describing: type(of: m))
            let lang = m.primaryLanguage ?? "unknown"
            return ModeInfo(identifier: id, primaryLanguage: lang)
        }
    }

    /// 一行摘要（诊断日志用）
    static var activeModesDescription: String {
        activeModes.map { "\($0.identifier) [\($0.primaryLanguage)]" }.joined(separator: ", ")
    }

    /// iOS 限制说明（逐字）
    static let limitNotice =
        "iOS 不允许 App 指定第三方输入法；请用键盘左下角地球键切换到搜狗。若列表中没有搜狗，请到 iOS 设置 → 通用 → 键盘 → 键盘 → 添加新键盘。"
}

/// 关于 → 输入法诊断子页
struct KeyboardDiagnosticsView: View {
    @State private var modes: [KeyboardDiagnostics.ModeInfo] = []

    var body: some View {
        Form {
            Section("当前激活输入法") {
                if modes.isEmpty {
                    Text("（快照为空 — 进入本页时无键盘激活是正常现象）")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                ForEach(Array(modes.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.identifier).font(.system(size: 13))
                        Text("primaryLanguage: \(m.primaryLanguage)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                Button("刷新快照") { modes = KeyboardDiagnostics.activeModes }
                    .font(.system(size: 13))
            }
            Section("iOS 输入法说明") {
                Text(KeyboardDiagnostics.limitNotice)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Section {
                Button("打开本 App 系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.system(size: 13))
                Text("iOS 无法从 App 直达键盘设置页；请手动前往 设置 → 通用 → 键盘。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("输入法诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { modes = KeyboardDiagnostics.activeModes }
    }
}
