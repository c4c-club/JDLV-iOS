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

    @ObservedObject var bus: SaveStateBus

    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupBrowse,
            rememberKey: "browse",
            summary: SettingsCopy.summaryBrowse(s),
            bus: bus
        ) {
            SettingsDropdownRow(label: SettingsCopy.viewModeLabel,
                                options: [(SettingsCopy.viewMode0, "0"),
                                          (SettingsCopy.viewMode1, "1"),
                                          (SettingsCopy.viewMode2, "2")],
                                current: "\(s.viewMode)") { v in
                selectInt(v) { $0.viewMode = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.coverHalfLabel,
                                options: [(SettingsCopy.coverHalf0, "0"),
                                          (SettingsCopy.coverHalf1, "1"),
                                          (SettingsCopy.coverHalf2, "2")],
                                current: "\(s.coverHalf)") { v in
                selectInt(v) { $0.coverHalf = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.lookupScopeLabel,
                                options: [(SettingsCopy.lookupScope0, "0"),
                                          (SettingsCopy.lookupScope1, "1")],
                                current: "\(s.lookupScope)") { v in
                selectInt(v) { $0.lookupScope = $1 }
            }
            AppSwitchRow(label: SettingsCopy.shadowPreferLabel,
                         checked: s.shadowPrefer,
                         hint: SettingsCopy.shadowPreferDesc) { v in
                editNow { $0.shadowPrefer = v }
            }
            SettingsDropdownRow(label: SettingsCopy.searchModeLabel,
                                options: [(SettingsCopy.searchMode0, "0"),
                                          (SettingsCopy.searchMode1, "1")],
                                current: "\(s.searchMode)") { v in
                selectInt(v) { $0.searchMode = $1 }
            }
            // jdb_sort + jdb_sort_asc（S11-P2：asc 不纳入 dbChanged）
            SettingsDropdownRow(label: SettingsCopy.jdbSortLabel,
                                options: [("发布日期", "release_date"),
                                          ("评分", "score"),
                                          ("年份", "year")],
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
                                options: [("出演数", "videos"),
                                          ("人气", "popularity"),
                                          ("均分", "avg_score_all")],
                                current: s.actorSort) { v in
                editNow { $0.actorSort = v }
            }
            SettingsDropdownRow(label: SettingsCopy.actorGenderLabel,
                                options: [("女", "f"), ("男", "m"), ("全部", "a")],
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
        bus.markSaving()
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

    @ObservedObject var bus: SaveStateBus

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
            bus: bus
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
                                    options: [(SettingsCopy.semThreshold5, "5"),
                                              (SettingsCopy.semThreshold10, "10"),
                                              (SettingsCopy.semThreshold20, "20")],
                                    current: "\(s.semThreshold)") { v in
                    if let n = Int(v) {
                        bus.markSaving()
                        store.updateSettings { $0.semThreshold = n }
                    }
                }
                // emb_cache_mb：autoSave 通道 + 立即更新 EmbStore（S15-14）
                SettingsDropdownRow(label: SettingsCopy.embCacheLabel,
                                    options: [("50 MB", "50"), ("100 MB", "100"),
                                              ("200 MB", "200"), ("不限", "0")],
                                    current: "\(s.embCacheMb)") { v in
                    if let n = Int(v) {
                        bus.markSaving()
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
        let st = SettingsIndexHub.shared.embStats()
        if let st {
            embInfo = SettingsCopy.embInfoLine(st.count, bytes: st.bytes)
        }
    }
}

// MARK: - ⑦ 缓存 — key `cache`（§10 逐字）

struct CacheCard: View {

    @ObservedObject var bus: SaveStateBus

    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupCache,
            rememberKey: "cache",
            summary: SettingsCopy.summaryCache(s),
            bus: bus
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
                                options: [("128 MB", "128"), ("256 MB", "256"),
                                          ("512 MB", "512"), ("1 GB", "1024"),
                                          ("2 GB", "2048")],
                                current: "\(s.imageCacheMb)") { v in
                selectInt(v) { $0.imageCacheMb = $1 }
            }
            SettingsDropdownRow(label: SettingsCopy.imageCacheDaysLabel,
                                options: [(SettingsCopy.imageCacheNever, "0"),
                                          ("7 天", "7"), ("15 天", "15"),
                                          ("30 天", "30"), ("60 天", "60")],
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
        bus.markSaving()
        Task { await store.editNow { set(&$0, n) } }
    }
}

// MARK: - ⑧ 关于 — key `about`（§12 逐字）

struct AboutCard: View {

    @ObservedObject var bus: SaveStateBus

    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupAbout,
            rememberKey: "about",
            summary: SettingsCopy.summaryAbout,
            bus: bus
        ) {
            AppText(SettingsCopy.aboutVersion(version), lvl: .bodyS)
            SettingsNote(text: SettingsCopy.aboutDesc, topPad: 2)

            // 测试图片模式（仅可调试构建显示）
            #if DEBUG
            AppSwitchRow(label: SettingsCopy.testImgLabel,
                         checked: s.testImgMode,
                         hint: SettingsCopy.testImgDesc) { v in
                toggleTestImg(v)
            }
            .accessibilityIdentifier("about_testimg_switch")
            if s.testImgMode {
                // P13 截图前置锚点：测试图片模式开启即出现
                AppText("✓ 测试图片模式生效中", lvl: .meta, color: theme.accent)
                    .accessibilityIdentifier("testImageModeOn")
            }
            #endif
        }
    }

    /// 开关副作用：清测试图缓存（rebuildImageLoader 对位）即时生效 + Toast 逐字
    private func toggleTestImg(_ v: Bool) {
        bus.markSaving()
        Task {
            _ = await store.editNow { $0.testImgMode = v }
            TestImages.clearCache()
            AppServices.shared.showToast(v ? SettingsCopy.testImgOnToast : SettingsCopy.testImgOffToast)
        }
    }
}
