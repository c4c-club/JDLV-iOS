import Foundation
import SwiftUI

//
//  AppServices.swift —— App 壳全局状态（07 A5：横幅与 Toast；MainVm.showToast 对位）。
//
//  - toast：全局单一 Toast 通道（showSnackbar Short ≈ 2s 后 clearToast）。
//  - offlineJdb / offlineSht：离线横幅按库粒度（javdb / 98t 拼接，不是全局开关）。
//  - restored：恢复横幅（离线→在线后只提示不自动重拉），showRestored() 里 6 秒
//    Task.sleep 自消（07 A5 / 10 §0.1：显示 6000ms，不触发列表自动重拉）。
//
//  P8 只建状态与驱动；离线判定/netEpoch 联动（SettingsStore.bumpNet）在 P9 数据层接入。
//

@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    /// 全局 Toast（VM 侧 showToast 写入，页面无需订阅）
    @Published var toast: String?
    /// javdb 库离线（横幅分段一）
    @Published var offlineJdb = false
    /// 98t 库离线（横幅分段二）
    @Published var offlineSht = false
    /// 离线→在线恢复横幅可见（6 秒自消）
    @Published var restored = false

    private var toastTask: Task<Void, Never>?
    private var restoredTask: Task<Void, Never>?

    private init() {}

    // MARK: offlineLabel（按库拼接；都离线 → "javdb · 98t"）

    var offlineLabel: String {
        var parts: [String] = []
        if offlineJdb { parts.append("javdb") }
        if offlineSht { parts.append("98t") }
        return parts.joined(separator: " · ")
    }

    // MARK: Toast

    /// 全局 Toast（Short ≈ 2s 自动清位）
    func showToast(_ msg: String) {
        toastTask?.cancel()
        toast = msg
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearToast()
        }
    }

    /// 页面消费后清位（对齐 Android clearToast）
    func clearToast() {
        toastTask?.cancel()
        toastTask = nil
        if toast != nil { toast = nil }
    }

    // MARK: 恢复横幅（6 秒自消）

    /// 离线→在线后调用：只更新横幅，绝不自动重拉列表
    func showRestored() {
        restoredTask?.cancel()
        restored = true
        restoredTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ComponentMetrics.restoredBannerMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.restored = false
        }
    }
}
