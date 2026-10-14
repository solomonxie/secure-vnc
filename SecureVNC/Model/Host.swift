import Foundation

enum VNCAuthKind: String, Codable, CaseIterable {
    case macOS, password, none

    var label: String {
        switch self {
        case .macOS: "macOS"
        case .password: "VNC"
        case .none: "None"
        }
    }
}

enum ConnectionType: String, Codable, CaseIterable {
    /// `reverse`: a terminal where the server connects out to this phone, for a server that can't accept connections.
    case vnc, terminal, reverse

    var label: String {
        switch self {
        case .vnc: "Screen"
        case .terminal: "Terminal"
        case .reverse: "Reverse"
        }
    }
    var symbol: String {
        switch self {
        case .vnc: "desktopcomputer"
        case .terminal: "terminal"
        case .reverse: "arrow.uturn.backward"
        }
    }
}

struct Host: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    /// Optional so hosts saved before terminal support still decode.
    private var connection: ConnectionType?
    var type: ConnectionType {
        get { connection ?? .vnc }
        set { connection = newValue }
    }
    var sshHost = ""
    var sshPort = 22
    /// `sshPort` is then this phone's listen port.
    var reverse: Bool { type == .reverse }
    private var reverseClientKey: String?
    /// Reverse: the OpenSSH public key the server's own ssh client connects with.
    var serverPublicKey: String {
        get { reverseClientKey ?? "" }
        set { reverseClientKey = newValue }
    }
    var username = ""
    var keyID: UUID?
    var vncHost = "localhost"
    var vncPort = 5900
    var auth = VNCAuthKind.macOS
    var macUser = ""
    /// Trusted on first use: `SHA256:…` of the server's host key.
    var hostKeyFingerprint: String?

    var subtitle: String {
        (reverse ? "reverse · listens on :\(sshPort)" : "\(username)@\(sshHost)\(sshPort == 22 ? "" : ":\(sshPort)")") + (type == .vnc ? " → :\(vncPort)" : "")
    }
    var isComplete: Bool {
        if reverse { return !name.trimmed.isEmpty && !serverPublicKey.trimmed.isEmpty && keyID != nil }
        return !name.trimmed.isEmpty && !sshHost.trimmed.isEmpty && !username.trimmed.isEmpty && keyID != nil
            && (type != .vnc || !vncHost.trimmed.isEmpty)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
