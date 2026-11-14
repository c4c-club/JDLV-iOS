import Foundation
import JDLVCore

//
//  AppBootstrap.swift —— 生产启动 Bootstrap（A1/R1，修复「远程库连不上」根因）。
//
//  根因：此前 App 启动链路从未把 SettingsStore.settings 映射成 MySQLPoolSettings，
//  也从未调用 Db.configure —— MySQLPool.shared.settingsProvider 恒为 nil，任何
//  Db.query / Db.check 在客户端第一道 guard 就抛「数据源未配置」，根本没有发起
//  socket/DNS/handshake。701 个绿灯全部被「Core 测试自带配置 + demo 假连接」掩盖。
//
//  职责（JDLVApp.init 即 @main 最早时机调用 start(store:)）：
//  ① AppSettings → MySQLPoolSettings 纯映射：端口非法或 host/user/pass 空 → nil
//     （Db 层显式抛「数据源未配置」，禁止静默空串建连）；
//  ② Db.configure(settingsProvider:hasNetwork:) 一次性注入：闭包实例永不替换，
//     内容经快照盒原子刷新（池/图片管线会在任意线程读 provider）；
//  ③ 同刻注入 CdnRewrite.settingsProvider + applyHostOnly()（A6 启动口径，
//     不再依赖 SettingsView.onAppear）；
//  ④ 把 SettingsEffects.apply 挂到 store.onPersistedEffects（A3 单入口：落盘成功才
//     执行快照盒刷新/Db.reset/隧道收敛/PageCache 清理/bumpData，不依赖任何视图）；
//  ⑤ 按持久化配置收敛数据库 SOCKS5 隧道（A2/R2）。
//  - hasNetwork 占位：NetworkStateBox（R5 换 NWPathMonitor 驱动同一盒子）。
//

/// 网络可用状态盒（线程安全；R5 前由 bootstrap 默认在线，R5 接 NWPathMonitor 驱动）
final class NetworkStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _online = true

    var online: Bool {
        lock.lock(); defer { lock.unlock() }
        return _online
    }

    func set(_ v: Bool) {
        lock.lock(); _online = v; lock.unlock()
    }
}

enum AppBootstrap {

    // MARK: 注入内容（实例一次性注入、永不替换；内容原子刷新）

    /// 设置快照盒（provider 在任意线程读取 → 内部 NSLock；AppSettings 单值替换）
    static let box = SettingsSnapshotBox()
    /// 网络状态盒（hasNetwork 闭包唯一数据源）
    static let network = NetworkStateBox()

    private static var started = false

    // MARK: App 入口（@main init；幂等）

    @MainActor
    static func start(store: SettingsStore) {
        guard !started else { return }
        started = true
        box.update(store.settings)
        injectRuntime()
        // A3/R3：副作用单入口挂到 Store（落盘成功才执行；不依赖任何视图）
        store.onPersistedEffects = { [weak store] old, new in
            guard let store else { return }
            SettingsEffects.apply(old: old, new: new, store: store)
        }
        // A5/R5：NWPathMonitor → network 盒 + 离线/恢复横幅（UI 测试可用 -JDLV_FAKE_NETWORK 注入）
        NetworkMonitor.shared.start(store: store)
        // A2/R2：按持久化配置收敛数据库 SOCKS5 隧道（proxyDb 开 → 启动隧道）
        ProxyTunnelManager.shared.reconcile(store.settings)
    }

    /// 注入核心（幂等：闭包实例不替换，只重放当前快照；单测直接调用）
    static func injectRuntime() {
        let snapshotBox = box
        Db.configure(
            settingsProvider: {
                ProxyTunnelManager.effectiveSettings(AppBootstrap.mysqlSettings(snapshotBox.settings))
            },
            hasNetwork: { AppBootstrap.network.online })
        CdnRewrite.settingsProvider = { snapshotBox.cdnSettings }
        CdnRewrite.applyHostOnly()
        // R4 P8：本地首页兜底接 SettingsIndexHub 的 IdxDb（懒建；仅离线路径触达）
        Q.setLocalIdxProvider { await SettingsIndexHub.shared.sync?.idx }
    }

    // MARK: AppSettings → MySQLPoolSettings（① 纯映射）

    /// 端口非法（非数字/0/65535+）或 host/user 空 → nil（Db 层显式抛
    /// 「数据源未配置」，禁止静默空串建连）；
    /// R5 P2 空口令规则（选 A，与 Settings.setupRequired 对齐）：
    ///   local 源允许空口令（MySQLPool 空串 → 发 nil，服务端空口令账号语义）；
    ///   remote 源仍要求非空（公网库不放行无口令账号）；
    /// 其余字段一一映射。
    static func mysqlSettings(_ s: AppSettings) -> MySQLPoolSettings? {
        let port = Int(s.port) ?? 0
        guard port > 0, port <= 65535,
              !s.host.isEmpty, !s.user.isEmpty else {
            return nil
        }
        if !s.isLocal && s.pass.isEmpty { return nil }
        return MySQLPoolSettings(
            host: s.host, port: port, user: s.user, pass: s.pass,
            jdbDb: s.jdbDb, shtDb: s.shtDb,
            tls: s.dbSsl,
            connectTimeout: s.connectTimeout,
            queryTimeout: s.queryTimeout)
    }
}
