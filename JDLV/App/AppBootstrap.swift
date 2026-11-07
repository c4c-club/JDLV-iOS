import Foundation
import Combine
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
//  ④ 订阅 store.$settings：快照盒始终与持久化配置同源；db 侧字段变更 → Db.reset()
//     （作废旧连接；副作用完整收口在 A3/R3 的 Store 级单一入口）。
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

    private static var subscription: AnyCancellable?
    private static var started = false

    // MARK: App 入口（@main init；幂等）

    @MainActor
    static func start(store: SettingsStore) {
        guard !started else { return }
        started = true
        injectRuntime()
        wire(store: store)
    }

    /// 注入核心（幂等：闭包实例不替换，只重放当前快照；单测直接调用）
    static func injectRuntime() {
        let snapshotBox = box
        Db.configure(
            settingsProvider: { AppBootstrap.mysqlSettings(snapshotBox.settings) },
            hasNetwork: { AppBootstrap.network.online })
        CdnRewrite.settingsProvider = { snapshotBox.cdnSettings }
        CdnRewrite.applyHostOnly()
    }

    /// 订阅设置变更（单测可独立调用；重复调用以最后一次为准）
    @MainActor
    static func wire(store: SettingsStore) {
        subscription?.cancel()
        subscription = store.$settings.sink { [weak store] newValue in
            guard let store else { return }
            refresh(newValue, store: store)
        }
    }

    // MARK: 设置变更（@MainActor；store.$settings 同步回调）

    @MainActor
    private static func refresh(_ new: AppSettings, store: SettingsStore) {
        let old = box.settings
        box.update(new)
        CdnRewrite.applyHostOnly()
        // 数据源/库名/口令/超时/TLS 变更 → 作废全部旧连接（内含 invalidateSchema + 清离线软标记）
        if store.changesBetween(old, new).db {
            Db.reset()
        }
    }

    // MARK: AppSettings → MySQLPoolSettings（① 纯映射）

    /// 端口非法（非数字/0/65535+）或 host/user/pass 空 → nil（Db 层显式抛
    /// 「数据源未配置」，禁止静默空串建连）；其余字段一一映射。
    static func mysqlSettings(_ s: AppSettings) -> MySQLPoolSettings? {
        let port = Int(s.port) ?? 0
        guard port > 0, port <= 65535,
              !s.host.isEmpty, !s.user.isEmpty, !s.pass.isEmpty else {
            return nil
        }
        return MySQLPoolSettings(
            host: s.host, port: port, user: s.user, pass: s.pass,
            jdbDb: s.jdbDb, shtDb: s.shtDb,
            tls: s.dbSsl,
            connectTimeout: s.connectTimeout,
            queryTimeout: s.queryTimeout)
    }
}
