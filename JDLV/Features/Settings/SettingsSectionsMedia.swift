//
//  SettingsSectionsMedia.swift
//  JDLV
//
//  P12：设置页 ③ jdb 图床（§4）/ ③ 98t 图床（§5）/ ④ 外观（§6）/ ④ 启动锁（§7 + 10 §8.8/8.9）。
//
//  - jdb 图床：三选一（app/web/自定义 URL 同字段 jdb_img_host）+ 自定义镜像（实时 normalizeUrl）
//    + 图床自检四条结果表 + 重置图片冷却 + 失败率诊断行（1s 轮询 ImgBreaker.diagnostic）。
//  - 98t：先 autoSave 再 CdnSniffer.request（25s 单飞/可取消）；成功 host 自动持久化 sht_mirror_host。
//  - 启动锁：类型切换经 LockSetup.needsConfirmation 二次确认；PIN/图案设置弹层复用
//    LockSecrets.hashSecret（LockView P6 接口）；落盘走 SettingsStore.applyLockChange（Keychain）。
//

import SwiftUI
import JDLVCore

// MARK: - ③ jdb 图床 — key `jdbimg`（§4 逐字）

struct JdbImageCard: View {


    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase

    @State private var customMirror = ""
    @State private var loaded = false
    @State private var selfBusy = false
    @State private var selfLines: [SettingsDiagnostics.SelfTestLine] = []
    @State private var diagText = ""

    /// 当前 chip 值：app / web / custom（自定义 URL 同字段）
    private var chipValue: String {
        let v = store.settings.jdbImgHost
        return (v == "app" || v == "web") ? v : "custom"
    }

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupJdbImg,
            rememberKey: "jdbimg",
            summary: SettingsCopy.summaryJdbImg(s, failureRate: ImgBreaker.shared.failureRatePct()),
        ) {
            SettingsSegmented(label: SettingsCopy.jdbImgHostLabel,
                              options: [
                                        (SettingsCopy.jdbImgApp, "app"), (SettingsCopy.jdbImgWeb, "web"), (SettingsCopy.jdbImgCustom, "custom")],
                              current: chipValue) { v in
                editNow { $0.jdbImgHost = v }
            }

            SettingsNote(text: SettingsCopy.jdbImgDesc(chipValue), topPad: 4)

            if chipValue == "custom" {
                MirrorField(label: SettingsCopy.jdbMirrorLabel,
                            text: $customMirror,
                            placeholder: SettingsCopy.jdbMirrorPh) { v in
                    editDebounced { $0.jdbImgHost = CdnRewrite.normalizeUrl(v) }
                }
            }

            SettingsNote(text: SettingsCopy.jdbFixedNote, topPad: 2)

            // R4 S1：明文 HTTP 镜像显式开关（默认关；开启即 MITM 风险自担）
            AppSwitchRow(label: SettingsCopy.allowInsecureHTTPLabel,
                         checked: s.allowInsecureHTTP,
                         hint: SettingsCopy.allowInsecureHTTPHint) { v in
                editNow { $0.allowInsecureHTTP = v }
            }
            if s.allowInsecureHTTP {
                SettingsNote(text: SettingsCopy.allowInsecureHTTPWarning,
                             topPad: 2, color: theme.red)
            }

            SettingsActionButton(title: SettingsCopy.selfTestButton,
                                 busyTitle: SettingsCopy.selfTestBusy,
                                 busy: selfBusy) {
                runSelfTest()
            }
            ForEach(selfLines.indices, id: \.self) { i in
                let line = selfLines[i]
                AppText(line.text, lvl: .meta,
                        color: line.failed ? theme.red : (line.ok ? theme.accent : theme.accent2))
                    .padding(.top, 2)
            }

            SettingsActionButton(title: SettingsCopy.resetCoolingButton) {
                ImgBreaker.shared.resetCooling()
                AppServices.shared.showToast(SettingsCopy.resetCoolingToast)
            }

            // 失败率诊断行（1s 轮询；Img.kt 逐字模板）
            AppText(diagText.isEmpty ? ImgBreaker.shared.diagnostic() : diagText,
                    lvl: .meta, color: theme.text2)
                .padding(.top, 4)
                // R5 P3：1s 轮询随【展开内容】创建/销毁（折叠卡不创建 timer，不每秒空转）
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    // 非前台零状态写入
                    guard scenePhase == .active else { return }
                    diagText = ImgBreaker.shared.diagnostic()
                }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            customMirror = (chipValue == "custom") ? s.jdbImgHost : ""
        }
    }

    private func editDebounced(_ t: @escaping SettingsTransform) {
        store.edit(t)
    }

    private func editNow(_ t: @escaping SettingsTransform) {
        Task { await store.editNow(t) }
    }

    private func runSelfTest() {
        selfBusy = true
        Task {
            let lines = await SettingsDiagnostics.runSelfTest()
            selfBusy = false
            selfLines = lines
        }
    }
}

// MARK: - ③ 98t 图床 — key `shtimg`（§5 逐字）

struct ShtImageCard: View {


    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var shtMirror = ""
    @State private var loaded = false
    @State private var sniffer = CdnSniffer.State()
    @State private var savedSniffHost: String? = nil

    private var running: Bool { sniffer.running }

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupShtImg,
            rememberKey: "shtimg",
            summary: SettingsCopy.summaryShtImg(live: s, draft: s),
        ) {
            MirrorField(label: SettingsCopy.shtMirrorLabel,
                        text: $shtMirror,
                        placeholder: SettingsCopy.shtMirrorPh) { v in
                editDebounced { $0.shtMirror = v }
            }

            SettingsNote(text: SettingsCopy.shtFixedNote, topPad: 2)

            HStack(spacing: 8) {
                SettingsActionButton(title: SettingsCopy.shtSniffButton,
                                     busyTitle: SettingsCopy.shtSniffingButton,
                                     busy: running) {
                    saveAndSniff()
                }
                if running {
                    SettingsTextButton(title: SettingsCopy.cancelButtonText) {
                        CdnSniffer.shared.cancel()
                    }
                }
            }

            statusLine
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            shtMirror = s.shtMirror
            CdnSniffer.shared.onStateChange = { st in
                Task { @MainActor in
                    sniffer = st
                    persistSniffedIfNeeded(st)
                }
            }
            sniffer = CdnSniffer.shared.state
        }
    }

    /// 状态行四分支（running → err 原文 → 嗅探 host → live.shtMirrorHost）
    @ViewBuilder
    private var statusLine: some View {
        let live = store.settings
        if running {
            AppText(SettingsCopy.shtSniffingStatus, lvl: .meta, color: theme.text2)
                .padding(.top, 4)
        } else if !sniffer.error.isEmpty {
            AppText(sniffer.error, lvl: .meta, color: theme.red)
                .padding(.top, 4)
        } else if let h = sniffer.host {
            AppText(SettingsCopy.shtHostStatus(h), lvl: .meta, color: theme.accent)
                .padding(.top, 4)
        } else if !live.shtMirrorHost.isEmpty {
            AppText(SettingsCopy.shtHostStatus(live.shtMirrorHost), lvl: .meta, color: theme.accent)
                .padding(.top, 4)
        }
    }

    // MARK: 保存并嗅探（§5：normalize 空 → 静默不动作；先 autoSave 后 request）

    private func saveAndSniff() {
        let u = CdnRewrite.normalizeUrl(shtMirror)
        guard !u.isEmpty else { return }
        Task {
            _ = await store.autoSave { $0.shtMirror = u }
            CdnSniffer.shared.request(kind: "sht", siteUrl: u)
        }
    }

    /// 结果持久化：host 非空且 ≠ 已保存值时 autoSave 一次 + Toast（§5 逐字）
    private func persistSniffedIfNeeded(_ st: CdnSniffer.State) {
        guard let h = st.host, h != savedSniffHost else { return }
        savedSniffHost = h
        Task {
            _ = await store.autoSave { $0.shtMirrorHost = h }
            AppServices.shared.showToast(SettingsCopy.shtUpdatedToast(h))
        }
    }

    private func editDebounced(_ t: @escaping SettingsTransform) {
        store.edit(t)
    }
}

// MARK: - ④ 外观 — key `theme`（§6 逐字）

struct ThemeCard: View {


    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupTheme,
            rememberKey: "theme",
            summary: SettingsCopy.summaryTheme(s),
        ) {
            SettingsSegmented(label: SettingsCopy.themeLabel,
                              options: [
                                        (SettingsCopy.themeSystem, "system"), (SettingsCopy.themeDark, "dark"), (SettingsCopy.themeLight, "light"), (SettingsCopy.themeSepia, "sepia")],
                              current: s.themeName) { v in
                editNow { $0.themeName = v }
            }
            // FlowChips：ACCENTS 六色（紫/蓝/绿/橙/粉/青, Theme.kt 逐字顺序）
            VStack(alignment: .leading, spacing: 6) {
                AppText(SettingsCopy.accentLabel, lvl: .meta)
                WrapChips(options: Theme.accents.map { ($0.name, $0.name) },
                          current: s.themeAccent) { v in
                    editNow { $0.themeAccent = v }
                }
            }
        }
    }

    private func editNow(_ t: @escaping SettingsTransform) {
        Task { await store.editNow(t) }
    }
}

// MARK: - ④ 启动锁 — key `lock`（§7 + 10 §8.8/8.9 逐字）

struct LockCard: View {


    @EnvironmentObject private var store: SettingsStore
    @Environment(\.appTheme) private var theme

    @State private var showPinSetup = false
    @State private var showPatternSetup = false
    @State private var pendingType: String? = nil
    @State private var confirmChange = false

    private var currentChip: String {
        store.settings.lockEnabled ? store.settings.lockType : "none"
    }

    var body: some View {
        let s = store.settings
        SettingsGroupCard(
            title: SettingsCopy.groupLock,
            rememberKey: "lock",
            summary: SettingsCopy.summaryLock(s),
        ) {
            SettingsSegmented(label: SettingsCopy.lockTypeLabel,
                              options: [
                                        (SettingsCopy.lockNone, "none"), (SettingsCopy.lockPin, "pin"), (SettingsCopy.lockPattern, "pattern"), (BiometryLabel.current, "biometric")],
                              current: currentChip) { v in
                select(v)
            }

            if s.lockEnabled {
                AppText(SettingsCopy.lockEnabledHint(s.lockType), lvl: .meta, color: theme.accent)
                    .padding(.top, 4)
            }
        }
        .sheet(isPresented: $showPinSetup) {
            PinSetupDialog { pin in
                applyLock(enabled: true, type: "pin", secret: pin)
            }
        }
        .sheet(isPresented: $showPatternSetup) {
            PatternSetupDialog { serialized in
                applyLock(enabled: true, type: "pattern", secret: serialized)
            }
        }
        // 二次确认（LockSetup.needsConfirmation 命中时；关闭/切 biometric 等直接变更路径）
        .alert(confirmTitle, isPresented: $confirmChange) {
            Button(SettingsCopy.cancelButtonText, role: .cancel) {}
            Button(SettingsCopy.saveButtonText, role: .destructive) {
                commitPending()
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String { "确认更改启动锁?" }
    private var confirmMessage: String { "更改后下次打开 app 生效；请牢记新凭据，忘记将无法进入应用。" }

    // MARK: 类型选择（§7 行为表）

    private func select(_ v: String) {
        guard v != currentChip else { return }
        switch v {
        case "none":
            askConfirm(newEnabled: false, newType: "none")
        case "biometric":
            askConfirm(newEnabled: true, newType: "biometric")
        case "pin":
            showPinSetup = true
        case "pattern":
            showPatternSetup = true
        default:
            break
        }
    }

    /// 二次确认判定（P6 接口 LockSetup.needsConfirmation）
    private func askConfirm(newEnabled: Bool, newType: String) {
        pendingType = newType
        let cur = store.settings
        let needs = LockSetup.needsConfirmation(currentEnabled: cur.lockEnabled,
                                                currentType: cur.lockEnabled ? cur.lockType : "none",
                                                newEnabled: newEnabled,
                                                newType: newType)
        if needs {
            confirmChange = true
        } else {
            commitPending()
        }
    }

    private func commitPending() {
        guard let t = pendingType else { return }
        pendingType = nil
        if t == "none" {
            applyLock(enabled: false, type: "none", secret: "")
        } else if t == "biometric" {
            applyLock(enabled: true, type: "biometric", secret: "")
        }
    }

    /// 落盘（P6 接口 applyLockChange；凭据 hash 走 Keychain）
    private func applyLock(enabled: Bool, type: String, secret: String) {
        Task {
            let hash = secret.isEmpty ? "" : await Task.detached(priority: .userInitiated) {
                LockSecrets.hashSecret(secret)
            }.value
            _ = await store.applyLockChange(enabled: enabled, type: type, secretHash: hash)
            if enabled {
                AppServices.shared.showToast(type == "pin" ? SettingsCopy.pinSetToast
                                                           : SettingsCopy.patternSetToast)
            }
        }
    }
}

// MARK: - PinSetupDialog（10 §8.8 逐字）

struct PinSetupDialog: View {

    let onSet: (String) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var pin1 = ""
    @State private var pin2 = ""

    private var errorText: String? {
        if pin1.count < 4 { return SettingsCopy.pinErrShort }
        if pin1 != pin2 { return SettingsCopy.pinErrMismatch }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppText(SettingsCopy.pinDialogTitle, lvl: .bodyS, fontWeight: .semibold)
            CompactField(text: $pin1, placeholder: SettingsCopy.pinPh1,
                         secure: true, showPlain: false, keyboard: .numberPad) { v in
                if v.count > 12 { pin1 = String(v.prefix(12)) }
            }
            CompactField(text: $pin2, placeholder: SettingsCopy.pinPh2,
                         secure: true, showPlain: false, keyboard: .numberPad) { v in
                if v.count > 12 { pin2 = String(v.prefix(12)) }
            }
            if let e = errorText {
                AppText(e, lvl: .meta, color: theme.red)
            }
            HStack(spacing: 8) {
                SettingsActionButton(title: SettingsCopy.saveButtonText,
                                     enabled: errorText == nil, filled: true) {
                    dismiss()
                    onSet(pin1)
                }
                SettingsActionButton(title: SettingsCopy.cancelButtonText) {
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(theme.bg1.ignoresSafeArea())
        .presentationDetents([.height(280)])
    }
}

// MARK: - PatternSetupDialog（10 §8.9 逐字；3×3 自绘：跨点补全/≥4 点/拖尾线）

struct PatternSetupDialog: View {

    let onSet: (String) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var first: String? = nil
    @State private var err = false
    @State private var path: [Int] = []
    @State private var dragPoint: CGPoint? = nil

    private let canvasSize: CGFloat = 240

    private var title: String { first == nil ? SettingsCopy.patternTitleFirst
                                             : SettingsCopy.patternTitleSecond }
    private var hint: String {
        if err { return SettingsCopy.patternHintErr }
        if first != nil { return SettingsCopy.patternHintFirst }
        return SettingsCopy.patternHintNone
    }

    var body: some View {
        VStack(spacing: 12) {
            AppText(title, lvl: .bodyS, fontWeight: .semibold)
            AppText(hint, lvl: .meta, color: err ? theme.red : theme.text2)
            canvas
                .frame(width: canvasSize, height: canvasSize)
                .background(RoundedRectangle(cornerRadius: 16).fill(theme.bg2))
                .contentShape(Rectangle())
                .gesture(dragGesture)
            SettingsTextButton(title: SettingsCopy.cancelButtonText) {
                dismiss()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(theme.bg1.ignoresSafeArea())
        .presentationDetents([.height(420)])
    }

    private var canvas: some View {
        Canvas { ctx, size in
            let w = size.width
            let accent = Color(hex: theme.accentHex)
            let idle = Color(hex: theme.pal.line)
            if let p0 = path.first {
                var line = Path()
                line.move(to: pos(p0, w))
                for i in path.dropFirst() { line.addLine(to: pos(i, w)) }
                if let dp = dragPoint { line.addLine(to: dp) }
                ctx.stroke(line, with: .color(accent),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            let r = w / 3 * 0.34
            for i in 0..<9 {
                let c = pos(i, w)
                let sel = path.contains(i)
                let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(sel ? accent : idle), lineWidth: 3)
                let ir = r * 0.26
                let dot = Path(ellipseIn: CGRect(x: c.x - ir, y: c.y - ir, width: ir * 2, height: ir * 2))
                ctx.fill(dot, with: .color(sel ? accent : idle))
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if let hit = hitTest(v.location) { push(hit) }
                dragPoint = v.location
            }
            .onEnded { _ in
                if path.count >= 4 {
                    let serialized = path.map(String.init).joined(separator: ",")
                    if let f = first {
                        if f == serialized {
                            dismiss()
                            onSet(serialized)
                        } else {
                            err = true
                            first = nil
                        }
                    } else {
                        first = serialized
                        err = false
                    }
                } else if !path.isEmpty {
                    err = true
                    first = nil
                }
                path = []
                dragPoint = nil
            }
    }

    // 几何（与 LockView PatternUnlockView 同规则）

    private func pos(_ i: Int, _ w: CGFloat) -> CGPoint {
        let cell = w / 3
        return CGPoint(x: cell * CGFloat(i % 3) + cell / 2, y: cell * CGFloat(i / 3) + cell / 2)
    }

    private func hitTest(_ p: CGPoint) -> Int? {
        let r = canvasSize / 3 * 0.34
        for i in 0..<9 {
            let c = pos(i, canvasSize)
            let dx = p.x - c.x, dy = p.y - c.y
            if dx * dx + dy * dy <= r * r { return i }
        }
        return nil
    }

    /// 跨点补全：同行/同列/对角跨两格自动加入中间点
    private func push(_ i: Int) {
        guard let last = path.last else {
            path.append(i)
            return
        }
        if path.contains(i) { return }
        let lr = last / 3, lc = last % 3
        let ir = i / 3, ic = i % 3
        let straight = lr == ir || lc == ic || abs(lr - ir) == abs(lc - ic)
        if straight, abs(lr - ir) == 2 || abs(lc - ic) == 2 {
            let mid = ((lr + ir) / 2) * 3 + (lc + ic) / 2
            if mid != last, mid != i, !path.contains(mid) { path.append(mid) }
        }
        path.append(i)
    }
}
