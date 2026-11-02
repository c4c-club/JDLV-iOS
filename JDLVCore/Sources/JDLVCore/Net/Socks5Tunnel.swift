import Foundation
import MySQLNIO

// SOCKS5 隧道（对齐规划 §4.3）：本机 127.0.0.1 监听（随机端口），每条入站连接
// 向 SOCKS 代理发起握手（无认证 / 用户名口令），CONNECT 固定目标（真实 db host:port），
// 成功后双向字节泵。MySQLNIO 指向 127.0.0.1:<tunnelPort>（透明中继，对内不是 SOCKS 服务器），
// serverHostname 仍填真实主机（保 TLS SNI）。
// Android 的 JVM 全局 socksProxy 属性在 iOS 不存在，本隧道即其等价物。

public enum Socks5Codec {
    public enum AuthMethod: UInt8 {
        case noAuth = 0x00
        case usernamePassword = 0x02
    }

    /// 客户端问候：VER=5 NMETHODS METHODS
    public static func greeting(methods: [AuthMethod]) -> [UInt8] {
        var out: [UInt8] = [0x05, UInt8(methods.count)]
        out.append(contentsOf: methods.map { $0.rawValue })
        return out
    }

    /// 解析服务器方法选择：VER=5 METHOD；拒绝（0xFF）→ nil
    public static func parseGreetingReply(_ bytes: [UInt8]) -> AuthMethod? {
        guard bytes.count >= 2, bytes[0] == 0x05, bytes[1] != 0xFF else { return nil }
        return AuthMethod(rawValue: bytes[1])
    }

    /// 用户名/口令子协商（RFC 1929）：VER=1 ULEN UNAME PLEN PASSWD
    public static func auth(username: String, password: String) -> [UInt8] {
        var out: [UInt8] = [0x01, UInt8(username.utf8.count)]
        out.append(contentsOf: Array(username.utf8))
        out.append(UInt8(password.utf8.count))
        out.append(contentsOf: Array(password.utf8))
        return out
    }

    /// 解析认证应答：VER=1 STATUS=0 成功
    public static func parseAuthReply(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 2 && bytes[0] == 0x01 && bytes[1] == 0x00
    }

    /// CONNECT 请求：VER=5 CMD=1 RSV=0 ATYP ADDR PORT（域名 ATYP=0x03）
    public static func connect(host: String, port: UInt16) -> [UInt8] {
        var out: [UInt8] = [0x05, 0x01, 0x00]
        let ip4 = host.split(separator: ".").compactMap { UInt8($0) }
        if ip4.count == 4 && host.allSatisfy({ $0.isNumber || $0 == "." }) {
            out.append(0x01)
            out.append(contentsOf: ip4)
        } else {
            out.append(0x03)
            out.append(UInt8(host.utf8.count))
            out.append(contentsOf: Array(host.utf8))
        }
        out.append(UInt8(port >> 8))
        out.append(UInt8(port & 0xFF))
        return out
    }

    public enum ConnectReply {
        case succeeded(bindHost: String, bindPort: UInt16)
        case failed(code: UInt8)
    }

    /// 解析 CONNECT 应答（支持 IPv4/域名/IPv6 地址）
    public static func parseConnectReply(_ bytes: [UInt8]) -> ConnectReply? {
        guard bytes.count >= 4, bytes[0] == 0x05 else { return nil }
        guard bytes[1] == 0x00 else { return .failed(code: bytes[1]) }
        let atyp = bytes[3]
        switch atyp {
        case 0x01:
            guard bytes.count >= 10 else { return nil }
            let host = bytes[4...7].map { String($0) }.joined(separator: ".")
            let port = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
            return .succeeded(bindHost: host, bindPort: port)
        case 0x03:
            let len = Int(bytes[4])
            guard len >= 0, bytes.count >= 5 + len + 2 else { return nil }
            let host = String(bytes: bytes[5..<(5 + len)], encoding: .utf8) ?? ""
            let p0 = 5 + len
            let port = (UInt16(bytes[p0]) << 8) | UInt16(bytes[p0 + 1])
            return .succeeded(bindHost: host, bindPort: port)
        case 0x04:
            guard bytes.count >= 4 + 16 + 2 else { return nil }
            var parts: [String] = []
            var hex = ""
            for i in 4..<(4 + 16) {
                hex += String(format: "%02x", bytes[i])
                if hex.count == 4 {
                    parts.append(hex)
                    hex = ""
                }
            }
            let port = (UInt16(bytes[20]) << 8) | UInt16(bytes[21])
            return .succeeded(bindHost: parts.joined(separator: ":"), bindPort: port)
        default:
            return nil
        }
    }

    /// 解析 CONNECT 请求（测试用假代理服务器 / 单测）
    public static func parseConnectRequest(_ bytes: [UInt8]) -> (host: String, port: UInt16)? {
        guard bytes.count >= 4, bytes[0] == 0x05, bytes[1] == 0x01 else { return nil }
        let atyp = bytes[3]
        switch atyp {
        case 0x01:
            guard bytes.count >= 10 else { return nil }
            let host = bytes[4...7].map { String($0) }.joined(separator: ".")
            let port = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
            return (host, port)
        case 0x03:
            let len = Int(bytes[4])
            guard len > 0, bytes.count >= 5 + len + 2 else { return nil }
            let host = String(bytes: bytes[5..<(5 + len)], encoding: .utf8) ?? ""
            let p0 = 5 + len
            let port = (UInt16(bytes[p0]) << 8) | UInt16(bytes[p0 + 1])
            return (host, port)
        case 0x04:
            guard bytes.count >= 4 + 16 + 2 else { return nil }
            var raw: [UInt8] = Array(bytes[4..<20])
            var parts: [String] = []
            var hex = ""
            for b in raw {
                hex += String(format: "%02x", b)
                if hex.count == 4 {
                    parts.append(hex)
                    hex = ""
                }
            }
            let port = (UInt16(bytes[20]) << 8) | UInt16(bytes[21])
            return (parts.joined(separator: ":"), port)
        default:
            return nil
        }
    }
}

/// 本机回环隧道：入站（透明中继）→ SOCKS 代理（CONNECT 固定目标）→ 双向字节泵。
public final class Socks5Tunnel {
    public struct ProxyConfig {
        public var host: String
        public var port: UInt16
        public var username: String?
        public var password: String?

        public init(host: String, port: UInt16, username: String? = nil,
                    password: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    public private(set) var listenPort: UInt16 = 0
    private var serverChannel: Channel?
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let proxy: ProxyConfig
    /// CONNECT 固定目标（真实 db host:port）
    public var targetHost: String
    public var targetPort: UInt16

    public init(proxy: ProxyConfig, targetHost: String, targetPort: UInt16) {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// 在 127.0.0.1 随机端口启动隧道
    public func start() async throws -> UInt16 {
        let host = targetHost, port = targetPort, proxy = self.proxy
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(Socks5Error.handshakeFailed)
                }
                return channel.pipeline.addHandler(
                    RelayInboundHandler(tunnel: self, proxy: proxy,
                                        targetHost: host, targetPort: port))
            }
        let channel = try await awaitFuture(bootstrap.bind(host: "127.0.0.1", port: 0))
        serverChannel = channel
        listenPort = UInt16(channel.localAddress?.port ?? 0)
        return listenPort
    }

    public func destroy() async {
        if let ch = serverChannel {
            _ = try? await awaitFuture(ch.close())
            serverChannel = nil
        }
    }

    deinit {
        if let ch = serverChannel {
            _ = try? ch.close().wait()
        }
        _ = try? group.syncShutdownGracefully()
    }
}

// MARK: - 入站侧（透明中继；建流前缓存入站字节）

final class RelayInboundHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let tunnel: Socks5Tunnel
    private let proxy: Socks5Tunnel.ProxyConfig
    private let targetHost: String
    private let targetPort: UInt16
    private var pending = ByteBuffer()
    private var upstream: Channel?
    private var upstreamFailed = false

    init(tunnel: Socks5Tunnel, proxy: Socks5Tunnel.ProxyConfig,
         targetHost: String, targetPort: UInt16) {
        self.tunnel = tunnel
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// 连接建立即发起上游（经代理）建流
    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        let el = context.eventLoop
        let established = el.makePromise(of: Channel.self)
        let bootstrap = ClientBootstrap(group: el)
            .channelInitializer { ch in
                ch.pipeline.addHandler(
                    SocksUpHandler(proxy: self.proxy,
                                   targetHost: self.targetHost,
                                   targetPort: self.targetPort,
                                   established: established,
                                   inbound: context.channel))
            }
        bootstrap.connect(host: proxy.host, port: Int(proxy.port)).whenComplete { r in
            if case .failure(let e) = r {
                established.fail(e)
            }
        }
        established.futureResult.whenComplete { [weak self] result in
            switch result {
            case .success(let upCh):
                self?.upstream = upCh
                self?.flushPending(context)
            case .failure:
                self?.upstreamFailed = true
                context.close(promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var part = Self.unwrapInboundIn(data)
        if let upstream {
            upstream.writeAndFlush(part, promise: nil)
        } else {
            pending.writeBuffer(&part)   // 建流前缓存（MySQL 握手首包）
        }
    }

    private func flushPending(_ context: ChannelHandlerContext) {
        guard let upstream else { return }
        if pending.readableBytes > 0 {
            upstream.writeAndFlush(pending, promise: nil)
            pending = ByteBuffer()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - 出站侧（对代理的 SOCKS5 客户端握手 + 泵）

final class SocksUpHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private enum Phase { case greetingReply, authReply, connectReply, relaying }
    private var phase: Phase = .greetingReply
    private var accum = ByteBuffer()
    private let proxy: Socks5Tunnel.ProxyConfig
    private let targetHost: String
    private let targetPort: UInt16
    private let established: EventLoopPromise<Channel>
    private weak var inbound: Channel?
    private var settled = false

    init(proxy: Socks5Tunnel.ProxyConfig, targetHost: String, targetPort: UInt16,
         established: EventLoopPromise<Channel>, inbound: Channel) {
        self.proxy = proxy
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.established = established
        self.inbound = inbound
    }

    func channelActive(context: ChannelHandlerContext) {
        // 向代理发问候
        var methods: [Socks5Codec.AuthMethod] = [.noAuth]
        if proxy.username != nil || proxy.password != nil {
            methods = [.usernamePassword, .noAuth]
        }
        write(context, Socks5Codec.greeting(methods: methods))
        context.fireChannelActive()
    }

    private func write(_ context: ChannelHandlerContext, _ bytes: [UInt8]) {
        var buf = context.channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        context.writeAndFlush(NIOAny(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var part = Self.unwrapInboundIn(data)
        accum.writeBuffer(&part)
        switch phase {
        case .greetingReply:
            guard let bytes = accum.readBytes(length: 2) else { return }
            guard Socks5Codec.parseGreetingReply(bytes) != nil else {
                settleFail(Socks5Error.rejected(bytes.count > 1 ? bytes[1] : 0xFF)); return
            }
            if bytes[1] == Socks5Codec.AuthMethod.usernamePassword.rawValue {
                phase = .authReply
                write(context, Socks5Codec.auth(
                    username: proxy.username ?? "", password: proxy.password ?? ""))
            } else {
                phase = .connectReply
                write(context, Socks5Codec.connect(host: targetHost, port: targetPort))
            }
        case .authReply:
            guard let bytes = accum.readBytes(length: 2) else { return }
            guard Socks5Codec.parseAuthReply(bytes) else {
                settleFail(Socks5Error.rejected(0x01)); return
            }
            phase = .connectReply
            write(context, Socks5Codec.connect(host: targetHost, port: targetPort))
        case .connectReply:
            guard accum.readableBytes >= 4 else { return }
            guard let atyp = accum.getInteger(at: accum.readerIndex + 3, as: UInt8.self) else { return }
            let need: Int
            switch atyp {
            case 0x01: need = 10
            case 0x03: need = 5 + Int(accum.getInteger(at: accum.readerIndex + 4, as: UInt8.self) ?? 0) + 2
            case 0x04: need = 4 + 16 + 2
            default: settleFail(Socks5Error.handshakeFailed); return
            }
            guard accum.readableBytes >= need else { return }
            let bytes = accum.getBytes(at: accum.readerIndex, length: need) ?? []
            accum.moveReaderIndex(forwardBy: need)
            switch Socks5Codec.parseConnectReply(bytes) {
            case .succeeded:
                settleOK(context)
            case .failed(let code):
                settleFail(Socks5Error.rejected(code))
            case nil:
                settleFail(Socks5Error.handshakeFailed)
            }
        case .relaying:
            guard let inbound else { return }
            var b = accum
            accum = ByteBuffer()
            if b.readableBytes > 0 {
                inbound.writeAndFlush(b, promise: nil)
            }
        }
    }

    private func settleOK(_ context: ChannelHandlerContext) {
        guard !settled else { return }
        settled = true
        phase = .relaying
        established.succeed(context.channel)
    }

    private func settleFail(_ e: Error) {
        guard !settled else { return }
        settled = true
        established.fail(e)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settleFail(Socks5Error.handshakeFailed)
        inbound?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settleFail(error)
        context.close(promise: nil)
    }
}

public enum Socks5Error: Error {
    case handshakeFailed
    case rejected(UInt8)
}
