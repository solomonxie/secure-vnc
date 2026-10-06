import CryptoKit
import Foundation
import NIOSSH

public enum SSHKeyKind: String, Codable, CaseIterable, Sendable {
    case secureEnclaveP256
    case ed25519

    public var label: String {
        switch self {
        case .secureEnclaveP256: "Secure Enclave"
        case .ed25519: "Ed25519"
        }
    }
}

public struct SSHKeyInfo: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let kind: SSHKeyKind
    public let requiresUserPresence: Bool
    /// OpenSSH `authorized_keys` line, including the comment.
    public let publicKey: String
    public let createdAt: Date

    public var fingerprint: String { SSHFingerprint.of(openSSHPublicKey: publicKey) ?? "" }
    public var installCommand: String {
        "mkdir -p ~/.ssh && echo '\(publicKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }
}

public enum SSHFingerprint {
    /// OpenSSH style `SHA256:<base64, no padding>` of the key blob.
    public static func of(openSSHPublicKey line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        let b64 = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }

    public static func of(_ key: NIOSSHPublicKey) -> String {
        of(openSSHPublicKey: String(openSSHPublicKey: key)) ?? ""
    }

    public static func algorithm(_ key: NIOSSHPublicKey) -> String {
        String(String(openSSHPublicKey: key).split(separator: " ").first ?? "")
    }
}
