//
//  SettingsSectionsOffline.swift
//  JDLV
//
//  P12：设置页 ⑦ 离线索引（§11 逐字；S13-P3 自定义上限 + 预热进度 + 继续/暂停/重建/清理）。
//
//  - 开关即时生效：开 → sync.start("switch", force: true)；关 → sync.stopAndJoin()。
//  - 上限 IndexLimitRow + IndexLimitDialog（万/条输入 + 快捷档 + 0=不限"不限"文案）+
//    裁剪二次确认 AlertDialog + applyIndexLimit 五种 Toast（SettingsDiagnostics.applyLimitToast）。
//  - 预估体积长文案（标签数×5.7 公式）/ 实际占用（IdxDb.usageBytes(fast:false) 含 WAL 定时刷新）/
//    进度区（SyncCoordinator.state 全字段 1s 定时刷新）/ 四按钮 2×2。
//  - 二次确认 AlertDialog 文案逐字（重建/清理）；demo 模式按钮只返回假结果（"演示模式"标注）。
//

import SwiftUI
import JDLVCore

// MARK: - ⑦ 离线索引 — key `shadow`（§11）

struct OfflineIndexCard: View {

    @ObservedObject var bus: SaveStateBus

    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    /// 进度快照（1s 定时刷新）
    @State private var st = SyncState()
    @State private var usageText = SettingsCopy.usagePendingText
    @State private var usagePending = false
    @State private var loadedOnce = false

    // IndexLimitDialog
    @State private var limitTarget: LimitTarget? = nil
    @State private var rebuildConfirm = false
    @State private var clearConfirm = false

    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum LimitTarget: String, Identifiable {
        case jdb, sht
        var id: String { rawValue }
        var title: String {
            self == .jdb ? SettingsCopy.limitDialogTitleJdb : SettingsCopy.limitDialogTitleSht
        }
    }

    var body: some View {
        let view = store.settings   // 权威值（B04：摘要/上限行/进度读 view）
        SettingsGroupCard(
            title: SettingsCopy.groupShadow,
            rememberKey: "shadow",
            summary: SettingsCopy.summaryShadow(view),
            bus: bus
        ) {
            settingsBlock(view)
            tagEstimateNote(view)
            estimateNote(view)
            usageBlock
            progressBlock(view)
            buttonsGrid
        }
        .onAppear {
            guard !loadedOnce else { return }
            loadedOnce = true
            // B06/B22：进卡片刷新统计与实际占用
            SettingsIndexHub.shared.sync?.refreshStats()
            recalcUsage()
        }
        .onReceive(tickTimer) { _ in
            st = SettingsIndexHub.shared.sync?.state ?? SyncState()
        }
        // 重建二次确认 AlertDialog（§11.7 逐字）
        .alert(SettingsCopy.rebuildTitle, isPresented: $rebuildConfirm) {
            Button(SettingsCopy.cancelButtonText, role: .cancel) {}
            Button(SettingsCopy.rebuildConfirmButton, role: .destructive) { runRebuild() }
        } message: {
            Text(SettingsCopy.rebuildBody(lj: view.shadowLimitJdb, ls: view.shadowLimitSht))
        }
        // 清理二次确认 AlertDialog（§11.7 逐字）
        .alert(SettingsCopy.clearTitle, isPresented: $clearConfirm) {
            Button(SettingsCopy.cancelButtonText, role: .cancel) {}
            Button(SettingsCopy.clearConfirmButton, role: .destructive) { runClear() }
        } message: {
            Text(SettingsCopy.clearBody)
        }
        // 上限对话框（jdb/98t 复用）
        .sheet(item: $limitTarget) { target in
            IndexLimitDialog(
                title: target.title,
                currentLimit: target == .jdb ? view.shadowLimitJdb : view.shadowLimitSht,
                currentCount: {
                    guard let sync = SettingsIndexHub.shared.sync else { return 0 }
                    let table = target == .jdb ? "idx_movies" : "idx_threads"
                    return (try? sync.idx.countOf(table: table)) ?? 0
                },
                onApply: { nv in applyIndexLimit(target: target, nv: nv) })
        }
    }

    // MARK: 11.1 设置项

    private func settingsBlock(_ s: AppSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AppSwitchRow(label: SettingsCopy.shadowEnabledLabel,
                         checked: s.shadowEnabled,
                         hint: SettingsCopy.shadowEnabledDesc) { v in
                editNow {
                    $0.shadowEnabled = v
                }
                // 开关即时生效（S13-P3：避免异步落盘竞态）
                Task {
                    if v {
                        _ = SettingsIndexHub.shared.sync?.start(trigger: "switch", force: true)
                    } else {
                        await SettingsIndexHub.shared.sync?.stopAndJoin()
                    }
                }
            }
            SettingsDropdownRow(label: SettingsCopy.shadowModeLabel,
                                options: [
                                        DropdownOption(label: SettingsCopy.shadowMode1, value: "1"), DropdownOption(label: SettingsCopy.shadowMode0, value: "0")],
                                current: "\(s.shadowMode)") { v in
                editNow { $0.shadowMode = Int(v) ?? 1 }
            }
            indexLimitRow(label: SettingsCopy.shadowLimitJdbLabel,
                          value: s.shadowLimitJdb, target: .jdb)
            indexLimitRow(label: SettingsCopy.shadowLimitShtLabel,
                          value: s.shadowLimitSht, target: .sht)
            AppSwitchRow(label: SettingsCopy.shadowActorLabel,
                         checked: s.shadowActorIndex,
                         hint: SettingsCopy.shadowActorDesc) { v in
                editNow {
                    $0.shadowActorIndex = v
                    $0.shadowActorLinks = v   // 两键联动（§11.1）
                }
            }
            AppSwitchRow(label: SettingsCopy.shadowTagLabel,
                         checked: s.shadowTagIndex,
                         hint: SettingsCopy.shadowTagDesc) { v in
                editNow { $0.shadowTagIndex = v }
            }
        }
    }

    private func indexLimitRow(label: String, value: Int, target: LimitTarget) -> some View {
        SettingsLabeledRow(label: label) {
            HStack(spacing: 6) {
                AppText(LimitMath.format(value), lvl: .bodyS, color: theme.accent)
                Spacer(minLength: 4)
                SettingsTextButton(title: SettingsCopy.editLimitButtonText,
                                   minHeight: ComponentMetrics.touchMin) {
                    limitTarget = target
                }
                .frame(width: 56)
            }
        }
    }

    // MARK: 11.2/11.3 预估

    private func tagEstimateNote(_ s: AppSettings) -> some View {
        let e = SettingsCopy.tagEstimateText(limitJdb: s.shadowLimitJdb)
        return SettingsNote(text: e.text, color: e.warn ? theme.accent2 : theme.text2)
    }

    private func estimateNote(_ s: AppSettings) -> some View {
        SettingsNote(text: SettingsCopy.estimateText(limitJdb: s.shadowLimitJdb,
                                                     limitSht: s.shadowLimitSht,
                                                     actorIndex: s.shadowActorIndex))
    }

    // MARK: 11.4 实际占用

    private var usageBlock: some View {
        HStack(alignment: .center, spacing: 8) {
            AppText(usageText, lvl: .meta, color: theme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsActionButton(title: usagePending ? SettingsCopy.recalcBusyText
                                                     : SettingsCopy.recalcButton,
                                 busy: usagePending,
                                 minHeight: 36) {
                recalcUsage()
            }
            .frame(width: 96)
        }
    }

    private func recalcUsage() {
        usagePending = true
        guard let sync = SettingsIndexHub.shared.sync else {
            usagePending = false
            usageText = SettingsCopy.usageText(idxMb: 0, detailMb: 0)
            return
        }
        let idx = sync.idx
        Task.detached(priority: .utility) {
            let bytes = idx.usageBytes(fast: false)
            await MainActor.run {
                usagePending = false
                usageText = SettingsCopy.usageText(idxMb: Double(bytes) / 1_048_576.0, detailMb: 0)
            }
        }
    }

    // MARK: 11.6 进度区

    @ViewBuilder
    private func progressBlock(_ s: AppSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AppText(SettingsCopy.indexedLine(movies: st.movies, threads: st.threads,
                                             actors: st.actors, actorTotal: st.actorTotal,
                                             limitJdb: s.shadowLimitJdb,
                                             limitSht: s.shadowLimitSht),
                    lvl: .meta, color: theme.text2)
            if st.running || st.movies > 0 || st.threads > 0 {
                Group {
                    if s.shadowLimitJdb > 0 {
                        ProgressView(value: min(max(Double(st.movies) / Double(s.shadowLimitJdb), 0), 1))
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .frame(minHeight: 4)
            }
            AppText(SettingsCopy.roundLine(phase: st.phase, speed: st.speedPerMin,
                                           eta: SettingsCopy.etaText(st.etaSec),
                                           note: st.note),
                    lvl: .meta, color: theme.text2)
            AppText(SettingsCopy.lastNextLine(last: st.lastRunAt, next: st.nextRunAt),
                    lvl: .meta, color: theme.text2)
            if !st.lastError.isEmpty {
                AppText(SettingsCopy.errorLine(st.lastError), lvl: .meta, color: theme.red)
            }
        }
        .padding(.top, 2)
    }

    // MARK: 11.7 四按钮（2×2）

    private var buttonsGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SettingsActionButton(title: "继续索引") { runResume() }
                SettingsActionButton(title: "暂停") { runPause() }
            }
            HStack(spacing: 8) {
                SettingsActionButton(title: "重建索引") { rebuildConfirm = true }
                SettingsActionButton(title: "清理") { clearConfirm = true }
            }
        }
        .padding(.top, 4)
    }

    private func runResume() {
        if SettingsDiagnostics.isDemo {
            AppServices.shared.showToast("✓ 继续索引已启动 (从断点续跑)（演示模式）")
            return
        }
        let r = SettingsIndexHub.shared.sync?.resume() ?? .DISABLED
        AppServices.shared.showToast(SettingsDiagnostics.resumeToast(r))
    }

    private func runPause() {
        if SettingsDiagnostics.isDemo { return }
        Task { await SettingsIndexHub.shared.sync?.stopAndJoin() }
    }

    private func runRebuild() {
        AppServices.shared.showToast(SettingsCopy.rebuildStartToast)
        if SettingsDiagnostics.isDemo {
            AppServices.shared.showToast(SettingsCopy.rebuildStartedToast + "（演示模式）")
            return
        }
        let s = store.settings
        Task {
            await SettingsIndexHub.shared.sync?.rebuild(limitJdb: s.shadowLimitJdb,
                                                        limitSht: s.shadowLimitSht)
            AppServices.shared.showToast(SettingsCopy.rebuildStartedToast)
            SettingsIndexHub.shared.sync?.refreshStats()
            recalcUsage()
        }
    }

    private func runClear() {
        if SettingsDiagnostics.isDemo {
            AppServices.shared.showToast(SettingsCopy.clearDoneToast + "（演示模式）")
            return
        }
        Task {
            await SettingsIndexHub.shared.sync?.clearAll()
            AppServices.shared.showToast(SettingsCopy.clearDoneToast)
            SettingsIndexHub.shared.sync?.refreshStats()
            recalcUsage()
        }
    }

    // MARK: 11.9 applyIndexLimit

    private func applyIndexLimit(target: LimitTarget, nv: Int) {
        let cur = store.settings
        let prevM = cur.shadowLimitJdb
        let prevT = cur.shadowLimitSht
        let lj = target == .jdb ? nv : prevM
        let ls = target == .sht ? nv : prevT
        let wasRunning = SettingsIndexHub.shared.sync?.isRunning() ?? false
        bus.markSaving()
        if SettingsDiagnostics.isDemo {
            Task {
                _ = await store.updateSettingsNow { s in
                    s.shadowLimitJdb = lj
                    s.shadowLimitSht = ls
                }
                AppServices.shared.showToast("✓ 上限已更新，正在按新上限收敛（演示模式）")
            }
            return
        }
        Task {
            if lj == prevM && ls == prevT {
                let r = SettingsIndexHub.shared.sync?
                    .applyLimits(prevM: prevM, prevT: prevT, nextM: prevM, nextT: prevT) ?? .NO_CHANGE
                AppServices.shared.showToast(
                    SettingsDiagnostics.applyLimitToast(result: r, wasRunning: wasRunning, offline: false))
                return
            }
            // 值变化：先落盘（等待完成）再热更新目标（≤5s 生效）
            _ = await store.updateSettingsNow { s in
                s.shadowLimitJdb = lj
                s.shadowLimitSht = ls
            }
            let r = SettingsIndexHub.shared.sync?
                .applyLimits(prevM: prevM, prevT: prevT, nextM: lj, nextT: ls) ?? .NO_CHANGE
            let offline = Db.offlineJdb || Db.offlineSht
            AppServices.shared.showToast(
                SettingsDiagnostics.applyLimitToast(result: r, wasRunning: wasRunning, offline: offline))
            SettingsIndexHub.shared.sync?.refreshStats()
        }
    }

    private func editNow(_ t: @escaping SettingsTransform) {
        bus.markSaving()
        Task { await store.editNow(t) }
    }
}

// MARK: - 11.8 IndexLimitDialog（jdb/98t 复用）

struct IndexLimitDialog: View {

    let title: String
    let currentLimit: Int
    let currentCount: () -> Int64
    let onApply: (Int) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var input: String = ""
    @State private var wan = true
    @State private var indexedCount: Int64 = 0
    @State private var availText = ""
    @State private var trimConfirm = false

    private let quickWans = [2, 5, 8, 15, 30, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppText(title, lvl: .bodyS, fontWeight: .semibold)

            CompactField(text: $input, placeholder: Self.phLimitInput,
                         keyboard: .numbersAndPunctuation) { _ in }

            // 单位切换（万支持 1 位小数）
            HStack(spacing: 6) {
                AppToggleChip(label: SettingsCopy.limitUnitWan, selected: wan) { switchUnit(toWan: true) }
                AppToggleChip(label: SettingsCopy.limitUnitCount, selected: !wan) { switchUnit(toWan: false) }
                Spacer()
            }

            // 快捷档（单行横向滚动）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickWans, id: \.self) { w in
                        AppToggleChip(label: "\(w)万", selected: false) {
                            wan = true
                            input = "\(w)"
                        }
                    }
                    AppToggleChip(label: SettingsCopy.limitUnlimitedChip, selected: false) {
                        wan = true
                        input = "0"
                    }
                }
            }

            AppText(SettingsCopy.limitIndexedCount(indexedCount), lvl: .meta, color: theme.text2)
            AppText(realtimeLine, lvl: .meta, color: theme.text2)

            if n != nil, n! > 2_000_000 {
                AppText(SettingsCopy.limitWarnText, lvl: .meta, color: theme.accent2)
            }
            if invalid {
                AppText(SettingsCopy.limitInvalidText, lvl: .meta, color: theme.red)
            }
            if trimCount > 0 {
                AppText(SettingsCopy.limitTrimPreview(trimCount), lvl: .meta, color: theme.accent2)
            }

            HStack(spacing: 8) {
                SettingsActionButton(title: SettingsCopy.okButtonText,
                                     enabled: !invalid, filled: true) {
                    confirmPressed()
                }
                SettingsActionButton(title: SettingsCopy.cancelButtonText) {
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.bg1.ignoresSafeArea())
        .presentationDetents([.height(470)])
        .onAppear {
            indexedCount = currentCount()
            // 初始输入：cur ≤ 0 → ""；整万 → "cur/10000"；否则 cur
            if currentLimit <= 0 {
                input = ""
                wan = true
            } else if currentLimit % 10000 == 0 {
                input = "\(currentLimit / 10000)"
                wan = true
            } else {
                input = "\(currentLimit)"
                wan = false
            }
            availText = availabilityText()
        }
        // 裁剪二次确认 AlertDialog（§11.8 逐字）
        .alert(SettingsCopy.trimConfirmTitle, isPresented: $trimConfirm) {
            Button(SettingsCopy.cancelButtonText, role: .cancel) {}
            Button(SettingsCopy.trimConfirmButton, role: .destructive) {
                applyAndDismiss()
            }
        } message: {
            Text(SettingsCopy.trimConfirmBody(current: indexedCount, keep: n ?? 0))
        }
    }

    private static let phLimitInput = "输入数量"

    // MARK: 派生值

    /// 万 → parseWan（1 位小数）；条 → parseCount（纯整数）
    private var n: Int64? {
        wan ? LimitMath.parseWan(input) : LimitMath.parseCount(input)
    }

    private var invalid: Bool { !LimitMath.isValid(n) }

    /// 裁剪预告：currentCount > 0 且 1 ≤ n < currentCount
    private var trimCount: Int64 {
        guard let v = n, v >= 1, indexedCount > 0, v < indexedCount else { return 0 }
        return indexedCount - v
    }

    private var realtimeLine: String {
        let est = SettingsCopy.limitEstText(n: n)
        return SettingsCopy.limitRealtimeLine(n: n, est: est, avail: availText)
    }

    // MARK: 动作

    private func switchUnit(toWan: Bool) {
        guard toWan != wan else { return }
        if let v = n {
            if toWan {
                // 条→万：整万取整，否则 1 位小数
                input = v % 10000 == 0 ? "\(v / 10000)" : String(format: "%.1f", Double(v) / 10000.0)
            } else {
                input = "\(v)"
            }
        }
        wan = toWan
    }

    private func confirmPressed() {
        guard !invalid else { return }
        if trimCount > 0 {
            trimConfirm = true
        } else {
            applyAndDismiss()
        }
    }

    private func applyAndDismiss() {
        let v = Int(truncatingIfNeeded: min((n ?? 0), Int64(Int.max)))
        dismiss()
        onApply(v)
    }

    /// 设备可用空间（StatFs 对位：卷可用容量 → "N GB"；不可得 → 空串）
    private func availabilityText() -> String {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = vals.volumeAvailableCapacityForImportantUsage, bytes > 0 else { return "" }
        return "设备可用 \(String(format: "%.0f", Double(bytes) / 1_073_741_824.0)) GB"
    }
}
