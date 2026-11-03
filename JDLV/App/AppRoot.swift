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
            HomeTabRoot()
        default:
            TabPlaceholderRoot(tab: tabName, label: label)
        }
    }
}

// MARK: - 首页占位（可 push movie/actor 占位详情验证压栈）

private struct HomeTabRoot: View {
    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme
    @State private var recent: [Row] = []
    @State private var demoLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                searchBar
                demoSection
            }
            .padding(12)
        }
        .background(theme.bg0.ignoresSafeArea())
        .onAppear(perform: loadDemo)
    }

    /// 搜索条占位（P9 接 SearchVm；placeholder 逐字 07 C2「番号 / 标题 / 女优 / 标签…」）
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18))
                .foregroundColor(theme.text2)
            AppText("番号 / 标题 / 女优 / 标签…", lvl: .meta)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: ComponentMetrics.searchBarHeight)
        .background(RoundedRectangle(cornerRadius: ComponentMetrics.searchBarRadius)
            .fill(theme.bg3))
        .accessibilityIdentifier("home_searchbar")
    }

    @ViewBuilder
    private var demoSection: some View {
        #if DEBUG
        if DemoDataSource.enabled() {
            if recent.isEmpty {
                AppText("演示数据加载中…", lvl: .meta)
            } else {
                // 段头逐字（07 C4：🆕 最近更新）
                AppText("🆕 最近更新", lvl: .titleM)
                ForEach(recent.indices, id: \.self) { i in
                    let m = recent[i]
                    MovieCard(m: m, viewMode: 2, onClick: { router.push(.movie(m.s("id"))) })
                        .accessibilityIdentifier(i == 0 ? "home_push_movie" : "home_movie_\(i)")
                }
            }
        } else {
            fallbackPushButtons
        }
        #else
        fallbackPushButtons
        #endif
    }

    private var fallbackPushButtons: some View {
        VStack(spacing: 12) {
            pushButton("打开影片详情（压栈验证）") { router.push(.movie("100001")) }
            pushButton("打开女优详情（压栈验证）") { router.push(.actor("200001")) }
        }
    }

    private func pushButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AppText(title, lvl: .bodyS, color: theme.accent, fontWeight: .medium)
                .frame(maxWidth: .infinity, minHeight: ComponentMetrics.buttonMin)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent.opacity(0.15)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadDemo() {
        #if DEBUG
        guard !demoLoaded, DemoDataSource.enabled() else { return }
        demoLoaded = true
        recent = DemoStore.shared.homeSections(per: 12)["recent"] ?? []
        #endif
    }
}

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
                MovieDetailPlaceholder(mid: mid)
            case .actor(let aid):
                ActorDetailPlaceholder(aid: aid)
            case .shtThread(let tid):
                SecondaryPlaceholder(title: "帖子详情", subtitle: "tid=\(tid)")
            case .articles:
                SecondaryPlaceholder(title: "资讯", subtitle: "资讯列表 P9 实现")
            case .article(let aid):
                SecondaryPlaceholder(title: "资讯详情", subtitle: "aid=\(aid)")
            case .hotreviews:
                SecondaryPlaceholder(title: "热评", subtitle: "热评页 P9 实现")
            case .top250:
                SecondaryPlaceholder(title: "🏆 TOP250", subtitle: "TOP250 完整页 P9 实现")
            case .lookup(let payload):
                LookupPlaceholder(payload: payload)
            }
        }
        .toolbar(.hidden, for: .tabBar)   // 二级页隐藏底栏（07 A3）
    }
}

// MARK: - 影片详情占位（demo 模式回显番号；可再压 actor 验证多层栈）

private struct MovieDetailPlaceholder: View {
    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme
    let mid: String
    @State private var number = ""

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            VStack(spacing: 8) {
                AppText(number.isEmpty ? "影片详情" : number, lvl: .titleM)
                AppText("mid=\(mid)", lvl: .meta)
                AppText(AppCopy.p9Placeholder, lvl: .meta)
                Button {
                    router.push(.actor("200001"))
                } label: {
                    AppText("查看演员（压栈验证）", lvl: .bodyS, color: theme.accent,
                            fontWeight: .medium)
                        .padding(.horizontal, 16)
                        .frame(minHeight: ComponentMetrics.buttonMin)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(theme.accent.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(number.isEmpty ? "影片详情" : number)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .accessibilityIdentifier("secondary_page")
    }

    private func load() {
        #if DEBUG
        guard number.isEmpty, DemoDataSource.enabled(),
              let m = DemoStore.shared.movie(mid: mid) else { return }
        number = m.s("number")
        #endif
    }
}

// MARK: - 女优详情占位

private struct ActorDetailPlaceholder: View {
    @EnvironmentObject private var router: Router
    @Environment(\.appTheme) private var theme
    let aid: String
    @State private var name = ""

    var body: some View {
        ZStack {
            theme.bg0.ignoresSafeArea()
            VStack(spacing: 8) {
                AppText(name.isEmpty ? "女优详情" : name, lvl: .titleM)
                AppText("aid=\(aid)", lvl: .meta)
                AppText(AppCopy.p9Placeholder, lvl: .meta)
                Button {
                    router.push(.movie("100001"))
                } label: {
                    AppText("查看影片（压栈验证）", lvl: .bodyS, color: theme.accent,
                            fontWeight: .medium)
                        .padding(.horizontal, 16)
                        .frame(minHeight: ComponentMetrics.buttonMin)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(theme.accent.opacity(0.15)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(name.isEmpty ? "女优详情" : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .accessibilityIdentifier("secondary_page")
    }

    private func load() {
        #if DEBUG
        guard name.isEmpty, DemoDataSource.enabled(),
              let a = DemoStore.shared.actor(aid: aid) else { return }
        name = a.s("name")
        #endif
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
