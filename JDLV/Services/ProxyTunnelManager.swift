import Foundation
import JDLVCore

//
//  ProxyTunnelManager.swift —— 数据库 SOCKS5 隧道生命周期（A2/R2）。
//
//  职责（对齐 Android MainVm 的 withSocks 语义）：
//  - proxyDb / proxyHost / proxyPort / 数据源 host/port 变化时【串行】收敛：
//      先起新隧道（不动旧隧道）→ 原子替换 override（host=127.0.0.1、port=listenPort、
//      serverHostname=真实 host 保 TLS SNI）→ 销毁旧隧道 → Db.reset()；
//  - 失败（代理端口非法 / 绑定失败）：保留旧隧道与旧 override，仅置 lastError；
//  - 关闭开关：原子清 override → 销毁隧道 → Db.reset()；
//  - override 只携带传输三元组（127.0.0.1:listenPort + serverHostname）；
//    user/pass/db/tls/超时每次从 AppBootstrap 快照实时映射（改口令不重建隧道也生效）；
//  - 【禁止】只改全局 provider 让并发查询串代理 —— override 原子替换 + Db.reset
//    作废全部旧连接，保证在途查询不落新隧道。
//

/// 隧道 override（线程安全；provider 在任意线程读取）
final class TunnelOverrideBox: @unchecked Sendable {
    struct Override: Equatable {
        var host: String            // 恒 127.0.0.1
        var port: Int               // 隧道监听端口
        var serverHostname: String? // 真实 db host（TLS SNI）
    }

    private let lock = NSLock()
    private var _value: Override?

    var value: Override? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ v: Override?) {
        lock.lock(); _value = v; lock.unlock()
    }
}

@MainActor
final class ProxyTunnelManager: ObservableObject {

    static let shared = ProxyTunnelManager()

    /// 隧道故障（UI 卡显示；重试成功后清空）
    @Published private(set) var lastError: String?
    /// 当前隧道监听端口（nil = 隧道未启用）
    @Published private(set) var activeListenPort: UInt16?

    let overrideBox = TunnelOverrideBox()
    private var tunnel: Socks5Tunnel?
    private var currentKey: String?
    /// 串行收敛队列（后一个 job 先等前一个完成）
    private var job: Task<Void, Never>?

    private init() {}

    // MARK: 生效设置合并（provider 唯一入口；任意线程）

    /// base = AppBootstrap 快照映射；隧道启用时原子叠加传输三元组。
    static func effectiveSettings(_ base: MySQLPoolSettings?) -> MySQLPoolSettings? {
        effectiveSettings(base, tunnel: true)
    }

    /// `tunnel=false`（草稿测试直连）或草稿目标 ≠ 运行中隧道目标 → 不叠加 override。
    static func effectiveSettings(
        _ base: MySQLPoolSettings?, tunnel: Bool
    ) -> MySQLPoolSettings? {
        guard var s = base else { return nil }
        if tunnel, let o = shared.overrideBox.value, s.host == o.serverHostname {
            s.host = o.host
            s.port = o.port
            s.serverHostname = o.serverHostname
        }
        return s
    }

    // MARK: 配置收敛入口（AppBootstrap.refresh / start 调用）

    /// 配置变化 → 排队收敛（不等待完成；串行保证内部顺序）
    func reconcile(_ s: AppSettings) {
        job = chain(from: job) { [weak self] in await self?.apply(s) }
    }

    /// 测试用：排队并等待收敛完成
    func reconcileAndWait(_ s: AppSettings) async {
        let t = chain(from: job) { [weak self] in await self?.apply(s) }
        job = t
        _ = await t.value
    }

    /// 测试辅助：完全复位（销毁隧道 + 清 override/key/error）
    func resetForTests() async {
        overrideBox.set(nil)
        currentKey = nil
        activeListenPort = nil
        lastError = nil
        let old = tunnel
        tunnel = nil
        await old?.destroy()
    }

    private func chain(from prev: Task<Void, Never>?,
                       _ body: @escaping () async -> Void) -> Task<Void, Never> {
        Task { [prev] in
            _ = await prev?.value
            await body()
        }
    }

    // MARK: 收敛执行体（串行到达）

    private func apply(_ s: AppSettings) async {
        let key = "\(s.proxyDb)|\(s.proxyHost)|\(s.proxyPort)|\(s.host)|\(s.port)"
        if key == currentKey { return }

        // 关闭：原子清 override → 销毁 → reset
        guard s.proxyDb else {
            guard currentKey != nil else { return }
            overrideBox.set(nil)
            currentKey = nil
            activeListenPort = nil
            lastError = nil
            let old = tunnel
            tunnel = nil
            await old?.destroy()
            Db.reset()
            return
        }

        // 无效代理端口 / 目标不可用 → 保留旧配置 + 报错
        guard let proxyPort = UInt16(s.proxyPort), proxyPort > 0,
              !s.proxyHost.isEmpty,
              let targetPort = Int(s.port), targetPort > 0, targetPort <= 65535,
              !s.host.isEmpty else {
            lastError = "代理配置无效（检查代理主机/端口）"
            return
        }

        // 先起新隧道（旧隧道继续服务 → 原子替换语义）
        let t = Socks5Tunnel(
            proxy: Socks5Tunnel.ProxyConfig(host: s.proxyHost, port: proxyPort),
            targetHost: s.host,
            targetPort: UInt16(targetPort))
        do {
            let port = try await t.start()
            overrideBox.set(TunnelOverrideBox.Override(
                host: "127.0.0.1", port: Int(port), serverHostname: s.host))
            currentKey = key
            activeListenPort = port
            lastError = nil
            let old = tunnel
            tunnel = t
            await old?.destroy()
            Db.reset()
        } catch {
            // 失败保留旧配置
            lastError = "数据库隧道启动失败: \(error)"
        }
    }
}
