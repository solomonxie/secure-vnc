import CryptoKit
import Foundation
import LocalAuthentication
import NIOSSH
import Security

/// Creates SSH keys and loads them for signing. Private material lives only in the SecretStore
/// (Secure Enclave keys: an encrypted blob only this device's enclave can use).
public struct SSHKeyStore: Sendable {
    let secrets: SecretStore

    public init(secrets: SecretStore = KeychainStore()) { self.secrets = secrets }

    public static var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    public func generate(name: String, kind: SSHKeyKind, requireUserPresence: Bool) throws -> SSHKeyInfo {
        let id = UUID()
        let nioKey: NIOSSHPrivateKey
        switch kind {
        case .secureEnclaveP256:
            var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
            if requireUserPresence { flags.insert(.userPresence) }
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error)
            else { throw error!.takeRetainedValue() }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            try secrets.set(key.dataRepresentation, for: account(id), requireUserPresence: false)
            nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            try secrets.set(key.rawRepresentation, for: account(id), requireUserPresence: requireUserPresence)
            nioKey = NIOSSHPrivateKey(ed25519Key: key)
        }
        let comment = name.replacingOccurrences(of: " ", with: "-") + "@secure-vnc"
        return SSHKeyInfo(id: id, name: name, kind: kind, requiresUserPresence: requireUserPresence,
                          publicKey: String(openSSHPublicKey: nioKey.publicKey) + " " + comment,
                          createdAt: Date())
    }

    /// `context` should already be evaluated when the key requires user presence, so signing never blocks on a prompt.
    public func privateKey(for info: SSHKeyInfo, context: LAContext? = nil) throws -> NIOSSHPrivateKey {
        let data = try secrets.get(account(info.id), context: context)
        switch info.kind {
        case .secureEnclaveP256:
            return NIOSSHPrivateKey(secureEnclaveP256Key:
                try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data, authenticationContext: context))
        case .ed25519:
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: data))
        }
    }

    public func delete(_ info: SSHKeyInfo) { secrets.delete(account(info.id)) }

    private func account(_ id: UUID) -> String { "sshkey." + id.uuidString }
}
