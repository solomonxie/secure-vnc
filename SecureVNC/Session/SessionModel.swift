import LocalAuthentication
import Network
import SecureVNCKit
import SwiftUI

struct TrustPrompt: Identifiable {
    let id = UUID()
    let algorithm: String
    let fingerprint: String
}

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case connecting(String)
        case live
        case failed(String, keyRejected: Bool)
    }

    @Published var phase = Phase.connecting("")
    @Published var trustPrompt: TrustPrompt?
    @Published private(set) var client: RFBClient?
    @Published private(set) var terminal: Terminal?
    /// Shown over the screen while the saved password is being typed into the lock screen.
    @Published private(set) var unlocking = false
    @Published var unlockNote: String?
    let forwards = ForwardList()

    let host: Host
    private var store: AppStore?
    private var tunnel: SSHTunnel?
    private var shell: (any ShellChannel)?
    private var task: Task<Void, Never>?
    private var trustReply: CheckedContinuation<Bool, Never>?
    private var generation = 0
    private var inBackground = false
    private var backgroundedAt = Date.distantPast
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// A drop noticed in the background or just after returning reconnects silently.
    private var quietReconnectUntil: Date?

    init(host: Host) { self.host = host }

    /// The SSH connection, for stats and tools; nil for this iPhone.
    var sshTunnel: SSHTunnel? { tunnel ?? shell as? SSHTunnel }

    var installCommand: String { store?.key(host.keyID)?.installCommand ?? "" }

    /// What the server runs to connect to this iPhone; nil off Wi-Fi.
    var reverseCommand: String? {
        Network.wifiAddress.map { ReverseSSH.serverCommand(phone: $0, port: host.sshPort) }
    }

    /// What the server's ssh shows when asked to trust this iPhone the first time.
    var reverseFingerprint: String? {
        (try? store?.keyStore.reverseHostKey()).map { SSHFingerprint.of($0.publicKey) }
    }

    func connect(store: AppStore) {
        self.store = store
        disconnect()
        generation += 1
        let gen = generation
        phase = .connecting(host.type == .local ? "Starting…" : host.reverse ? "Opening port \(host.sshPort)…" : "Connecting to \(host.sshHost)…")
        task = Task { await run(gen) }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        tunnel?.close()
        tunnel = nil
        shell?.close()
        shell = nil
        client = nil
        terminal?.detach()
        forwards.closeAll()
        answerTrust(false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// iOS gives a few seconds to finish work before suspending; a dead link is mended on return.
    func enterBackground() {
        inBackground = true
        backgroundedAt = Date()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
    }

    func enterForeground() {
        guard inBackground else { return }
        inBackground = false
        endBackgroundTask()
        // The server's ssh gives up on a suspended phone within ~15s and keeps retrying, so after a longer
        // trip listen again at once rather than wait for the stale link to fail.
        if host.reverse, Date().timeIntervalSince(backgroundedAt) > 8, let store {
            quietReconnectUntil = nil
            connect(store: store)
        } else if case .failed = phase, quietReconnectUntil != nil, let store {
            quietReconnectUntil = nil
            connect(store: store)
        } else {
            quietReconnectUntil = Date().addingTimeInterval(5)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func answerTrust(_ trusted: Bool) {
        trustPrompt = nil
        trustReply?.resume(returning: trusted)
        trustReply = nil
    }

    private func run(_ gen: Int) async {
        guard let store else { return }
        let host = store.host(self.host.id) ?? self.host
        let onStatus: @Sendable (SSHTunnelStatus) -> Void = { [weak self] status in
            let text = switch status {
            case .waitingForNetwork: "Waiting for local network access…"
            case .waitingForServer: "Waiting for the server to connect…"
            case .authenticating: host.reverse ? "Starting a private sshd there…" : "Authenticating as \(host.username)…"
            }
            Task { @MainActor in self?.status(text, gen) }
        }
        do {
            if host.type == .local { return try await runTerminal(LocalShell(files: store.places.files), gen) }
            guard let keyInfo = store.key(host.keyID) else {
                throw Failure("This host's key was deleted. Edit the host and pick another.")
            }
            let keyStore = store.keyStore
            let key: KeyProvider = {
                var context: LAContext?
                if keyInfo.requiresUserPresence {
                    let ctx = LAContext()
                    try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock \(keyInfo.name) to connect")
                    context = ctx
                }
                return try keyStore.privateKey(for: keyInfo, context: context)
            }
            if host.reverse {
                guard Network.wifiAddress != nil else { throw Failure("Join the server's Wi-Fi so it can connect to this iPhone.") }
                let tunnel = try await SSHTunnel.acceptReverse(
                    port: host.sshPort, hostKey: keyStore.reverseHostKey(), clientKey: host.serverPublicKey,
                    phoneKey: keyInfo.publicKey, key: key,
                    onStatus: onStatus)
                return try await runTerminal(tunnel, gen)
            }
            if Network.offLAN(host.sshHost) {
                throw Failure("Couldn't reach \(host.sshHost)." + Network.hint(for: host.sshHost))
            }
            let expected = host.hostKeyFingerprint
            let endpoint = SSHEndpoint(host: host.sshHost, port: host.sshPort, username: host.username)
            let verify: HostKeyVerifier = { [weak self] pub in
                let got = SSHFingerprint.of(pub)
                if let expected {
                    guard expected == got else { throw SSHTunnelError.hostKeyChanged(expected: expected, got: got) }
                } else {
                    guard let self, await self.askTrust(SSHFingerprint.algorithm(pub), got) else {
                        throw SSHTunnelError.hostKeyRejected
                    }
                    await store.trust(got, for: host.id)
                }
            }

            if host.type == .terminal {
                return try await runTerminal(SSHTunnel.openShell(endpoint, key: key, verifyHostKey: verify, onStatus: onStatus), gen)
            }

            let tunnel = try await SSHTunnel.open(
                endpoint, key: key, verifyHostKey: verify,
                targetHost: host.vncHost, targetPort: host.vncPort, onStatus: onStatus)
            guard gen == generation else { return tunnel.close() }
            self.tunnel = tunnel

            status("Starting VNC…", gen)
            let client = RFBClient(transport: tunnel)
            try await client.handshake(auth: vncAuth(host, store))
            guard gen == generation else { return }
            self.client = client
            phase = .live
            UIApplication.shared.isIdleTimerDisabled = true
            if canUnlock { Task { await unlockIfLocked(automatic: true) } }
            try await client.run()
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            let wasLive = phase == .live
            disconnect()
            phase = .failed(message(error), keyRejected: { if case SSHTunnelError.keyRejected = error { true } else { false } }())
            guard wasLive else { return }
            if inBackground {
                quietReconnectUntil = .distantFuture
            } else if let until = quietReconnectUntil, Date() < until {
                quietReconnectUntil = nil
                connect(store: store)
            } else {
                terminal?.note(message(error))
            }
        }
    }

    private func runTerminal(_ shell: any ShellChannel, _ gen: Int) async throws {
        guard gen == generation else { return shell.close() }
        self.shell = shell
        let terminal = self.terminal ?? Terminal()
        terminal.attach(shell)
        self.terminal = terminal
        phase = .live
        try await terminal.run()
    }

    private func status(_ text: String, _ gen: Int) {
        guard gen == generation, case .connecting = phase else { return }
        phase = .connecting(text)
    }

    private func askTrust(_ algorithm: String, _ fingerprint: String) async -> Bool {
        await withCheckedContinuation { cont in
            trustReply = cont
            trustPrompt = TrustPrompt(algorithm: algorithm, fingerprint: fingerprint)
        }
    }

    /// The lock screen can be unlocked with the saved macOS password.
    var canUnlock: Bool { host.auth == .macOS && !(store?.password(for: host.id).isEmpty ?? true) }

    func unlock() { Task { await unlockIfLocked(automatic: false) } }

    /// Types the saved password into the lock screen, but only while the Mac reports its screen
    /// locked, so it can never land in an open window. Confirms over SSH and retries.
    private func unlockIfLocked(automatic: Bool) async {
        guard !unlocking, let tunnel, let store, canUnlock else { return }
        let gen = generation
        guard let locked = try? await tunnel.macScreenLocked() else {
            if !automatic { unlockNote = "Couldn't read the Mac's lock state." }
            return
        }
        guard locked else {
            if !automatic { unlockNote = "Already unlocked." }
            return
        }
        unlocking = true
        defer { unlocking = false }
        let password = store.password(for: host.id)
        // A sleeping Mac takes a moment to bring the display up after the connection wakes it.
        if automatic { try? await Task.sleep(for: .milliseconds(1500)) }
        for _ in 0..<3 {
            guard gen == generation, let client = self.client,
                  (try? await tunnel.macScreenLocked()) == true else { return }
            Self.tap(client, KeySym.shift)
            try? await Task.sleep(for: .milliseconds(800))
            Self.clearField(client)
            for ch in password.unicodeScalars { Self.type(client, ch) }
            Self.tap(client, KeySym.enter)
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(400))
                if (try? await tunnel.macScreenLocked()) == false { return }
            }
        }
        if gen == generation { unlockNote = "Couldn't unlock. Check the saved macOS password." }
    }

    /// ⌘A then Delete, so a retry doesn't append to a half-typed password.
    private static func clearField(_ client: RFBClient) {
        client.key(KeySym.command, down: true)
        tap(client, 0x61)
        client.key(KeySym.command, down: false)
        tap(client, KeySym.backspace)
    }

    private static let shifted = Set(#"~!@#$%^&*()_+{}|:"<>?"#.unicodeScalars)

    /// X11 keysyms match Latin-1 code points; Shift is held for characters that need it on a US layout.
    private static func type(_ client: RFBClient, _ ch: Unicode.Scalar) {
        let sym = ch.value < 0x100 ? ch.value : 0x0100_0000 + ch.value
        let shift = shifted.contains(ch) || ("A"..."Z").contains(ch)
        if shift { client.key(KeySym.shift, down: true) }
        tap(client, sym)
        if shift { client.key(KeySym.shift, down: false) }
    }

    private static func tap(_ client: RFBClient, _ sym: UInt32) {
        client.key(sym, down: true)
        client.key(sym, down: false)
    }

    private func vncAuth(_ host: Host, _ store: AppStore) -> VNCAuth {
        let password = store.password(for: host.id)
        switch host.auth {
        case .none: return .none
        case .password: return .password(password)
        case .macOS: return .macOS(username: host.macUser.isEmpty ? host.username : host.macUser, password: password)
        }
    }

    private func message(_ error: Error) -> String {
        switch error {
        case SSHTunnelError.keyRejected:
            "Key not accepted by \(host.username)@\(host.sshHost). Add its public key to ~/.ssh/authorized_keys there."
        case let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel:
            "Unlock cancelled."
        case SSHTunnelError.unreachable(let why) where host.reverse:
            "Couldn't listen on port \(host.sshPort): \(why)"
        case SSHTunnelError.unreachable:
            error.localizedDescription + Network.hint(for: host.sshHost)
        case TransportError.closed:
            "Disconnected."
        case RFBError.authFailed:
            host.auth == .macOS ? "macOS login rejected. Check the account name and password." : "VNC password rejected."
        default:
            error.localizedDescription
        }
    }
}

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Explains the usual reason a LAN address fails from a phone.
enum Network {
    private static let monitor: NWPathMonitor = {
        let m = NWPathMonitor()
        m.start(queue: DispatchQueue(label: "network-path"))
        return m
    }()

    static func start() { _ = monitor }

    static func isLAN(_ host: String) -> Bool {
        host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
            || host.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
    }

    /// True when a LAN host can't possibly be reached: the path is known and has neither Wi-Fi nor Ethernet.
    static func offLAN(_ host: String) -> Bool {
        let path = monitor.currentPath
        return isLAN(host) && path.status != .requiresConnection && !path.availableInterfaces.isEmpty
            && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet)
    }

    /// This iPhone's IPv4 address on Wi-Fi.
    static var wifiAddress: String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: entry.pointee.ifa_name) == "en0", let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            return String(cString: name)
        }
        return nil
    }

    static func hint(for host: String) -> String {
        guard isLAN(host) else { return "" }
        if offLAN(host) {
            return "\n\nThis iPhone isn't on Wi-Fi. \(host) is only reachable from your local network."
        }
        return "\n\nIf this is the first connection, check Settings → Privacy & Security → Local Network → Secure VNC is on."
    }
}
