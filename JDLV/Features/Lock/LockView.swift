//
//  LockView.swift
//  JDLV
//
//  P6：启动锁（对齐 Android ui/LockScreen.kt，docs/_extract/10_misc_pages.md §8）。
//
//  口径：
//  - 三分支：pattern → 图案；biometric → 生物识别；else → PIN（空串回退 PIN）。
//  - PIN：4–12 位、上限 12 位超长忽略、"清"/"⌫"、新格式 800ms 防抖（同一输入串只验一次、
//    失败清空 + 撤销 lastTried）、旧格式按存储长度立即验证。
//  - 图案：3×3、≥4 点提交、跨点补全（同行/同列/对角跨两格自动加入中间点）、拖尾线、失败清空。
//  - 生物识别：LAContext .deviceOwnerAuthenticationWithBiometrics，降级系统密码
//    （.deviceOwnerAuthentication）；设备不可用文案逐字。
//  - 失败锁定：5 次起锁 30s，×2 指数（shift 封顶 6 → 最高 32 分钟），倒计时文案逐字；
//    计数/倒计时只在内存（LockThrottle，可注入时钟供测试）。
//  - 凭据：PBKDF2-HMAC-SHA256（CommonCrypto，120k 迭代，随机盐 16B，256 位输出），
//    iOS 存储格式 `pbkdf2-sha256$<iter>$<salt_b64>$<hash_b64>`；兼容 Android 旧格式
//    `pbkdf2:<iter>[:<len>]:<salt_hex>:<hash_hex>` 与 64 位裸 sha256 hex（三端互认）。
//    比较恒定时间。hash 串经 SettingsStore 写 Keychain（lock_secret）。
//  - 解锁态由 App 级 SettingsStore.unlocked 持有（内存，绝不持久化）。
//
//  刻意差异：Android「宿主 Activity 不支持」文案无 iOS 对应物（无 FragmentActivity 概念），省略。
//

import JDLVCore
import SwiftUI
import Combine
import LocalAuthentication
import CommonCrypto
import Security

// MARK: - PBKDF2 凭据哈希

enum LockSecrets {

    static let prefix = "pbkdf2-sha256"
    static let defaultIterations = 120_000
    static let saltBytes = 16
    static let hashBytes = 32

    // MARK: 哈希

    /// 新版哈希：PBKDF2-HMAC-SHA256，120k 迭代，16B 随机盐，32B 输出。
    /// 格式 `pbkdf2-sha256$<iter>$<salt_b64>$<hash_b64>`（不含原文长度，A-27）。
    static func hashSecret(_ plain: String) -> String {
        var salt = Data(count: saltBytes)
        let status = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, saltBytes, base)
        }
        if status != errSecSuccess {
            // 随机源异常兜底：SystemRandomNumberGenerator 填充
            var gen = SystemRandomNumberGenerator()
            salt = Data((0..<saltBytes).map { _ in UInt8.random(in: .min ... .max, using: &gen) })
        }
        let hash = pbkdf2(plain: plain, salt: salt, rounds: defaultIterations, keyLength: hashBytes)
        return "\(prefix)$\(defaultIterations)$\(salt.base64EncodedString())$\(hash.base64EncodedString())"
    }

    /// CommonCrypto PBKDF2-HMAC-SHA256
    static func pbkdf2(plain: String, salt: Data, rounds: Int, keyLength: Int) -> Data {
        var derived = Data(repeating: 0, count: keyLength)
        var pw = Array(plain.utf8)
        let passLen = pw.count
        if pw.isEmpty { pw = [0] }   // 空口令：占位指针 + 长度 0，保持空串语义
        let saltCopy = salt
        let status = derived.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int32 in
            pw.withUnsafeBufferPointer { pwBuf in
                saltCopy.withUnsafeBytes { (sal: UnsafeRawBufferPointer) -> Int32 in
                    let passPtr: UnsafePointer<Int8>? = pwBuf.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self)
                    }
                    let saltPtr = sal.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr, passLen,
                        saltPtr, saltCopy.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(max(1, rounds)),
                        out.bindMemory(to: UInt8.self).baseAddress, keyLength)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return derived
    }

    /// 裸 sha256 hex（旧格式兼容校验用）
    static func sha256Hex(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBufferPointer { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 校验

    /// 校验（恒定时间比较）。命中顺序：iOS 新格式 → Android 旧 pbkdf2 格式 → 裸 sha256 → false。
    static func verifySecret(_ plain: String, stored: String) -> Bool {
        // 新格式 pbkdf2-sha256$<iter>$<salt_b64>$<hash_b64>
        let dollarParts = stored.split(separator: "$", omittingEmptySubsequences: false)
        if dollarParts.count == 4, dollarParts[0] == prefix {
            guard let iters = Int(dollarParts[1]), iters >= 1,
                  let salt = Data(base64Encoded: String(dollarParts[2])),
                  let hash = Data(base64Encoded: String(dollarParts[3])), !hash.isEmpty
            else { return false }
            let calc = pbkdf2(plain: plain, salt: salt, rounds: iters, keyLength: hash.count)
            return constantTimeEquals(calc, hash)
        }
        // Android 旧格式 pbkdf2:<iters>[:<len>]:<saltHex>:<hashHex>
        if stored.hasPrefix("pbkdf2:") {
            let segs = stored.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if segs.count == 4 || segs.count == 5 {
                let saltHex = segs.count == 5 ? segs[3] : segs[2]
                let hashHex = segs.count == 5 ? segs[4] : segs[3]
                guard let iters = Int(segs[1]), iters >= 1,
                      let salt = hexDecode(saltHex), !salt.isEmpty,
                      let hash = hexDecode(hashHex), !hash.isEmpty
                else { return false }
                let calc = pbkdf2(plain: plain, salt: salt, rounds: iters, keyLength: hash.count)
                return constantTimeEquals(calc, hash)
            }
            return false
        }
        // 更旧：64 位裸 sha256 hex
        if stored.count == 64, stored.allSatisfy({ $0.isHexDigit }) {
            guard let calc = hexDecode(sha256Hex(plain)), let expect = hexDecode(stored) else { return false }
            return constantTimeEquals(calc, expect)
        }
        return false
    }

    /// 新格式返回 0（走防抖验证）；Android 旧格式带长度可读出 4–12；其余 0
    static func secretLength(_ stored: String) -> Int {
        let dollarParts = stored.split(separator: "$", omittingEmptySubsequences: false)
        if dollarParts.count == 4, dollarParts[0] == prefix { return 0 }
        if stored.hasPrefix("pbkdf2:") {
            let segs = stored.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if segs.count == 5 { return Int(segs[2]) ?? 0 }
            return 0
        }
        return 0
    }

    /// 恒定时间比较（等价 MessageDigest.isEqual 的长度不泄露语义：长度不等直接 false 不做逐字节比较）
    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    static func hexDecode(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var out = Data(capacity: chars.count / 2)
        var byte: UInt8 = 0
        for (idx, c) in chars.enumerated() {
            guard let v = hexValue(c) else { return nil }
            if idx % 2 == 0 { byte = v << 4 } else { out.append(byte | v) }
        }
        return out
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

// MARK: - 失败锁定计数器（内存态，可注入时钟）

/// 5 次起锁 30s，×2 指数（shift 封顶 6 → 32 分钟）；倒计时结束 msg 清空、fails 归零重计。
final class LockThrottle {

    private let clock: () -> TimeInterval   // 秒
    private var lockedUntil: TimeInterval = 0
    private(set) var fails = 0

    init(clock: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    /// 锁定罚时长 ms：fails<5 → 0；否则 30000 << min(fails-5, 6)（封顶 32 分钟）
    static func penaltyMs(fails: Int) -> Int {
        guard fails >= 5 else { return 0 }
        let shift = min(fails - 5, 6)
        return 30_000 << shift
    }

    /// 失败一次；≥5 触发锁定。返回本次罚时长 ms（0 = 未触发）。
    @discardableResult
    func registerFailure() -> Int {
        fails += 1
        guard fails >= 5 else { return 0 }
        let penalty = Self.penaltyMs(fails: fails)
        lockedUntil = clock() + Double(penalty) / 1000.0
        return penalty
    }

    /// 是否锁定中；跨过锁定终点时归零 fails 并解除。
    func checkLocked() -> Bool {
        let now = clock()
        if lockedUntil > 0 && now >= lockedUntil {
            lockedUntil = 0
            fails = 0
            return false
        }
        return lockedUntil > now
    }

    /// 剩余锁定 ms（未锁定 0）
    func remainingMs() -> Int {
        let now = clock()
        guard lockedUntil > now else { return 0 }
        return Int((lockedUntil - now) * 1000.0)
    }

    func reset() {
        fails = 0
        lockedUntil = 0
    }
}

// MARK: - LockView 主界面

@MainActor
struct LockView: View {

    let type: String              // "pin" / "pattern" / "biometric"（空串回退 pin）
    let secret: String            // Keychain 读出的哈希串
    let onUnlock: () -> Void

    @Environment(\.appTheme) private var theme

    @State private var msg = ""
    @State private var throttle = LockThrottle()
    @State private var verifying = false
    @State private var pendingPlain: String? = nil   // 验证中到达的请求排队，不丢弃
    @State private var failTick = 0                  // 失败信号：PIN/图案清空重试
    @State private var lockedNow = false

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var effectiveType: String {
        switch type {
        case "pattern": return "pattern"
        case "biometric": return "biometric"
        default: return "pin"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 80)
            Text("JDLV 已锁定")
                .font(.system(size: Tx.titleL.size, weight: .bold))
                .foregroundColor(theme.text)
            Text("输入凭据解锁")
                .font(.system(size: Tx.bodyS.size))
                .foregroundColor(theme.text2)
                .padding(.top, 6)
            Spacer().frame(height: 28)
            Group {
                switch effectiveType {
                case "pattern":
                    PatternUnlockView(theme: theme, verifying: verifying, failTick: failTick, onSubmit: verify)
                case "biometric":
                    BiometricGateView(theme: theme, onUnlock: onUnlock)
                default:
                    PinUnlockView(theme: theme, stored: secret, verifying: verifying,
                                  failTick: failTick, lockedNow: lockedNow, onSubmit: verify)
                }
            }
            messageArea
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg0.ignoresSafeArea())
        .onAppear { lockedNow = throttle.checkLocked() }
        .onReceive(timer) { _ in
            let was = lockedNow
            lockedNow = throttle.checkLocked()
            if was && !lockedNow { msg = "" }   // 倒计时结束：msg 清空、fails 归零重计
        }
    }

    /// 消息区（12sp error）：锁定倒计时优先，否则 msg
    @ViewBuilder
    private var messageArea: some View {
        Group {
            if lockedNow {
                Text("失败次数过多, \(throttle.remainingMs() / 1000 + 1) 秒后可重试")
            } else if !msg.isEmpty {
                Text(msg)
            }
        }
        .font(.system(size: Tx.meta.size))
        .foregroundColor(theme.red)
        .frame(minHeight: 18)
        .padding(.top, 12)
    }

    // MARK: 验证

    private func verify(_ plain: String) {
        if verifying {
            pendingPlain = plain   // 验证中到达的请求排队（跑完再验），不丢弃
            return
        }
        if throttle.checkLocked() { return }   // 锁定期间验证直接 return
        if secret.isEmpty {
            msg = "锁凭据丢失, 请在设置中重新设置 (可先用系统指纹解锁)"
            failTick &+= 1   // 清空输入便于重试（不计失败）
            return
        }
        verifying = true
        let stored = secret
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                LockSecrets.verifySecret(plain, stored: stored)
            }.value
            finishVerify(ok: ok)
        }
    }

    private func finishVerify(ok: Bool) {
        verifying = false
        if ok {
            throttle.reset()
            onUnlock()
            return
        }
        let penalty = throttle.registerFailure()
        lockedNow = throttle.checkLocked()
        msg = penalty > 0
            ? "连续失败 \(throttle.fails) 次, 锁定 \(penalty / 1000) 秒"
            : "凭据不正确"
        failTick &+= 1   // 失败清空重试
        if let p = pendingPlain {
            pendingPlain = nil
            verify(p)
        }
    }
}

// MARK: - PIN 解锁

@MainActor
private struct PinUnlockView: View {

    let theme: AppTheme
    let stored: String
    let verifying: Bool
    let failTick: Int
    let lockedNow: Bool
    let onSubmit: (String) -> Void

    @State private var pin = ""
    @State private var lastTried: String?
    @State private var debounceTask: Task<Void, Never>?
    /// 旧格式可读出期望长度（>0 → 达到即验证；0 → 新格式 800ms 防抖）
    private let expectLen: Int

    private static let rows: [[String]] = [
        ["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["清", "0", "⌫"],
    ]

    init(theme: AppTheme, stored: String, verifying: Bool, failTick: Int,
         lockedNow: Bool, onSubmit: @escaping (String) -> Void) {
        self.theme = theme
        self.stored = stored
        self.verifying = verifying
        self.failTick = failTick
        self.lockedNow = lockedNow
        self.onSubmit = onSubmit
        self.expectLen = LockSecrets.secretLength(stored)
    }

    private var displayText: String {
        pin.isEmpty ? "请输入 PIN" : String(repeating: "● ", count: pin.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(displayText)
                .font(.system(size: 18))
                .foregroundColor(theme.text)
                .frame(height: 32)
            VStack(spacing: 7) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                onKey(key)
                            } label: {
                                Text(key)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(theme.text)
                                    .frame(width: 66, height: 66)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.bg1))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .onChange(of: pin) { newValue in
            onPinChanged(newValue)
        }
        .onChange(of: failTick) { _ in
            // 失败：清空输入 + 撤销 lastTried（保证同一 PIN 可重试）
            debounceTask?.cancel()
            debounceTask = nil
            lastTried = nil
            pin = ""
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    private func onKey(_ key: String) {
        switch key {
        case "清":                       // 清空全部
            debounceTask?.cancel()
            debounceTask = nil
            lastTried = nil
            pin = ""
        case "⌫":                        // 删一位
            guard !pin.isEmpty else { return }
            debounceTask?.cancel()
            pin.removeLast()
        default:                         // 数字键上限 12 位（超长忽略）
            guard pin.count < 12 else { return }
            debounceTask?.cancel()
            pin.append(key)
        }
    }

    private func onPinChanged(_ p: String) {
        guard !lockedNow else { return }           // 锁定期间不调度验证（verify 也会直接 return）
        guard !verifying else { return }
        if expectLen > 0 {
            // 旧格式：长度达期望立即验证（满 12 位不中计失败）
            if p.count == expectLen {
                lastTried = p
                onSubmit(p)
            }
            return
        }
        // 新格式：800ms 防抖；pin.length ≥ 4 且 ≠ lastTried 才验证（同一输入串只验一次）
        debounceTask?.cancel()
        guard p.count >= 4, p != lastTried else { return }
        lastTried = p
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            onSubmit(p)
        }
    }
}

// MARK: - 图案解锁

@MainActor
private struct PatternUnlockView: View {

    let theme: AppTheme
    let verifying: Bool
    let failTick: Int
    let onSubmit: (String) -> Void

    @State private var path: [Int] = []
    @State private var dragPoint: CGPoint? = nil   // 手指在点外拖动显示拖尾线

    private static let canvasSize: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            Text("绘制解锁图案")
                .font(.system(size: Tx.bodyS.size))
                .foregroundColor(theme.text)
                .frame(height: 28)
            canvas
                .frame(width: Self.canvasSize, height: Self.canvasSize)
                .background(RoundedRectangle(cornerRadius: 16).fill(theme.bg1))
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .padding(.top, 12)
        }
        .onChange(of: failTick) { _ in
            path = []          // 失败后 path 清空
            dragPoint = nil
        }
    }

    private var canvas: some View {
        Canvas { ctx, size in
            let w = size.width
            let accent = Color(hex: theme.accentHex)
            let idle = Color(hex: theme.pal.line)
            // 连线 + 拖尾
            if let first = path.first {
                var line = Path()
                line.move(to: pointPos(first, size: w))
                for i in path.dropFirst() { line.addLine(to: pointPos(i, size: w)) }
                if let dp = dragPoint { line.addLine(to: dp) }
                ctx.stroke(line, with: .color(accent),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            // 九点：外圈描边 3 + 内点半径 r×0.26 填充；已选 primary / 未选 outlineVariant
            let r = pointRadius(size: w)
            for i in 0..<9 {
                let c = pointPos(i, size: w)
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
                if let hit = hitTest(v.location) { pushPoint(hit) }
                dragPoint = v.location
            }
            .onEnded { _ in
                if path.count >= 4 {
                    // 提交即 verify（计入失败）；序列化 "0,1,5,8"
                    onSubmit(path.map(String.init).joined(separator: ","))
                }
                path = []          // <4 点清空重画；提交后同样清空（失败重画，成功即离页）
                dragPoint = nil
            }
    }

    // MARK: 几何

    private func pointPos(_ i: Int, size: CGFloat) -> CGPoint {
        let cell = size / 3
        return CGPoint(x: cell * CGFloat(i % 3) + cell / 2, y: cell * CGFloat(i / 3) + cell / 2)
    }

    /// 九点半径 = cell × 0.34
    private func pointRadius(size: CGFloat) -> CGFloat {
        size / 3 * 0.34
    }

    private func hitTest(_ p: CGPoint) -> Int? {
        let size = Self.canvasSize
        let r = pointRadius(size: size)
        for i in 0..<9 {
            let c = pointPos(i, size: size)
            let dx = p.x - c.x, dy = p.y - c.y
            if dx * dx + dy * dy <= r * r { return i }
        }
        return nil
    }

    /// 跨点补全：同行/同列/对角跨两格 → 自动加入中间点
    private func pushPoint(_ i: Int) {
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

// MARK: - 生物识别

@MainActor
private struct BiometricGateView: View {

    let theme: AppTheme
    let onUnlock: () -> Void

    @State private var msg = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "touchid")
                .font(.system(size: 44))
                .foregroundColor(theme.text2)
            Button {
                run()
            } label: {
                Text("重新验证")
                    .font(.system(size: Tx.body.size, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(theme.accent))
            }
            .buttonStyle(.plain)
            if !msg.isEmpty {
                Text(msg)
                    .font(.system(size: Tx.meta.size))
                    .foregroundColor(theme.red)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear { run() }   // 进入自动弹出系统 BiometricPrompt
    }

    /// 先生物识别（.deviceOwnerAuthenticationWithBiometrics），降级系统密码（.deviceOwnerAuthentication）
    private func run() {
        let ctx = LAContext()
        var err: NSError?
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) {
            evaluate(ctx, policy: .deviceOwnerAuthenticationWithBiometrics)
        } else if ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) {
            evaluate(ctx, policy: .deviceOwnerAuthentication)
        } else {
            msg = "设备无可用指纹/系统凭据, 请在设置中改用 PIN 或图案"
        }
    }

    private func evaluate(_ ctx: LAContext, policy: LAPolicy) {
        ctx.evaluatePolicy(policy, localizedReason: "解锁 JDLV") { ok, error in
            DispatchQueue.main.async {
                if ok {
                    onUnlock()
                    return
                }
                // 用户点了系统 UI 的“使用密码” → 降级走系统锁屏凭据
                if let laErr = error as? LAError, laErr.code == .userFallback {
                    let fallback = LAContext()
                    if fallback.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
                        evaluate(fallback, policy: .deviceOwnerAuthentication)
                    }
                }
                // 失败/取消留在本页（系统 prompt 自带错误 UI）
            }
        }
    }
}

// MARK: - P12 设置页接口占位（切换锁类型必须二次确认）

extension SettingsStore {
    /// 设置页（P12）专用：切换/关闭启动锁的落盘入口。
    /// 调用约定：UI 必须先弹二次确认（对齐 Android PinSetupDialog/PatternSetupDialog 语义），
    /// 确认后传入 LockSecrets.hashSecret(凭据) 的哈希；type ∈ none/pin/pattern/biometric；
    /// 关闭时 secretHash 传空串。lock_secret 经 Keychain，绝不进 UserDefaults。
    @discardableResult
    func applyLockChange(enabled: Bool, type: String, secretHash: String) async -> SaveResult {
        await updateSettingsNow { s in
            s.lockEnabled = enabled
            s.lockType = enabled ? type : "none"
            s.lockSecret = enabled ? secretHash : ""
        }
    }
}

/// P12 切换确认判定：类型或启用态变化即需二次确认
enum LockSetup {
    static func needsConfirmation(currentEnabled: Bool, currentType: String,
                                  newEnabled: Bool, newType: String) -> Bool {
        currentEnabled != newEnabled || currentType != newType
    }
}
