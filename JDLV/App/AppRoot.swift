import SwiftUI
import UIKit
import JDLVCore

// 门禁顺序（07 §A2，顺序即优先级）：lock → !ready → setup → AppRoot。
// 主题应用（13 §A.4）：theme_name/theme_accent → Theme.palette + accentOf → AppTheme 注入
// environment（替换 P1 的 fallback）。
// P8：AppRoot 接 Router（每 Tab 独立 NavigationStack）+ 离线/恢复横幅 + 全局 Toast；
//     二级页一律 .toolbar(.hidden, for: .tabBar)（底栏仅顶层 route 显示，07 A3）。

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

// MARK: - 主界面（6 Tab + 每 Tab 独立 NavigationStack + 横幅/Toast）

struct AppRoot: View {
    @Environment(\.appTheme) private var theme
    @StateObject private var router = Router()
    @StateObject private var services = AppServices.shared

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
        TabView(selection: $router.tab) {
            ForEach(Self.tabs, id: \.route) { t in
                NavigationStack(path: pathBinding(t.route)) {
                    tabRoot(t.route, label: t.label)
                        .navigationDestination(for: Route.self) { route in
                            RouteDestination(route: route)
                        }
                }
                .tabItem { Label(t.label, systemImage: t.icon) }
                .tag(t.route)
                .accessibilityIdentifier("tab_\(t.route)")
            }
        }
        .environmentObject(router)
        .environmentObject(services)
        // 顶部横幅（内容之上、Tab 内容顶部；离线按库粒度 + 恢复 6s 自消）
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                OfflineBanner(offlineJdb: services.offlineJdb, offlineSht: services.offlineSht)
                if services.restored {
                    RestoredBanner()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: services.restored)
        }
        // 全局 Toast（SnackbarHost 对位；services 显式传入，overlay 兄弟层不吃 TabView 的 environmentObject）
        .overlay { ToastHost(services: services) }
        .tint(theme.accent)
    }

    // MARK: 每 Tab 独立 path（Tab 切换保留状态；单实例栈）

    private func pathBinding(_ tabName: String) -> Binding<[Route]> {
        switch tabName {
        case "browse": return $router.browsePath
        case "actors": return $router.actorsPath
        case "sht": return $router.shtPath
        case "favs": return $router.favsPath
        case "settings": return $router.settingsPath
        default: return $router.searchPath
        }
    }

    @ViewBuilder
    private func tabRoot(_ tabName: String, label: String) -> some View {
        switch tabName {
        case "search":
            HomeView()   // P9a：首页三段态 + 搜索态（Features/Search/HomeView.swift）
        case "browse":
            BrowseView()   // P9b：浏览页（自持 BrowseVM；toolbar/筛选/网格/翻页）
        case "actors":
            ActorsView()   // P9c：女优列表（自持 ActorsVM；3 列 1:1 / 搜索 / 排序）
        case "sht":
            ShtView()   // P9d：98t 列表（Features/Sht/ShtView.swift；自持 ShtVM）
        default:
            TabPlaceholderRoot(tab: tabName, label: label)
        }
    }
}

// MARK: - 影片/女优详情占位（P8）已由 Features/MovieDetail / Features/Actors 接管（P9c）

// MARK: - 其余 Tab 根占位（P9 各列表页接入）

private struct TabPlaceholderRoot: View {
    @Environment(\.appTheme) private var theme
    let tab: String
    let label: String

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            VStack(spacing: 8) {
                AppText(label, lvl: .titleM)
                AppText(AppCopy.p9Placeholder, lvl: .meta)
            }
        }
        .accessibilityIdentifier("tab_root_\(tab)")
    }
}

// MARK: - 二级路由目的地（一律隐藏 TabBar）

private struct RouteDestination: View {
    let route: Route

    var body: some View {
        Group {
            switch route {
            case .movie(let mid):
                MovieDetailView(mid: mid)   // P9c：影片详情（Features/MovieDetail）
            case .actor(let aid):
                ActorDetailView(aid: aid)   // P9c：女优详情（Features/Actors）
            case .shtThread(let tid):
                ShtDetailView(tid: tid)   // P9d：帖子详情（Features/Sht；Reader/灯箱/复制收藏）
            case .articles:
                SecondaryPlaceholder(title: "资讯", subtitle: "资讯列表 P9 实现")
            case .article(let aid):
                SecondaryPlaceholder(title: "资讯详情", subtitle: "aid=\(aid)")
            case .hotreviews:
                SecondaryPlaceholder(title: "热评", subtitle: "热评页 P9 实现")
            case .top250:
                SecondaryPlaceholder(title: "🏆 TOP250", subtitle: "TOP250 完整页 P9 实现")
            case .lookup(let payload):
                LookupView(payload: payload)   // P9b：反查结果页（独立 VM + skipBind）
            }
        }
        .toolbar(.hidden, for: .tabBar)   // 二级页隐藏底栏（07 A3）
    }
}

// MARK: - 反查占位（payload 解码 LookupSpec；解码失败兜底空态，10 §6.2）

private struct LookupPlaceholder: View {
    @Environment(\.appTheme) private var theme
    let payload: String

    var body: some View {
        Group {
            if let spec = LookupCodec.decode(payload) {
                ZStack {
                    theme.bg0.ignoresSafeArea()
                    VStack(spacing: 8) {
                        AppText(spec.label, lvl: .titleM)
                        AppText(AppCopy.p9Placeholder, lvl: .meta)
                    }
                }
                .navigationTitle(spec.label)
            } else {
                EmptyBox(text: AppCopy.lookupInvalid, hint: AppCopy.lookupInvalidHint)
                    .navigationTitle(AppCopy.lookupDefaultLabel)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("secondary_page")
    }
}

// MARK: - 通用二级占位页

private struct SecondaryPlaceholder: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            VStack(spacing: 8) {
                AppText(title, lvl: .titleM)
                AppText(subtitle, lvl: .meta)
                AppText(AppCopy.p9Placeholder, lvl: .meta)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("secondary_page")
    }
}
