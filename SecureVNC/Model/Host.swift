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

struct Host: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
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

    var subtitle: String { "\(username)@\(sshHost)\(sshPort == 22 ? "" : ":\(sshPort)") → :\(vncPort)" }
    var isComplete: Bool {
        !name.trimmed.isEmpty && !sshHost.trimmed.isEmpty && !username.trimmed.isEmpty && keyID != nil
            && !vncHost.trimmed.isEmpty
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
