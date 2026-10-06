import Foundation
import SecureVNCKit

/// Hosts and key metadata as JSON in Application Support; every secret goes to the Keychain.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var hosts: [Host] = []
    @Published private(set) var keys: [SSHKeyInfo] = []

    let keyStore = SSHKeyStore()
    private let secrets = KeychainStore()
    private let dir: URL

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hosts = load("hosts.json") ?? []
        keys = load("keys.json") ?? []
    }

    // MARK: Hosts

    func save(_ host: Host, password: String?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        if let password {
            if password.isEmpty { secrets.delete(passwordAccount(host.id)) }
            else { try? secrets.set(Data(password.utf8), for: passwordAccount(host.id), requireUserPresence: false) }
        }
        persist(hosts, "hosts.json")
    }

    func delete(_ host: Host) {
        hosts.removeAll { $0.id == host.id }
        secrets.delete(passwordAccount(host.id))
        persist(hosts, "hosts.json")
    }

    func trust(_ fingerprint: String, for hostID: UUID) {
        guard let i = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[i].hostKeyFingerprint = fingerprint
        persist(hosts, "hosts.json")
    }

    func password(for hostID: UUID) -> String {
        (try? secrets.get(passwordAccount(hostID), context: nil)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func host(_ id: UUID) -> Host? { hosts.first { $0.id == id } }

    // MARK: Keys

    func generateKey(name: String, kind: SSHKeyKind, requireUserPresence: Bool) throws -> SSHKeyInfo {
        let info = try keyStore.generate(name: name, kind: kind, requireUserPresence: requireUserPresence)
        keys.append(info)
        persist(keys, "keys.json")
        return info
    }

    func delete(_ key: SSHKeyInfo) {
        keyStore.delete(key)
        keys.removeAll { $0.id == key.id }
        persist(keys, "keys.json")
    }

    func key(_ id: UUID?) -> SSHKeyInfo? { keys.first { $0.id == id } }

    // MARK: Files

    private func passwordAccount(_ id: UUID) -> String { "vncpw." + id.uuidString }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }
}
