//
//  SettingsSectionsBrowse.swift
//  JDLV
//
//  P12：设置页 ⑤ 浏览与搜索（§8）/ ⑥ 语义搜索模型（§9）/ ⑦ 缓存（§10）/ ⑧ 关于（§12）。
//
//  - ⑥ 三步竖排导入（.fileImporter → 拷贝到 Application Support/semantic/，FileManager）+
//    高级折叠（默认收起；sem_threshold 走 updateSettings 轻量通道，emb_cache_mb 走 autoSave
//    并立即更新 EmbStore.maxBytes + prune 至 90%，S15-14）。
//  - ⑧ 关于：版本 CFBundleShortVersionString + 测试图片模式（仅 DEBUG 显示）；
//    开关切换清 TestImages 缓存即时生效，Toast 文案逐字；开启时挂 "testImageModeOn"
//    accessibilityIdentifier（P13 截图前置锚点）。
//

import SwiftUI
import UniformTypeIdentifiers
import JDLVCore

// MARK: - ⑤ 浏览与搜索 — key `browse`（§8 + 任务键清单）

struct BrowseSearchCard: View {


    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupBrowse,
            rememberKey: "browse",
            summary: SettingsCopy.summaryBrowse(s),
        ) {
            SettingsDropdownRow(label: SettingsCopy.viewModeLabel,
                                options: [
                                        DropdownOption(label: SettingsCopy.viewMode0, value: "0"), DropdownOption(label: SettingsCopy.viewMode1, value: "1"), DropdownOption(label: SettingsCopy.viewMode2, value: "2")],
                                current: "\(s.viewMode)") { v in
                selectInt(v) { $0.viewMode = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.coverHalfLabel,
                                options: [
                                        DropdownOption(label: SettingsCopy.coverHalf0, value: "0"), DropdownOption(label: SettingsCopy.coverHalf1, value: "1"), DropdownOption(label: SettingsCopy.coverHalf2, value: "2")],
                                current: "\(s.coverHalf)") { v in
                selectInt(v) { $0.coverHalf = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.lookupScopeLabel,
                                options: [
                                        DropdownOption(label: SettingsCopy.lookupScope0, value: "0"), DropdownOption(label: SettingsCopy.lookupScope1, value: "1")],
                                current: "\(s.lookupScope)") { v in
                selectInt(v) { $0.lookupScope = $1 }
            }
            AppSwitchRow(label: SettingsCopy.shadowPreferLabel,
                         checked: s.shadowPrefer,
                         hint: SettingsCopy.shadowPreferDesc) { v in
                editNow { $0.shadowPrefer = v }
            }
            SettingsDropdownRow(label: SettingsCopy.searchModeLabel,
                                options: [
                                        DropdownOption(label: SettingsCopy.searchMode0, value: "0"), DropdownOption(label: SettingsCopy.searchMode1, value: "1")],
                                current: "\(s.searchMode)") { v in
                selectInt(v) { $0.searchMode = $1 }
            }
            // jdb_sort + jdb_sort_asc（S11-P2：asc 不纳入 dbChanged）
            SettingsDropdownRow(label: SettingsCopy.jdbSortLabel,
                                options: [
                                        DropdownOption(label: "发布日期", value: "release_date"), DropdownOption(label: "评分", value: "score"), DropdownOption(label: "年份", value: "year")],
                                current: s.jdbSort) { v in
                editNow { $0.jdbSort = v }
            }
            AppSwitchRow(label: SettingsCopy.jdbSortAscLabel,
                         checked: s.jdbSortAsc,
                         hint: SettingsCopy.jdbSortAscDesc) { v in
                editNow { $0.jdbSortAsc = v }
            }
            // actor_sort / actor_gender
            SettingsDropdownRow(label: SettingsCopy.actorSortLabel,
                                options: [
                                        DropdownOption(label: "出演数", value: "videos"), DropdownOption(label: "人气", value: "popularity"), DropdownOption(label: "均分", value: "avg_score_all")],
                                current: s.actorSort) { v in
                editNow { $0.actorSort = v }
            }
            SettingsDropdownRow(label: SettingsCopy.actorGenderLabel,
                                options: [
                                        DropdownOption(label: "女", value: "f"), DropdownOption(label: "男", value: "m"), DropdownOption(label: "全部", value: "a")],
                                current: s.actorGender) { v in
                editNow { $0.actorGender = v }
            }
            // sht_has_magnet
            AppSwitchRow(label: SettingsCopy.shtHasMagnetLabel,
                         checked: s.shtHasMagnet) { v in
                editNow { $0.shtHasMagnet = v }
            }
            SettingsDropdownRow(label: SettingsCopy.perPageLabel,
                                options: intOptions([20, 40, 60, 80, 100]),
                                current: "\(s.perPage)") { v in
                selectInt(v) { $0.perPage = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.homePerLabel,
                                options: intOptions([12, 18, 24, 36]),
                                current: "\(s.homePer)") { v in
                selectInt(v) { $0.homePer = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.shtPerLabel,
                                options: intOptions([20, 40, 60, 80, 100]),
                                current: "\(s.shtPer)") { v in
                selectInt(v) { $0.shtPer = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.semCandLabel,
                                options: intOptions([3000, 10000, 50000]),
                                current: "\(s.semCand)") { v in
                selectInt(v) { $0.semCand = $1 }
            }

            SettingsNote(text: SettingsCopy.semCandNote(s.semCand), topPad: 2)
        }
    }

    private func intOptions(_ vs: [Int]) -> [DropdownOption] {
        vs.map { DropdownOption(label: "\($0)", value: "\($0)") }
    }

    private func selectInt(_ v: String, _ set: @escaping (inout AppSettings, Int) -> Void) {
        guard let n = Int(v) else { return }
        editNow { set(&$0, n) }
    }

    private func editNow(_ t: @escaping SettingsTransform) {
        Task { await store.editNow(t) }
    }
}

// MARK: - 语义模型文件（导入：拷贝到 Application Support/semantic/，FileManager）

enum SemanticImport {

    static let dirName = "semantic"
    static let modelFileName = "model.onnx"
    static let tokFileName = "tokenizer.json"

    static func directory(create: Bool = false) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(dirName, isDirectory: true)
        if create {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static var modelURL: URL { directory().appendingPathComponent(modelFileName) }
    static var tokURL: URL { directory().appendingPathComponent(tokFileName) }

    /// 两文件都存在且非空
    static func isInstalled() -> Bool {
        fileSize(modelURL) > 0 && fileSize(tokURL) > 0
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 覆盖式拷贝（security-scoped 读取；失败抛错给调用方拼 "导入失败: …"）
    static func install(model: URL, tokenizer: URL) throws {
        let fm = FileManager.default
        directory(create: true)
        for (src, dst) in [(model, modelURL), (tokenizer, tokURL)] {
            var scoped = false
            if src.startAccessingSecurityScopedResource() {
                scoped = true
            }
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            guard fm.fileExists(atPath: src.path) else {
                throw NSError(domain: "SemanticImport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "无法读取所选文件"])
            }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }
    }
}

// MARK: - ⑥ 语义搜索模型 — key `semantic`（§9 逐字）

struct SemanticModelCard: View {


    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var installed = false
    @State private var modelPick: URL? = nil
    @State private var tokPick: URL? = nil
    @State private var showModelPicker = false
    @State private var showTokPicker = false
    @State private var busy = false
    @State private var resultText = ""
    @State private var advanced = false
    @State private var embInfo = SettingsCopy.embInfoLoading
    @State private var confirmClearEmbs = false

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupSemantic,
            rememberKey: "semantic",
            summary: SettingsCopy.summarySemantic(installed: installed),
        ) {
            statusLine

            SettingsActionButton(title: modelPick == nil ? SettingsCopy.semStep1Idle
                                                         : SettingsCopy.semStep1Done) {
                showModelPicker = true
            }
            SettingsNote(text: SettingsCopy.semStep1Hint)

            SettingsActionButton(title: tokPick == nil ? SettingsCopy.semStep2Idle
                                                       : SettingsCopy.semStep2Done) {
                showTokPicker = true
            }
            SettingsNote(text: SettingsCopy.semStep2Hint)

            SettingsActionButton(title: busy ? SettingsCopy.semStep3Busy : SettingsCopy.semStep3Idle,
                                 busy: busy,
                                 enabled: modelPick != nil && tokPick != nil) {
                install()
            }
            SettingsNote(text: SettingsCopy.semStep3Hint)

            if !resultText.isEmpty {
                SettingsNote(text: resultText, topPad: 4)
            }

            advancedHeader
            if advanced {
                // sem_threshold：updateSettings 轻量通道（不触发副作用）
                SettingsDropdownRow(label: SettingsCopy.semThresholdLabel,
                                    options: [
                                        DropdownOption(label: SettingsCopy.semThreshold5, value: "5"), DropdownOption(label: SettingsCopy.semThreshold10, value: "10"), DropdownOption(label: SettingsCopy.semThreshold20, value: "20")],
                                    current: "\(s.semThreshold)") { v in
                    if let n = Int(v) {
                        store.updateSettings { $0.semThreshold = n }
                    }
                }
                // emb_cache_mb：autoSave 通道 + 立即更新 EmbStore（S15-14）
                SettingsDropdownRow(label: SettingsCopy.embCacheLabel,
                                    options: [
                                        DropdownOption(label: "50 MB", value: "50"), DropdownOption(label: "100 MB", value: "100"), DropdownOption(label: "200 MB", value: "200"), DropdownOption(label: "不限", value: "0")],
                                    current: "\(s.embCacheMb)") { v in
                    if let n = Int(v) {
                        Task {
                            _ = await store.autoSave { $0.embCacheMb = n }
                            SettingsIndexHub.shared.applyEmbBudget(mb: n)
                        }
                    }
                }
                AppText(embInfo, lvl: .meta, color: theme.text2)
                SettingsActionButton(title: SettingsCopy.embClearButton) {
                    confirmClearEmbs = true
                }
            }
        }
        .fileImporter(isPresented: $showModelPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            modelPick = try? result.get().first
        }
        .fileImporter(isPresented: $showTokPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            tokPick = try? result.get().first
        }
        .alert("清空向量缓存?", isPresented: $confirmClearEmbs) {
            Button(SettingsCopy.cancelButtonText, role: .cancel) {}
            Button(SettingsCopy.embClearButton, role: .destructive) {
                clearEmbs()
            }
        } message: {
            Text("将删除全部本地缓存向量 (下次语义搜索重新拉取), 不可恢复。")
        }
        .onAppear {
            installed = SemanticImport.isInstalled()
            refreshEmbInfo()
        }
        .onChange(of: installed) { _ in refreshEmbInfo() }
    }

    // MARK: 状态行 / 高级折叠头

    @ViewBuilder
    private var statusLine: some View {
        if installed {
            AppText(SettingsCopy.semStatus(installed: true), lvl: .bodyS, color: theme.accent)
        } else {
            AppText(SettingsCopy.semStatus(installed: false), lvl: .bodyS, color: theme.text2)
        }
    }

    private var advancedHeader: some View {
        Button {
            withAnimation { advanced.toggle() }
        } label: {
            HStack {
                AppText(SettingsCopy.semAdvancedHeader, lvl: .bodyS)
                Spacer()
                Image(systemName: advanced ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.text2)
            }
            .frame(minHeight: ComponentMetrics.buttonMin, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 导入（③）/ 清空

    private func install() {
        guard let m = modelPick, let t = tokPick, !busy else { return }
        busy = true
        resultText = ""
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SemanticImport.install(model: m, tokenizer: t)
                }.value
                busy = false
                installed = SemanticImport.isInstalled()
                let mSize = SemanticImport.fileSize(SemanticImport.modelURL)
                let tSize = SemanticImport.fileSize(SemanticImport.tokURL)
                resultText = String(format: "model.onnx %.1f MB · tokenizer.json %.1f MB",
                                    Double(mSize) / 1_048_576.0, Double(tSize) / 1_048_576.0)
                AppServices.shared.showToast(SettingsCopy.semImportOkToast)
            } catch {
                busy = false
                let msg = (error as? CustomStringConvertible)?.description ?? "未知错误"
                resultText = SettingsCopy.semImportFailToast(msg)
                AppServices.shared.showToast(SettingsCopy.semImportFailToast(msg))
            }
        }
    }

    private func clearEmbs() {
        SettingsIndexHub.shared.clearEmbs()
        embInfo = SettingsCopy.embClearedInfo
        AppServices.shared.showToast(SettingsCopy.embClearToast)
    }

    private func refreshEmbInfo() {
        guard installed else { return }
        // R5 P3：EmbStore 懒开 + 统计离主线程（embStatsAsync 内部 detached；@MainActor 只登记）
        Task { @MainActor in
            if let st = await SettingsIndexHub.shared.embStatsAsync() {
                embInfo = SettingsCopy.embInfoLine(st.count, bytes: st.bytes)
            }
        }
    }
}

// MARK: - ⑦ 缓存 — key `cache`（§10 逐字）

struct CacheCard: View {


    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupCache,
            rememberKey: "cache",
            summary: SettingsCopy.summaryCache(s),
        ) {
            SettingsDropdownRow(label: SettingsCopy.homeTtlLabel,
                                options: ttlOptions,
                                current: "\(s.homeTtl)") { v in
                selectInt(v) { $0.homeTtl = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.catTtlLabel,
                                options: ttlOptions,
                                current: "\(s.catTtl)") { v in
                selectInt(v) { $0.catTtl = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.filterTtlLabel,
                                options: ttlOptions,
                                current: "\(s.filterTtl)") { v in
                selectInt(v) { $0.filterTtl = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.imageCacheMbLabel,
                                options: [
                                        DropdownOption(label: "128 MB", value: "128"), DropdownOption(label: "256 MB", value: "256"), DropdownOption(label: "512 MB", value: "512"), DropdownOption(label: "1 GB", value: "1024"), DropdownOption(label: "2 GB", value: "2048")],
                                current: "\(s.imageCacheMb)") { v in
                selectInt(v) { $0.imageCacheMb = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.imageCacheDaysLabel,
                                options: [
                                        DropdownOption(label: SettingsCopy.imageCacheNever, value: "0"), DropdownOption(label: "7 天", value: "7"), DropdownOption(label: "15 天", value: "15"), DropdownOption(label: "30 天", value: "30"), DropdownOption(label: "60 天", value: "60")],
                                current: "\(s.imageCacheDays)") { v in
                selectInt(v) { $0.imageCacheDays = $1 }
            }

            // 按钮行（两枚并排）
            HStack(spacing: 8) {
                SettingsActionButton(title: SettingsCopy.clearQueryButton) {
                    SettingsDiagnostics.clearQueryCache()
                    AppServices.shared.showToast(SettingsCopy.clearQueryToast)
                }
                SettingsActionButton(title: SettingsCopy.sweepImageButton) {
                    let n = SettingsDiagnostics.sweepImageCache(days: store.settings.imageCacheDays)
                    AppServices.shared.showToast(SettingsCopy.sweepImageToast(n))
                }
            }
            .padding(.top, 2)
        }
    }

    private var ttlOptions: [DropdownOption] {
        [0, 5, 10, 30, 60].map { DropdownOption(label: "\($0)", value: "\($0)") }
    }

    private func selectInt(_ v: String, _ set: @escaping (inout AppSettings, Int) -> Void) {
        guard let n = Int(v) else { return }
        Task { await store.editNow { set(&$0, n) } }
    }
}

// MARK: - ⑧ 关于 — key `about`（§12 逐字）

