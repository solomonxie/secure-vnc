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
    case vnc, terminal

    var label: String { self == .vnc ? "Screen" : "Terminal" }
    var symbol: String { self == .vnc ? "desktopcomputer" : "terminal" }
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
    var username = ""
    var keyID: UUID?
    var vncHost = "localhost"
    var vncPort = 5900
    var auth = VNCAuthKind.macOS
    var macUser = ""
    /// Trusted on first use: `SHA256:…` of the server's host key.
    var hostKeyFingerprint: String?

    var subtitle: String {
        "\(username)@\(sshHost)\(sshPort == 22 ? "" : ":\(sshPort)")" + (type == .vnc ? " → :\(vncPort)" : "")
    }
    var isComplete: Bool {
        !name.trimmed.isEmpty && !sshHost.trimmed.isEmpty && !username.trimmed.isEmpty && keyID != nil
            && (type == .terminal || !vncHost.trimmed.isEmpty)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
