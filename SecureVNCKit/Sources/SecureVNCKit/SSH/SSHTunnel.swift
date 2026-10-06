import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public enum SSHTunnelError: Error, LocalizedError {
    case unreachable(String)
    case keyRejected
    case hostKeyRejected
    case hostKeyChanged(expected: String, got: String)
    case forwardFailed(host: String, port: Int)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Couldn't reach the SSH server: \(why)"
        case .keyRejected: "Key not accepted by the server"
        case .hostKeyRejected: "Host key not trusted"
        case .hostKeyChanged(let expected, let got):
            "Host key changed — possible attack.\nExpected \(expected)\nGot \(got)"
        case .forwardFailed(let host, let port): "Couldn't reach \(host):\(port) through SSH — is Screen Sharing on?"
        }
    }
}

public struct SSHEndpoint: Sendable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// Decides whether to trust a server's host key; throw to refuse with a specific reason.
public typealias HostKeyVerifier = @Sendable (NIOSSHPublicKey) async throws -> Void
public typealias KeyProvider = @Sendable () async throws -> NIOSSHPrivateKey

public enum SSHTunnelStatus: Sendable {
    case waitingForNetwork
    case authenticating
}

/// `ssh -N -L` without the local listener: one direct-tcpip channel exposed as a ByteTransport.
public final class SSHTunnel: ByteTransport, @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let connection: Channel
    private let child: Channel
    private let reader: ChunkReader

    private init(group: MultiThreadedEventLoopGroup, connection: Channel, child: Channel, reader: ChunkReader) {
        self.group = group
        self.connection = connection
        self.child = child
        self.reader = reader
    }

    /// `key` is loaded only once the server is reachable and trusted and asks for auth,
    /// so a Face ID prompt never appears for a connection that was going to fail anyway.
    public static func open(
        _ endpoint: SSHEndpoint, key: @escaping KeyProvider, verifyHostKey: @escaping HostKeyVerifier,
        targetHost: String, targetPort: Int, onStatus: @escaping @Sendable (SSHTunnelStatus) -> Void = { _ in }
    ) async throws -> SSHTunnel {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = FailureState()
        let userAuth = KeyAuthDelegate(username: endpoint.username, key: key, state: state, onStatus: onStatus)
        let serverAuth = HostKeyDelegate(verify: verifyHostKey, state: state)

        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(ErrorRecorder(state: state))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let connection: Channel
        do {
            connection = try await connect(bootstrap, endpoint, onStatus)
        } catch {
            try? await group.shutdownGracefully()
            throw SSHTunnelError.unreachable(describe(error))
        }

        connection.eventLoop.execute { userAuth.connection = connection }
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        do {
            let child = try await connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                let target = SSHChannelType.DirectTCPIP(
                    targetHost: targetHost, targetPort: targetPort,
                    originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                ssh.createChannel(promise, channelType: .directTCPIP(target)) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(TunnelDataHandler(continuation: continuation))
                    }
                }
                return promise.futureResult
            }.get()
            return SSHTunnel(group: group, connection: connection, child: child, reader: ChunkReader(stream))
        } catch {
            try? await connection.close()
            try? await group.shutdownGracefully()
            if let cause = state.error { throw cause }
            if userAuth.exhausted { throw SSHTunnelError.keyRejected }
            if error is ChannelError || "\(error)".contains("ChannelOpenFailure") || "\(error)".contains("channelSetupRejected") {
                throw SSHTunnelError.forwardFailed(host: targetHost, port: targetPort)
            }
            throw SSHTunnelError.unreachable(error.localizedDescription)
        }
    }

    /// Retries fast failures for a while: on first use iOS fails LAN connects while its
    /// Local Network permission alert is still on screen.
    private static func connect(_ bootstrap: ClientBootstrap, _ endpoint: SSHEndpoint,
                                _ onStatus: @Sendable (SSHTunnelStatus) -> Void) async throws -> Channel {
        let deadline = Date().addingTimeInterval(20)
        while true {
            let started = Date()
            do {
                return try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
            } catch {
                let quick = Date().timeIntervalSince(started) < 3
                guard quick, Date() < deadline, !errnos(error).contains(ECONNREFUSED) else { throw error }
                onStatus(.waitingForNetwork)
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func errnos(_ error: Error) -> [CInt] {
        if let e = error as? IOError { return [e.errnoCode] }
        if let e = error as? NIOConnectionError { return e.connectionErrors.compactMap { ($0.error as? IOError)?.errnoCode } }
        return []
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? NIOConnectionError {
            if let dns = e.dnsAError ?? e.dnsAAAAError { return "can't resolve \(e.host) (\(dns))" }
            if let code = errnos(error).first { return String(cString: strerror(code)) }
            if e.connectionErrors.isEmpty { return "no address found for \(e.host)" }
        }
        if let e = error as? IOError { return String(cString: strerror(e.errnoCode)) }
        if error is ChannelError { return "timed out" }
        return error.localizedDescription
    }

    public func read(_ count: Int) async throws -> [UInt8] { try await reader.read(count) }

    public func send(_ bytes: [UInt8]) {
        var buf = child.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
    }

    public func close() {
        connection.close(promise: nil)
        group.shutdownGracefully { _ in }
    }
}

final class FailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?
    var error: Error? { lock.withLock { first } }
    func record(_ e: Error) { lock.withLock { if first == nil { first = e } } }
}

final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: KeyProvider
    let state: FailureState
    let onStatus: @Sendable (SSHTunnelStatus) -> Void
    private(set) var exhausted = false
    private var offered = false
    /// Closed on rejection; NIO SSH would otherwise wait out the server's login grace time.
    var connection: Channel?

    init(username: String, key: @escaping KeyProvider, state: FailureState,
         onStatus: @escaping @Sendable (SSHTunnelStatus) -> Void) {
        self.username = username
        self.key = key
        self.state = state
        self.onStatus = onStatus
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            exhausted = true
            state.record(SSHTunnelError.keyRejected)
            nextChallengePromise.succeed(nil)
            connection?.close(promise: nil)
            return
        }
        offered = true
        onStatus(.authenticating)
        let (username, key, state, connection) = (username, key, state, connection)
        Task {
            do {
                let privateKey = try await key()
                nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .privateKey(.init(privateKey: privateKey))))
            } catch {
                state.record(error)
                nextChallengePromise.succeed(nil)
                connection?.close(promise: nil)
            }
        }
    }
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let verify: HostKeyVerifier
    let state: FailureState

    init(verify: @escaping HostKeyVerifier, state: FailureState) {
        self.verify = verify
        self.state = state
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        Task {
            do {
                try await verify(hostKey)
                validationCompletePromise.succeed(())
            } catch {
                state.record(error)
                validationCompletePromise.fail(error)
            }
        }
    }
}

final class ErrorRecorder: ChannelInboundHandler {
    typealias InboundIn = Any
    let state: FailureState
    init(state: FailureState) { self.state = state }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        state.record(error)
        context.close(promise: nil)
    }
}

final class TunnelDataHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    init(continuation: AsyncThrowingStream<[UInt8], Error>.Continuation) { self.continuation = continuation }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(var buf) = message.data else { return }
        if let bytes = buf.readBytes(length: buf.readableBytes) { continuation.yield(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, e == .inputClosed { continuation.finish() }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }
}
