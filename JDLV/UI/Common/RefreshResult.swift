import SwiftUI

//
//  RefreshResult.swift —— 刷新结果通道（08 C.6：VM ↔ 页面契约）。
//
//  Android 语义：VM 在 fetch 结束（成功/失败/走 stale）时写入，**只有手动下拉
//  （fromRefresh = force && !auto）才写**；页面 `LaunchedEffect(st.refreshResult)`
//  消费 → Toast → `consumeRefreshResult()` 清位。修复了旧版"空列表首刷
//  refreshing 恒 false → 无提示"。
//
//  iOS 对位：P9 各列表 VM 持有 `RefreshResultChannel`（@Published value），
//  页面 `onChange(of: channel.value)` 消费弹 Toast 后调 `consume()` 清位。
//

/// 刷新结果（等价 Android `sealed class RefreshResult { Done(n); Fail(msg) }`）
enum RefreshResult: Equatable {
    /// 成功：n = 合并后已加载总条数（merged.size）
    case done(Int)
    /// 失败：msg 来自 ErrText（原文透传，不得改成通用"出错了"）
    case fail(String)

    /// 页面消费侧 Toast 文案（07 C0）：
    /// Done → "✓ 刷新完成 · 共 {n} 条"；Fail → "刷新失败：{msg 前 40 字}"
    var toastText: String {
        switch self {
        case .done(let n): return AppCopy.refreshDoneToast(n)
        case .fail(let msg): return AppCopy.refreshFailToast(msg)
        }
    }
}

/// VM 侧通道载体（@Published 单槽位 + consume 清位）
@MainActor
final class RefreshResultChannel: ObservableObject {
    @Published private(set) var value: RefreshResult?

    /// VM 写位（仅手动下拉刷新路径；筛选变化/翻页/自动刷新不写）
    func emit(_ r: RefreshResult) { value = r }

    /// 页面消费后清位
    func consume() { value = nil }
}
