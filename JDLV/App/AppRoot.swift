import SwiftUI
import UIKit
import JDLVCore

// 门禁顺序（07 §A2，顺序即优先级）：lock → !ready → setup → AppRoot。
// 主题应用（13 §A.4）：theme_name/theme_accent → Theme.palette + accentOf → AppTheme 注入
// environment（替换 P1 的 fallback）。现有 6 Tab 占位结构保留。

// MARK: - 门禁（lock → ready → setup → 主界面）

struct AppGate: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let s = store.settings
        // lock 判定（A2）：lockEnabled && (lockType == "biometric" || lockSecret 非空)
        let lockNeeded = s.lockEnabled && (s.lockType == "biometric" || !s.lockSecret.isEmpty)
        let theme = AppTheme(
            pal: Theme.palette(themeName: s.themeName, systemDark: colorScheme == .dark),
            accentHex: Theme.accentOf(s.themeAccent))

        Group {
            if lockNeeded && !store.unlocked {
                LockView(
                    type: s.lockType.isEmpty ? "pin" : s.lockType,
                    secret: s.lockSecret,
                    onUnlock: { store.markUnlocked() }
                )
            } else if !store.loaded {
                // A2 #2：!ready → 全屏居中转圈（iOS 同步载入，仅瞬态）
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.bg0.ignoresSafeArea())
            } else if store.setupRequired {
                FirstRunSetupView()
            } else {
                AppRoot()
            }
        }
        .tint(theme.accent)
        .environment(\.appTheme, theme)
    }
}

// MARK: - 首启引导（setup 分支占位；完整设置页留 P12）

/// 顶部横幅逐字「首次使用 · 请配置数据源」+ 极简说明卡 + 「去设置」按钮；
/// 「去设置」展开最小数据源表单（P6 占位），保存后 setupRequired 转 false → 门禁直接进
/// 主页（≤3s，无需重启进程）。
struct FirstRunSetupView: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var showForm = false
    @State private var dbSrc = "remote"
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var showPlain = false       // 密码遮罩切换（尾缀文字 明文/隐藏）
    @State private var saving = false
    @State private var errText = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("首次使用 · 请配置数据源")
                .font(.system(size: 13))
                .foregroundColor(theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(theme.accent.opacity(0.20))
            ScrollView {
                VStack(spacing: 16) {
                    if showForm { quickForm } else { explanationCard }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
        .onAppear { loadDraft() }
        .onChange(of: dbSrc) { _ in loadDraft() }
    }

    // MARK: 说明卡 + 去设置

    private var explanationCard: some View {
        VStack(spacing: 12) {
            Text("JDLV Mobile · 远程库只读浏览客户端")
                .font(.system(size: Tx.titleM.size, weight: .semibold))
                .foregroundColor(theme.text)
            Text("与桌面端共用远程 MySQL; 数据源配置仅保存在本机")
                .font(.system(size: Tx.meta.size))
                .foregroundColor(theme.text2)
                .multilineTextAlignment(.center)
            Button {
                showForm = true
            } label: {
                Text("去设置")
                    .font(.system(size: Tx.body.size, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.bg1))
    }

    // MARK: 最小数据源表单（P6 占位）

    private var quickForm: some View {
        VStack(spacing: 12) {
            Picker("当前数据源", selection: $dbSrc) {
                Text("本地库").tag("local")
                Text("远程库").tag("remote")
            }
            .pickerStyle(.segmented)
            fieldRow("主机", placeholder: "IP / 主机名", text: $host, keyboard: .default)
            fieldRow("端口", placeholder: dbSrc == "local" ? "3306" : "3307", text: $port, keyboard: .numberPad)
            fieldRow("用户", placeholder: "用户名", text: $user, keyboard: .default)
            passwordRow
            if !errText.isEmpty {
                Text(errText)
                    .font(.system(size: Tx.meta.size))
                    .foregroundColor(theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                save()
            } label: {
                Text(saving ? "保存中…" : "保存")
                    .font(.system(size: Tx.body.size, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(saving)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.bg1))
    }

    private var passwordRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("密码")
                .font(.system(size: 13))
                .foregroundColor(theme.text2)
                .frame(width: 96, alignment: .leading)
            Group {
                if showPlain {
                    TextField("密码", text: $pass)
                } else {
                    SecureField("密码", text: $pass)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(theme.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
            Button {
                showPlain.toggle()
            } label: {
                Text(showPlain ? "隐藏" : "明文")
                    .font(.system(size: 12))
                    .foregroundColor(theme.text2)
            }
            .buttonStyle(.plain)
        }
    }

    private func fieldRow(_ label: String, placeholder: String,
                          text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(theme.text2)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .font(.system(size: 13))
                .foregroundColor(theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.bg3.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
        }
    }

    // MARK: 草稿与保存

    private func loadDraft() {
        let s = store.settings
        dbSrc = s.dbSrc == "local" ? "local" : "remote"
        host = s.host
        port = s.port
        user = s.user
        pass = s.pass
    }

    private func save() {
        let src = dbSrc
        let h = host.trimmingCharacters(in: .whitespaces)
        let p = port.trimmingCharacters(in: .whitespaces)
        let u = user
        let pw = pass
        // P6 占位校验（对齐 setupRequired 判定；完整校验/测试连接在 P12）
        let missing = src == "remote" ? (u.isEmpty || pw.isEmpty) : u.isEmpty
        if missing {
            errText = src == "remote" ? "请填写用户与密码" : "请填写用户名"
            return
        }
        saving = true
        errText = ""
        Task {
            let r = await store.updateSettingsNow { s in
                s.dbSrc = src
                if src == "local" {
                    s.localHost = h; s.localPort = p; s.localUser = u; s.localPass = pw
                } else {
                    s.remoteHost = h; s.remotePort = p; s.remoteUser = u; s.remotePass = pw
                }
            }
            saving = false
            if r == .failed {
                errText = "保存失败 (重试或检查存储)"   // 11_settings 0.1 逐字
            }
            // SAVED：setupRequired 转 false → AppGate 直接进主页，无需重启进程
        }
    }
}

// MARK: - 主界面骨架（6 Tab 占位，P1 结构保留）

struct AppRoot: View {
    @Environment(\.appTheme) private var theme

    private struct TabDef {
        let route: String
        let label: String
        let icon: String
    }

    // 图标与 Android outlined/filled 语义对应（SF Symbols）
    private static let tabs: [TabDef] = [
        TabDef(route: "search", label: "搜索", icon: "magnifyingglass"),
        TabDef(route: "browse", label: "浏览", icon: "square.grid.2x2"),
        TabDef(route: "actors", label: "女优", icon: "face.smiling"),
        TabDef(route: "sht", label: "98t", icon: "bubble.left.and.bubble.right"),
        TabDef(route: "favs", label: "收藏", icon: "star"),
        TabDef(route: "settings", label: "设置", icon: "gearshape"),
    ]

    var body: some View {
        TabView {
            ForEach(Self.tabs, id: \.route) { tab in
                PlaceholderPage(label: tab.label)
                    .tabItem {
                        Label(tab.label, systemImage: tab.icon)
                    }
                    .accessibilityIdentifier("tab_\(tab.route)")
            }
        }
        .tint(theme.accent)
        .environment(\.appTheme, theme)
    }
}

private struct PlaceholderPage: View {
    @Environment(\.appTheme) private var theme
    let label: String

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            Text(label)
                .font(.system(size: Tx.titleM.size, weight: Tx.titleM.weight))
                .foregroundColor(theme.text)
        }
    }
}
