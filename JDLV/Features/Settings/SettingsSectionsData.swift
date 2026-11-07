//
//  SettingsSectionsData.swift
//  JDLV
//
//  P12：设置页 ① 数据源（§2）与 ② 网络与代理（§3）两张分组卡。
//
//  - 文本输入走 store.edit（800ms 防抖变换链）；开关/选择走 store.editNow（立即落盘）。
//  - editingOther：编辑另一数据源时 ConnFields 显示另一侧字段，不影响当前连接。
//  - 测试连接（① 与 ② 共用）：SettingsDiagnostics.testConnection —— connLock 串行、
//    两库各建连一次；成功（✓ 开头）时 clearOffline + Db.reset + bumpData + Toast。
//

import SwiftUI
import JDLVCore

// MARK: - ① 数据源 (改完自动保存) — key `db`（§2 逐字）

struct DataSourceCard: View {

    var firstRun: Bool = false
    @ObservedObject var bus: SaveStateBus

    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var loaded = false
    @State private var editingOther = false

    // 两侧字段草稿（输入即时回显；落盘走 store.edit 变换链）
    @State private var localHost = ""
    @State private var localPort = ""
    @State private var localUser = ""
    @State private var localPass = ""
    @State private var localJdb = ""
    @State private var localSht = ""
    @State private var remoteHost = ""
    @State private var remotePort = ""
    @State private var remoteUser = ""
    @State private var remotePass = ""
    @State private var remoteJdb = ""
    @State private var remoteSht = ""

    @State private var showPlain = false
    @State private var testing = false
    @State private var testResult = ""

    /// 当前 ConnFields 显示侧：编辑另一数据源时显示另一侧
    private var curSide: String {
        if editingOther {
            return store.settings.dbSrc == "remote" ? "local" : "remote"
        }
        return store.settings.dbSrc
    }

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupDb,
            rememberKey: "db",
            defaultExpanded: firstRun || s.user.isEmpty,   // 唯一自动展开例外（§0.3）
            summary: SettingsCopy.summaryDb(s),
            bus: bus
        ) {
            SettingsSegmented(label: SettingsCopy.dsLabelSource,
                              options: [("本地库", "local"), ("远程库", "remote")],
                              current: s.dbSrc) { v in
                selectSource(v)
            }

            connFields(curSide)

            // A7/R7：口令读取失败显式提示（绝不静默当空口令连库）
            if store.secretReadFailed {
                SettingsNote(text: "口令读取失败：\(store.secretReadMessage) — 请重新输入口令",
                             topPad: 4, color: .red)
                    .accessibilityIdentifier("settings_secret_read_failed")
            }

            if editingOther {
                SettingsNote(text: SettingsCopy.dsEditingOtherHint, topPad: 2)
            }
            SettingsTextButton(title: editingOther ? SettingsCopy.dsBackCurrent
                                                   : SettingsCopy.dsEditOther) {
                editingOther.toggle()
            }

            AppSwitchRow(label: SettingsCopy.dsTlsLabel,
                         checked: s.dbSsl,
                         hint: SettingsCopy.dsTlsDesc) { v in
                editNow { $0.dbSsl = v }
            }

            // connect_timeout 档位 chips 4/8/15/30（任务键清单；文档 §2 无此行）
            SettingsSegmented(label: SettingsCopy.dsConnTimeoutLabel,
                              options: [("4 秒", "4"), ("8 秒", "8"), ("15 秒", "15"), ("30 秒", "30")],
                              current: connectTimeoutCurrent,
                              showLabel: true) { v in
                if let n = Int(v) { editNow { $0.connectTimeout = n } }
            }

            SettingsDropdownRow(label: "查询超时",
                                options: queryTimeoutOptions,
                                current: "\(s.queryTimeout)") { v in
                if let n = Int(v) { editNow { $0.queryTimeout = n } }
            }

            SettingsNote(text: SettingsCopy.dsTestIsolationNote, topPad: 4)

            SettingsActionButton(title: SettingsCopy.dsTestButton,
                                 busyTitle: SettingsCopy.dsTestingText,
                                 busy: testing,
                                 id: "ds_test_button") {
                runTest()
            }

            if !testResult.isEmpty {
                SettingsNote(text: testResult, topPad: 6)
                    .accessibilityIdentifier("settings_test_result")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            loadDraft(s)
        }
    }

    private var connectTimeoutCurrent: String {
        [4, 8, 15, 30].contains(store.settings.connectTimeout)
            ? "\(store.settings.connectTimeout)" : ""
    }

    private var queryTimeoutOptions: [DropdownOption] {
        [DropdownOption(label: "4 秒", value: "4"),
         DropdownOption(label: "8 秒 (推荐)", value: "8"),
         DropdownOption(label: "15 秒", value: "15"),
         DropdownOption(label: "30 秒", value: "30")]
    }

    // MARK: ConnFields（§2：主机/端口/用户/密码/jdb 库名/98t 库名 × local/remote）

    @ViewBuilder
    private func connFields(_ side: String) -> some View {
        let isLocal = side == "local"
        SettingsLabeledRow(label: SettingsCopy.dsLabelHost) {
            CompactField(text: isLocal ? $localHost : $remoteHost,
                         placeholder: SettingsCopy.dsPhHost) { v in
                editDebounced { if isLocal { $0.localHost = v } else { $0.remoteHost = v } }
            }
        }
        SettingsLabeledRow(label: SettingsCopy.dsLabelPort) {
            CompactField(text: isLocal ? $localPort : $remotePort,
                         placeholder: isLocal ? SettingsCopy.dsPhPortLocal : SettingsCopy.dsPhPortRemote,
                         keyboard: .numberPad) { v in
                editDebounced { if isLocal { $0.localPort = v } else { $0.remotePort = v } }
            }
        }
        SettingsLabeledRow(label: SettingsCopy.dsLabelUser) {
            CompactField(text: isLocal ? $localUser : $remoteUser,
                         placeholder: SettingsCopy.dsPhUser) { v in
                editDebounced { if isLocal { $0.localUser = v } else { $0.remoteUser = v } }
            }
        }
        SettingsLabeledRow(label: SettingsCopy.dsLabelPass) {
            CompactField(text: isLocal ? $localPass : $remotePass,
                         placeholder: SettingsCopy.dsPhPass,
                         secure: true,
                         showPlain: showPlain,
                         trailingTitle: showPlain ? SettingsCopy.dsHide : SettingsCopy.dsPlain,
                         onTrailing: { showPlain.toggle() }) { v in
                editDebounced { if isLocal { $0.localPass = v } else { $0.remotePass = v } }
            }
        }
        SettingsLabeledRow(label: SettingsCopy.dsLabelJdbDb) {
            CompactField(text: isLocal ? $localJdb : $remoteJdb,
                         placeholder: SettingsCopy.dsPhJdb) { v in
                editDebounced { if isLocal { $0.localJdb = v } else { $0.remoteJdb = v } }
            }
        }
        SettingsLabeledRow(label: SettingsCopy.dsLabelShtDb) {
            CompactField(text: isLocal ? $localSht : $remoteSht,
                         placeholder: SettingsCopy.dsPhSht) { v in
                editDebounced { if isLocal { $0.localSht = v } else { $0.remoteSht = v } }
            }
        }
    }

    // MARK: 草稿与写通道

    private func loadDraft(_ s: AppSettings) {
        localHost = s.localHost
        localPort = s.localPort
        localUser = s.localUser
        localPass = s.localPass
        localJdb = s.localJdb
        localSht = s.localSht
        remoteHost = s.remoteHost
        remotePort = s.remotePort
        remoteUser = s.remoteUser
        remotePass = s.remotePass
        remoteJdb = s.remoteJdb
        remoteSht = s.remoteSht
    }

    private func editDebounced(_ t: @escaping SettingsTransform) {
        bus.markSaving()
        store.edit(t)
    }

    private func editNow(_ t: @escaping SettingsTransform) {
        bus.markSaving()
        Task { await store.editNow(t) }
    }

    private func selectSource(_ v: String) {
        editingOther = false
        editNow { $0.dbSrc = v }
    }

    // MARK: 测试连接（§13；成功 → clearOffline + Db.reset + bumpData + Toast）

    private func runTest() {
        testing = true
        testResult = SettingsCopy.dsTestingText
        Task {
            // A4/R4：先把 800ms 防抖链落盘，再用「卡片草稿 ∪ 落盘值」显式测试
            await store.flushPendingEdits()
            var draft = store.settings
            draft.localHost = localHost
            draft.localPort = localPort
            draft.localUser = localUser
            draft.localPass = localPass
            draft.localJdb = localJdb
            draft.localSht = localSht
            draft.remoteHost = remoteHost
            draft.remotePort = remotePort
            draft.remoteUser = remoteUser
            draft.remotePass = remotePass
            draft.remoteJdb = remoteJdb
            draft.remoteSht = remoteSht
            draft.dbSrc = curSide
            let r = await SettingsDiagnostics.testConnection(draft)
            testing = false
            testResult = r
            await SettingsDiagnostics.applyConnTestOutcome(r, store: store)
        }
    }
}

// MARK: - ② 网络与代理 — key `proxy`（§3 逐字）

struct ProxyCard: View {

    @ObservedObject var bus: SaveStateBus

    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    // A2/R2：数据库隧道生命周期（错误横显 + 端口可见性）
    @ObservedObject private var tunnel = ProxyTunnelManager.shared

    @State private var loaded = false
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var testing = false
    @State private var testResult = ""

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupProxy,
            rememberKey: "proxy",
            summary: SettingsCopy.summaryProxy(s),
            bus: bus
        ) {
            SettingsLabeledRow(label: SettingsCopy.proxyHostLabel) {
                CompactField(text: $proxyHost,
                             placeholder: SettingsCopy.proxyHostPh) { v in
                    editDebounced(v, proxyPort)
                }
            }
            SettingsLabeledRow(label: SettingsCopy.proxyPortLabel) {
                CompactField(text: $proxyPort,
                             placeholder: SettingsCopy.proxyPortPh,
                             keyboard: .numberPad) { v in
                    // 输入过滤：只保留数字字符（§3 逐字规则）
                    let digits = String(v.filter { $0.isASCII && $0.isNumber })
                    if digits != v { proxyPort = digits }
                    editDebounced(proxyHost, digits)
                }
            }
            SettingsNote(text: SettingsCopy.proxyPortNote, topPad: 2)

            AppSwitchRow(label: SettingsCopy.proxyDbLabel,
                         checked: s.proxyDb,
                         hint: SettingsCopy.proxyDbDesc) { v in
                editNow { $0.proxyDb = v }
            }
            AppSwitchRow(label: SettingsCopy.proxyJdbLabel,
                         checked: s.proxyCdnJdb,
                         hint: SettingsCopy.proxyJdbDesc) { v in
                editNow { $0.proxyCdnJdb = v }
            }
            AppSwitchRow(label: SettingsCopy.proxyShtLabel,
                         checked: s.proxyCdnSht,
                         hint: SettingsCopy.proxyShtDesc) { v in
                editNow { $0.proxyCdnSht = v }
            }
            SettingsNote(text: SettingsCopy.proxyOverlayNote, topPad: 2)

            SettingsActionButton(title: SettingsCopy.proxyTestButton,
                                 busyTitle: SettingsCopy.dsTestingText,
                                 busy: testing,
                                 id: "proxy_test_button") {
                runTest()
            }
            if !testResult.isEmpty {
                SettingsNote(text: testResult, topPad: 6)
            }
            // A2/R2：隧道故障实时显示（保留旧配置语义由 Manager 保证）
            if let tunnelErr = tunnel.lastError {
                SettingsNote(text: tunnelErr, topPad: 6, color: .red)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            proxyHost = s.proxyHost
            proxyPort = s.proxyPort
        }
    }

    private func editDebounced(_ host: String, _ port: String) {
        bus.markSaving()
        store.edit { s in
            s.proxyHost = host
            s.proxyPort = port
        }
    }

    private func editNow(_ t: @escaping SettingsTransform) {
        bus.markSaving()
        Task { await store.editNow(t) }
    }

    private func runTest() {
        testing = true
        testResult = SettingsCopy.dsTestingText
        Task {
            // A4/R4：与 ① 数据源同一口径 —— flush 防抖链 + 显式草稿测试
            await store.flushPendingEdits()
            var draft = store.settings
            draft.proxyHost = proxyHost
            draft.proxyPort = proxyPort
            let r = await SettingsDiagnostics.testConnection(draft)
            testing = false
            testResult = r
            await SettingsDiagnostics.applyConnTestOutcome(r, store: store)
        }
    }
}
