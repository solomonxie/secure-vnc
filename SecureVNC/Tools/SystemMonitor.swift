import SecureVNCKit
import SwiftUI

/// Live stats for a server over SSH, or for this iPhone when `remote` is nil.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var stats: SystemStats?
    @Published private(set) var error: String?
    @Published private(set) var awake: Bool?
    @Published private(set) var publicIP: PublicIP?
    @Published private(set) var lookingUp = false
    @Published var toolError: String?

    let remote: RemoteSystem?
    let tunnel: SSHTunnel?

    init(tunnel: SSHTunnel?) {
        self.tunnel = tunnel
        remote = tunnel.map(RemoteSystem.init)
    }

    var isDevice: Bool { remote == nil }

    func run() async {
        if let remote { awake = try? await remote.keepingAwake() }
        var previous: SystemStats?
        while !Task.isCancelled {
            do {
                let next = try await remote?.stats() ?? DeviceStats.sample()
                stats = next.updatingRates(from: previous)
                previous = next
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(stats?.cpuUsage == nil && error == nil ? 0.5 : 2))
        }
    }

    func setAwake(_ on: Bool) {
        guard let remote else { return }
        Task {
            do {
                try await remote.keepAwake(on)
            } catch {
                toolError = error.localizedDescription
            }
            awake = try? await remote.keepingAwake()
        }
    }

    func lookUpPublicIP() {
        lookingUp = true
        Task {
            defer { lookingUp = false }
            do {
                if let remote {
                    publicIP = try await remote.publicIP()
                } else {
                    let (data, _) = try await URLSession.shared.data(from: PublicIP.url)
                    publicIP = try PublicIP.decode(Array(data))
                }
            } catch {
                toolError = "Public IP lookup failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Port forwards of one SSH connection; closed with it.
@MainActor
final class ForwardList: ObservableObject {
    @Published private(set) var forwards: [PortForward] = []

    func add(_ forward: PortForward) { forwards.append(forward) }

    func remove(_ forward: PortForward) {
        forward.close()
        forwards.removeAll { $0.id == forward.id }
    }

    func closeAll() {
        forwards.forEach { $0.close() }
        forwards = []
    }
}

enum Format {
    static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory) }
    static func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let r = bytesPerSecond else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(r), countStyle: .file) + "/s"
    }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func uptime(since boot: Date) -> String {
        let s = Int(Date().timeIntervalSince(boot))
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
