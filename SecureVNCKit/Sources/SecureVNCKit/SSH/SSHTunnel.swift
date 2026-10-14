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
    case badClientKey
    case clientKeyRejected
    case closedBeforeShell
    case noServerSSHD

    public var errorDescription: String? {
        switch self {
        case .unreachable(let why): "Couldn't reach the SSH server: \(why)"
        case .keyRejected: "Key not accepted by the server"
        case .hostKeyRejected: "Host key not trusted"
        case .hostKeyChanged(let expected, let got):
            "Host key changed — possible attack.\nExpected \(expected)\nGot \(got)"
        case .forwardFailed(let host, let port): "Couldn't reach \(host):\(port) through SSH — is Screen Sharing on?"
        case .badClientKey: "The server's public key isn't valid. Paste one line like ssh-ed25519 AAAA…"
        case .clientKeyRejected: "The server connected with a key that isn't the one saved for this host."
        case .closedBeforeShell: "The server connected but closed before starting a shell."
        case .noServerSSHD: "The server's shell couldn't start a private sshd (needs /usr/sbin/sshd, ssh-keygen and nc there)."
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
    case waitingForServer
    case authenticating
}

/// `ssh -N -L` without the local listener: one direct-tcpip channel exposed as a ByteTransport.
public final class SSHTunnel: ByteTransport, @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    /// The TCP connection; closing it ends everything.
    private let link: Channel
    /// Where the client `NIOSSHHandler` lives: `link`, or a reverse session's channel inside it.
    private let connection: Channel
    private let child: Channel
    private let reader: ChunkReader

    private init(group: MultiThreadedEventLoopGroup, link: Channel, connection: Channel, child: Channel, reader: ChunkReader) {
        self.group = group
        self.link = link
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
        let target = SSHChannelType.DirectTCPIP(
            targetHost: targetHost, targetPort: targetPort,
            originatorAddress: try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
        return try await open(endpoint, key: key, verifyHostKey: verifyHostKey, channel: .directTCPIP(target), onStatus: onStatus)
    }

    /// A login shell on a `dumb` pty, so prompts like sudo's password and y/n questions work.
    public static func openShell(
        _ endpoint: SSHEndpoint, key: @escaping KeyProvider, verifyHostKey: @escaping HostKeyVerifier,
        columns: Int = 80, rows: Int = 24, onStatus: @escaping @Sendable (SSHTunnelStatus) -> Void = { _ in }
    ) async throws -> SSHTunnel {
        let tunnel = try await open(endpoint, key: key, verifyHostKey: verifyHostKey, channel: .session, onStatus: onStatus)
        try await tunnel.startShell(columns: columns, rows: rows)
        return tunnel
    }

    private func startShell(columns: Int, rows: Int) async throws {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false, term: "dumb", terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        try await child.triggerUserOutboundEvent(pty).get()
        try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false)).get()
    }

    /// Reverse: this device listens and the other machine's own `ssh` connects in with `clientKey`, its session
    /// carrying a login shell there (see `ReverseSSH`). Typed into that shell, `ReverseSSH.bootstrap` turns it into
    /// a pipe to a throwaway sshd that authorizes `phoneKey`, and this device logs in through it with `key` as
    /// the user that connected: a shell plus exec channels, like `openShell`.
    public static func acceptReverse(
        port: Int, hostKey: NIOSSHPrivateKey, clientKey: String, phoneKey: String, key: @escaping KeyProvider,
        columns: Int = 80, rows: Int = 24, onStatus: @escaping @Sendable (SSHTunnelStatus) -> Void = { _ in }
    ) async throws -> SSHTunnel {
        guard let allowed = try? NIOSSHPublicKey(openSSHPublicKey: clientKey.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw SSHTunnelError.badClientKey }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let state = FailureState()
        let auth = ClientKeyDelegate(allowed: allowed, state: state)
        let session = OneShot<ReverseSession>(group.next())
        let first = Latch()
        let bootstrap = ReverseSSH.bootstrap(phoneKey: phoneKey)
        let initialize: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
            channel.eventLoop.makeCompletedFuture {
                let ssh = NIOSSHHandler(
                    role: .server(.init(hostKeys: [hostKey], userAuthDelegate: auth)),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, type in
                        guard case .session = type, first.claim() else {
                            return child.eventLoop.makeFailedFuture(ChannelError.operationUnsupported)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            // The sshd's host key isn't checked: only the client already authenticated as
                            // `allowed` can produce this stream.
                            let login = ClientLogin(username: auth.username, key: key, verifyHostKey: { _ in }, onStatus: onStatus)
                            try child.pipeline.syncOperations.addHandler(SessionRequestHandler())
                            try child.pipeline.syncOperations.addHandler(ChannelBytesCodec())
                            try child.pipeline.syncOperations.addHandler(BootstrapHandler(command: bootstrap) { ready in
                                if ready {
                                    try login.install(on: child)
                                    session.succeed(ReverseSession(channel: child, login: login))
                                } else {
                                    session.fail(SSHTunnelError.noServerSSHD)
                                }
                            })
                        }
                    })
                try channel.pipeline.syncOperations.addHandler(ssh)
                try channel.pipeline.syncOperations.addHandler(ErrorRecorder(state: state))
            }
        }

        let link: Channel
        do {
            link = try await accept(group, port: port, initialize, onStatus)
        } catch {
            session.fail(error)
            try? await group.shutdownGracefully()
            throw error is CancellationError ? error : SSHTunnelError.unreachable(describe(error))
        }
        link.closeFuture.whenComplete { _ in session.fail(state.error ?? SSHTunnelError.closedBeforeShell) }
        let opened: ReverseSession
        do {
            opened = try await withTaskCancellationHandler {
                try await session.future.get()
            } onCancel: {
                session.fail(CancellationError())
            }
        } catch {
            try? await link.close()
            try? await group.shutdownGracefully()
            throw error
        }
        let tunnel: SSHTunnel
        do {
            tunnel = try await openChannel(group, link: link, connection: opened.channel, login: opened.login, .session)
        } catch SSHTunnelError.unreachable {
            throw SSHTunnelError.noServerSSHD
        }
        try await tunnel.startShell(columns: columns, rows: rows)
        return tunnel
    }

    private static func open(
        _ endpoint: SSHEndpoint, key: @escaping KeyProvider, verifyHostKey: @escaping HostKeyVerifier,
        channel channelType: SSHChannelType, onStatus: @escaping @Sendable (SSHTunnelStatus) -> Void
    ) async throws -> SSHTunnel {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let login = ClientLogin(username: endpoint.username, key: key, verifyHostKey: verifyHostKey, onStatus: onStatus)
        let link: Channel
        do {
            let bootstrap = ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try login.install(on: channel) } }
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            link = try await connect(bootstrap, endpoint, onStatus)
        } catch {
            try? await group.shutdownGracefully()
            throw SSHTunnelError.unreachable(describe(error))
        }
        return try await openChannel(group, link: link, connection: link, login: login, channelType)
    }

    /// Opens `channelType` once `login` has authenticated on `connection`; on failure tears down `link` and `group`.
    private static func openChannel(
        _ group: MultiThreadedEventLoopGroup, link: Channel, connection: Channel, login: ClientLogin,
        _ channelType: SSHChannelType
    ) async throws -> SSHTunnel {
        let userAuth = login.userAuth
        connection.eventLoop.execute { userAuth.connection = connection }
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        do {
            let child = try await connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(promise, channelType: channelType) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(TunnelDataHandler(continuation: continuation))
                    }
                }
                return promise.futureResult
            }.get()
            return SSHTunnel(group: group, link: link, connection: connection, child: child, reader: ChunkReader(stream))
        } catch {
            try? await link.close()
            try? await group.shutdownGracefully()
            if let cause = login.state.error { throw cause }
            if userAuth.exhausted { throw SSHTunnelError.keyRejected }
            if case .directTCPIP(let target) = channelType, error is ChannelError
                || "\(error)".contains("ChannelOpenFailure") || "\(error)".contains("channelSetupRejected") {
                throw SSHTunnelError.forwardFailed(host: target.targetHost, port: target.targetPort)
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

    /// Listens until the server connects; the first connection is used and the listener closed.
    private static func accept(
        _ group: EventLoopGroup, port: Int, _ initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>,
        _ onStatus: @Sendable (SSHTunnelStatus) -> Void
    ) async throws -> Channel {
        let accepted = group.next().makePromise(of: Channel.self)
        let first = Latch()
        let listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .childChannelInitializer { child in
                guard first.claim() else { return child.eventLoop.makeFailedFuture(ChannelError.alreadyClosed) }
                let ready = initialize(child)
                ready.whenComplete { result in
                    switch result {
                    case .success: accepted.succeed(child)
                    case .failure(let error): accepted.fail(error)
                    }
                }
                return ready
            }
            .bind(host: "0.0.0.0", port: port).get()
        defer { listener.close(promise: nil) }
        onStatus(.waitingForServer)
        return try await withTaskCancellationHandler {
            try await accepted.futureResult.get()
        } onCancel: {
            if first.claim() { accepted.fail(CancellationError()) }
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

    /// Whatever bytes arrive next; throws `TransportError.closed` at end of stream.
    public func readAvailable() async throws -> [UInt8] { try await reader.readAvailable() }

    public func send(_ bytes: [UInt8]) {
        var buf = child.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
    }

    public func resize(columns: Int, rows: Int) {
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)
        child.triggerUserOutboundEvent(event, promise: nil)
    }

    /// Runs a command on its own channel of this connection, sending `input` then EOF.
    public func exec(_ command: String, input: [UInt8] = []) async throws -> SSHExecResult {
        let connection = connection
        let result = connection.eventLoop.makePromise(of: SSHExecResult.self)
        _ = try await connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh in
            let promise = connection.eventLoop.makePromise(of: Channel.self)
            ssh.createChannel(promise, channelType: .session) { child, _ in
                child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMapThrowing {
                    try child.pipeline.syncOperations.addHandler(ExecHandler(command: command, input: input, result: result))
                }
            }
            return promise.futureResult
        }.get()
        return try await result.futureResult.get()
    }

    public func close() {
        link.close(promise: nil)
        group.shutdownGracefully { _ in }
    }
}

final class FailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?
    var error: Error? { lock.withLock { first } }
    func record(_ e: Error) { lock.withLock { if first == nil { first = e } } }
}

/// A promise that may be completed from several places; only the first completion counts.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let promise: EventLoopPromise<Value>
    private let first = Latch()
    var future: EventLoopFuture<Value> { promise.futureResult }

    init(_ loop: EventLoop) { promise = loop.makePromise() }
    func succeed(_ value: Value) { if first.claim() { promise.succeed(value) } }
    func fail(_ error: Error) { if first.claim() { promise.fail(error) } }
}

/// Lets in only the client key saved for the host. NIO SSH has already checked the signature.
final class ClientKeyDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    let allowed: NIOSSHPublicKey
    let state: FailureState
    /// Who the server's ssh logged in as; that machine's user, whose sshd it leads to.
    private(set) var username = ""
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey

    init(allowed: NIOSSHPublicKey, state: FailureState) {
        self.allowed = allowed
        self.state = state
    }

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard case .publicKey(let offer) = request.request else { return responsePromise.succeed(.failure) }
        if offer.publicKey == allowed {
            username = request.username
            return responsePromise.succeed(.success)
        }
        state.record(SSHTunnelError.clientKeyRejected)
        responsePromise.succeed(.failure)
    }
}

/// Accepts the reverse client's session requests; its shell request is passed on to start the bootstrap.
final class SessionRequestHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        let wantReply: Bool
        switch event {
        case let e as SSHChannelRequestEvent.ShellRequest: wantReply = e.wantReply
        case let e as SSHChannelRequestEvent.ExecRequest: wantReply = e.wantReply
        case let e as SSHChannelRequestEvent.PseudoTerminalRequest: wantReply = e.wantReply
        case let e as SSHChannelRequestEvent.EnvironmentRequest: wantReply = e.wantReply
        default: return context.fireUserInboundEventTriggered(event)
        }
        if wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        if event is SSHChannelRequestEvent.ShellRequest { context.fireUserInboundEventTriggered(event) }
    }
}

/// Types `command` into the shell, drops its output until an sshd's version line, then hands over:
/// `done(true)` adds the SSH client after this handler, which passes everything through from then on.
final class BootstrapHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let command: String
    let done: (Bool) throws -> Void
    private var seen: [UInt8] = []
    private var started = false
    private var ready = false
    private static let banner = Array("SSH-2.0-".utf8)

    init(command: String, done: @escaping (Bool) throws -> Void) {
        self.command = command
        self.done = done
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard event is SSHChannelRequestEvent.ShellRequest, !started else { return context.fireUserInboundEventTriggered(event) }
        started = true
        var buf = context.channel.allocator.buffer(capacity: command.utf8.count + 1)
        buf.writeString(command + "\r")
        context.writeAndFlush(wrapOutboundOut(buf), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !ready else { return context.fireChannelRead(data) }
        var buf = unwrapInboundIn(data)
        seen += buf.readBytes(length: buf.readableBytes) ?? []
        guard let start = Self.find(Self.banner, in: seen) else {
            if seen.count > 1 << 16 { seen.removeFirst(seen.count - Self.banner.count) }
            return
        }
        ready = true
        do {
            try done(true)
        } catch {
            return context.fireErrorCaught(error)
        }
        var rest = context.channel.allocator.buffer(capacity: seen.count - start)
        rest.writeBytes(seen[start...])
        seen = []
        context.fireChannelRead(wrapInboundOut(rest))
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !ready { try? done(false) }
        context.fireChannelInactive()
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        return (0...(hay.count - needle.count)).first { hay[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// A channel as a plain byte stream, so an SSH client can run over it.
final class ChannelBytesCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .channel = message.type, case .byteBuffer(let buf) = message.data else { return }
        context.fireChannelRead(wrapInboundOut(buf))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let message = SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))
        context.write(wrapOutboundOut(message), promise: promise)
    }
}

struct ReverseSession: @unchecked Sendable {
    let channel: Channel
    let login: ClientLogin
}

/// Client-side SSH handlers, for a TCP connection or a reverse session's byte stream.
final class ClientLogin: @unchecked Sendable {
    let state = FailureState()
    let userAuth: KeyAuthDelegate
    let serverAuth: HostKeyDelegate

    init(username: String, key: @escaping KeyProvider, verifyHostKey: @escaping HostKeyVerifier,
         onStatus: @escaping @Sendable (SSHTunnelStatus) -> Void) {
        userAuth = KeyAuthDelegate(username: username, key: key, state: state, onStatus: onStatus)
        serverAuth = HostKeyDelegate(verify: verifyHostKey, state: state)
    }

    func install(on channel: Channel) throws {
        let ssh = NIOSSHHandler(
            role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
            allocator: channel.allocator, inboundChildChannelInitializer: nil)
        try channel.pipeline.syncOperations.addHandler(ssh)
        try channel.pipeline.syncOperations.addHandler(ErrorRecorder(state: state))
    }
}

/// True for the first caller only.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
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
        guard case .byteBuffer(var buf) = message.data else { return }
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

public struct SSHExecResult: Sendable {
    public var status: Int
    public var output: [UInt8]
    public var error: [UInt8]

    public var text: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

final class ExecHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData
    let command: String
    let input: [UInt8]
    let result: EventLoopPromise<SSHExecResult>
    private var collected = SSHExecResult(status: -1, output: [], error: [])
    private var started = false
    private var done = false

    init(command: String, input: [UInt8], result: EventLoopPromise<SSHExecResult>) {
        self.command = command
        self.input = input
        self.result = result
    }

    func handlerAdded(context: ChannelHandlerContext) { if context.channel.isActive { start(context) } }

    func channelActive(context: ChannelHandlerContext) {
        start(context)
        context.fireChannelActive()
    }

    private func start(_ context: ChannelHandlerContext) {
        guard !started else { return }
        started = true
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false), promise: nil)
        if !input.isEmpty {
            var buf = context.channel.allocator.buffer(capacity: input.count)
            buf.writeBytes(input)
            context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: nil)
        }
        context.flush()
        context.close(mode: .output, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = message.data, let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        if case .channel = message.type { collected.output += bytes } else { collected.error += bytes }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus { collected.status = exit.exitStatus }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; result.fail(error) }
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    private func finish() {
        guard !done else { return }
        done = true
        result.succeed(collected)
    }
}
