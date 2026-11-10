import SwiftUI
import UIKit

//
//  AboutView.swift —— 设置 → 关于子页（R3 问题 4：Release 也有真实内容，≥8 行；
//  不挂保存状态行）。Form + Section；行清单见 13 §5.3。
//

struct AboutView: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var diagLogURL: URL? = nil
    @State private var showShareLog = false
    @State private var cacheToast: String? = nil

    // R4 P5：回顶（Form 无可靠 offset 源 → FAB 常显；push 详情页无 TabBar → inset 0；
    // Form 行 scrollTo iOS16 可用性不保证 → 兜底语义见任务书 §8.3「保底」口径）
    private var showScrollTop: Bool { true }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section("版本信息") {
                LabeledRow(label: "版本", value: versionText)
                LabeledRow(label: "构建", value: buildText)
                LabeledRow(label: "设备", value: UIDevice.current.model)
                LabeledRow(label: "系统", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                LabeledRow(label: "数据源", value: dataSourceSummary)
            }
            .id("about_top")
            #if DEBUG
            Section("调试") {
                testImgToggle
                if store.settings.testImgMode {
                    Text("✓ 测试图片模式生效中")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0x2E7D32))
                        .accessibilityIdentifier("testImageModeOn")
                }
            }
            #endif
            Section("诊断") {
                NavigationLink("输入法诊断") {
                    KeyboardDiagnosticsView()
                }
                .accessibilityIdentifier("about_keyboard_diag")
                Button("导出诊断日志") {
                    exportDiagnostics()
                }
                .accessibilityIdentifier("about_export_log")
                Button("清空图片缓存") { clearImageCache() }
                Button("清空查询缓存") { clearQueryCache() }
            }
            Section("法律信息") {
                NavigationLink("开源许可") { LicenseView() }
                NavigationLink("隐私说明") { PrivacyView() }
            }
            Section {
                Text("JDLV iOS — 个人局域网影音资料库客户端。数据来源为自建库与镜像站，本应用不收集、不上传任何用户数据；数据库凭据仅保存在本机 Keychain。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareLog) {
            if let url = diagLogURL {
                ActivityShareSheet(activityItems: [url])
            }
        }
        .onChange(of: cacheToast) { t in
            guard let t else { return }
            AppServices.shared.showToast(t)
            cacheToast = nil
        }
        // R4 P5：Form 无可靠 offset 源 → FAB 常显（push 详情页无 TabBar → inset 0）
        .scrollTopOverlay(visible: showScrollTop, bottomInset: 0) {
            proxy.scrollTo("about_top", anchor: .top)
        }
        }
    }

    // MARK: 行值

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var buildText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
    /// 数据源摘要（不含口令）：本地 jdb/sht 库名 · 远程 host:port
    private var dataSourceSummary: String {
        let s = store.settings
        let local = [s.localJdb, s.localSht].filter { !$0.isEmpty }.joined(separator: "/")
        let remote = s.remoteHost.isEmpty ? "" : "\(s.remoteHost):\(s.remotePort)"
        var parts: [String] = []
        if !local.isEmpty { parts.append("本地 \(local)") }
        if !remote.isEmpty { parts.append("远程 \(remote)") }
        return parts.isEmpty ? "未配置" : parts.joined(separator: " · ")
    }

    // MARK: 测试图片模式（DEBUG only）

    #if DEBUG
    private var testImgToggle: some View {
        AppSwitchRow(label: SettingsCopy.testImgLabel,
                     checked: store.settings.testImgMode,
                     hint: SettingsCopy.testImgDesc) { v in
            // 同步写（updateSettings 立即落盘 + saveState 状态机覆盖）
            store.updateSettings { $0.testImgMode = v }
            TestImages.clearCache()
            AppServices.shared.showToast(v ? SettingsCopy.testImgOnToast
                                           : SettingsCopy.testImgOffToast)
        }
        .accessibilityIdentifier("about_testimg_switch")
    }
    #endif

    // MARK: 诊断日志（生成 txt → ShareLink）

    private func exportDiagnostics() {
        let s = store.settings
        let lines = SettingsDiagnostics.diagnosticLines(s: s, metaLines: [
            "JDLV iOS 诊断日志",
            "生成时间: \(Date())",
            "版本: \(versionText) (\(buildText))",
            "设备: \(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
        ])
        // R4 P14：清理上一次导出的残留（同一 tmp 路径；不在 defer 里删当前文件，
        // 分享面板生命周期内保留，系统 tmp 清理兜底回收）
        try? FileManager.default.removeItem(at: Self.tmpLogURL)
        let url = Self.writeTempLog(lines.joined(separator: "\n"))
        diagLogURL = url
        if url != nil { showShareLog = true }
    }

    /// 诊断临时文件固定路径（R4 P14：可寻址清理，不留历史残留）
    private static var tmpLogURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("jdlv-diagnostics.txt")
    }

    private static func writeTempLog(_ text: String) -> URL? {
        let f = tmpLogURL
        do {
            try text.data(using: .utf8)?.write(to: f)
            return f
        } catch { return nil }
    }

    // MARK: 缓存清理（复用 SettingsDiagnostics 既有目录口径）

    private func clearImageCache() {
        // Caches/jdlv_img 全目录删除（sweepImageCache 同目录、days=∞ 语义）
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = caches.appendingPathComponent("jdlv_img", isDirectory: true)
        var n = 0
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for item in items where (try? fm.removeItem(at: item)) != nil { n += 1 }
        }
        // 内存缓存随进程生命周期；磁盘 Caches/jdlv_img 已清空（下次加载重下）
        cacheToast = "已清空图片缓存 (\(n) 项)"
    }

    private func clearQueryCache() {
        let ok = SettingsDiagnostics.clearQueryCache()
        cacheToast = ok ? "已清空查询缓存" : "查询缓存为空"
    }
}

// MARK: - 行（label + value）

private struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 开源许可 / 隐私说明（静态文本页）

struct LicenseView: View {
    var body: some View {
        ScrollView {
            Text(licenseText)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .navigationTitle("开源许可")
        .navigationBarTitleDisplayMode(.inline)
    }

    private let licenseText = """
    本应用使用的第三方组件：
    · SwiftNIO / mysql-nio（Apache License 2.0）—— MySQL 协议客户端。
    · SQLite3（Public Domain）—— 本地库（已读/收藏/离线索引）。
    · SwiftUI / LocalAuthentication / WebKit —— Apple 系统框架。
    完整许可文本见各组件发行包。本应用不含其他第三方 UI 框架。
    """
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            Text(privacyText)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
        }
        .navigationTitle("隐私说明")
        .navigationBarTitleDisplayMode(.inline)
    }

    private let privacyText = """
    JDLV iOS 不接入任何统计/崩溃上报/广告 SDK，不收集设备标识。
    · 数据库凭据仅保存在本机 Keychain（AfterFirstUnlockThisDeviceOnly），不随设置导出。
    · 查询仅发往你配置的局域网数据库与图床镜像；应用不维护任何远端服务器。
    · 已读/收藏/阅读进度保存在本机 SQLite（jdlv_local.db）。
    · 「导出诊断日志」仅在用户主动触发时生成文本并交给系统分享面板。
    """
}
