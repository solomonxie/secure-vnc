import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// `ssh -L 127.0.0.1:<random>:host:port`: a loopback listener on this device whose connections each
/// go through a new direct-tcpip channel. Lives until closed or the SSH connection ends.
public final class PortForward: @unchecked Sendable, Identifiable {
    public let id = UUID()
    public let targetHost: String
    public let targetPort: Int
    public let localPort: Int
    private let listener: Channel

    init(targetHost: String, targetPort: Int, listener: Channel) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.listener = listener
        localPort = listener.localAddress?.port ?? 0
    }

    public var url: URL? {
        let scheme = [443, 8443].contains(targetPort) ? "https" : "http"
        return URL(string: "\(scheme)://127.0.0.1:\(localPort)/")
    }

    public func close() { listener.close(promise: nil) }
}

extension SSHTunnel {
    public func forward(to host: String, port: Int) async throws -> PortForward {
        let connection = connection
        let listener = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { local in
                let (a, b) = GlueHandler.pair()
                let origin = (try? SocketAddress(ipAddress: "127.0.0.1", port: local.remoteAddress?.port ?? 0))!
                let target = SSHChannelType.DirectTCPIP(targetHost: host, targetPort: port, originatorAddress: origin)
                return connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                    let promise = connection.eventLoop.makePromise(of: Channel.self)
                    ssh.createChannel(promise, channelType: .directTCPIP(target)) { child, _ in
                        child.pipeline.addHandlers([ChannelBytesCodec(), b])
                    }
                    return promise.futureResult
                }
                .hop(to: local.eventLoop)
                .flatMap { _ in local.pipeline.addHandler(a) }
                .map { local.setOption(ChannelOptions.autoRead, value: true).whenSuccess { local.read() } }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        connection.closeFuture.whenComplete { _ in listener.close(promise: nil) }
        return PortForward(targetHost: host, targetPort: port, listener: listener)
    }
}

/// Passes bytes between two channels; when one closes, so does the other.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?

    static func pair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.send(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }

    func channelInactive(context: ChannelHandlerContext) { partner?.context?.close(promise: nil) }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, e == .inputClosed { partner?.context?.close(promise: nil) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    private func send(_ buf: ByteBuffer) {
        guard let context else { return }
        if context.eventLoop.inEventLoop {
            context.write(wrapOutboundOut(buf), promise: nil)
        } else {
            context.eventLoop.execute { context.writeAndFlush(self.wrapOutboundOut(buf), promise: nil) }
        }
    }
}
