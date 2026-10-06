import LocalAuthentication
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

    let host: Host
    private var store: AppStore?
    private var tunnel: SSHTunnel?
    private var task: Task<Void, Never>?
    private var trustReply: CheckedContinuation<Bool, Never>?
    private var generation = 0

    init(host: Host) { self.host = host }

    var installCommand: String { store?.key(host.keyID)?.installCommand ?? "" }

    func connect(store: AppStore) {
        self.store = store
        disconnect()
        generation += 1
        let gen = generation
        phase = .connecting("Connecting to \(host.sshHost)…")
        task = Task { await run(gen) }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        tunnel?.close()
        tunnel = nil
        client = nil
        answerTrust(false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func dropToBackground() {
        guard phase == .live || { if case .connecting = phase { return true } else { return false } }() else { return }
        disconnect()
        phase = .failed("Disconnected while in the background.", keyRejected: false)
    }

    func answerTrust(_ trusted: Bool) {
        trustPrompt = nil
        trustReply?.resume(returning: trusted)
        trustReply = nil
    }

    private func run(_ gen: Int) async {
        guard let store else { return }
        let host = store.host(self.host.id) ?? self.host
        do {
            guard let keyInfo = store.key(host.keyID) else {
                throw Failure("This host's key was deleted. Edit the host and pick another.")
            }
            var context: LAContext?
            if keyInfo.requiresUserPresence {
                let ctx = LAContext()
                try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock \(keyInfo.name) to connect")
                context = ctx
            }
            let key = try store.keyStore.privateKey(for: keyInfo, context: context)
            let expected = host.hostKeyFingerprint
            let tunnel = try await SSHTunnel.open(
                SSHEndpoint(host: host.sshHost, port: host.sshPort, username: host.username), key: key,
                verifyHostKey: { [weak self] pub in
                    let got = SSHFingerprint.of(pub)
                    if let expected {
                        guard expected == got else { throw SSHTunnelError.hostKeyChanged(expected: expected, got: got) }
                    } else {
                        guard let self, await self.askTrust(SSHFingerprint.algorithm(pub), got) else {
                            throw SSHTunnelError.hostKeyRejected
                        }
                        await store.trust(got, for: host.id)
                    }
                    await self?.status("Authenticating as \(host.username)…", gen)
                },
                targetHost: host.vncHost, targetPort: host.vncPort)
            guard gen == generation else { return tunnel.close() }
            self.tunnel = tunnel

            status("Starting VNC…", gen)
            let client = RFBClient(transport: tunnel)
            try await client.handshake(auth: vncAuth(host, store))
            guard gen == generation else { return }
            self.client = client
            phase = .live
            UIApplication.shared.isIdleTimerDisabled = true
            try await client.run()
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            disconnect()
            phase = .failed(message(error), keyRejected: { if case SSHTunnelError.keyRejected = error { true } else { false } }())
        }
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
