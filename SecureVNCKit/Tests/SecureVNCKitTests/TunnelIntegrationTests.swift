import NIOSSH
import XCTest
@testable import SecureVNCKit

/// Runs a throwaway sshd on 127.0.0.1:2222 as the current user and tunnels to the local
/// Screen Sharing port. Opt in with SECUREVNC_LIVE=1.
final class TunnelIntegrationTests: XCTestCase {
    var sshd: Process?
    var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SECUREVNC_LIVE"] == "1")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("securevnc-sshd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("host").path])
    }

    override func tearDown() {
        if let pid = sshd?.processIdentifier { kill(pid, SIGKILL) }
    }

    func startSSHD(authorizing publicKey: String) throws {
        try publicKey.write(to: dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        let config = """
        Port 2222
        ListenAddress 127.0.0.1
        HostKey \(dir.appendingPathComponent("host").path)
        AuthorizedKeysFile \(dir.appendingPathComponent("authorized_keys").path)
        PidFile \(dir.appendingPathComponent("pid").path)
        UsePAM no
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        """
        try config.write(to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-e", "-f", dir.appendingPathComponent("sshd_config").path]
        try p.run()
        sshd = p
        Thread.sleep(forTimeInterval: 0.8)
    }

    func hostFingerprint() throws -> String {
        let line = try String(contentsOf: dir.appendingPathComponent("host.pub"), encoding: .utf8)
        return SSHFingerprint.of(openSSHPublicKey: line)!
    }

    func testTunnelReachesScreenSharing() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "live", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        let expected = try hostFingerprint()

        let tunnel = try await SSHTunnel.open(
            SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
            verifyHostKey: { key in
                let got = SSHFingerprint.of(key)
                guard got == expected else { throw SSHTunnelError.hostKeyChanged(expected: expected, got: got) }
            },
            targetHost: "localhost", targetPort: 5900)
        defer { tunnel.close() }
        let version = String(decoding: try await tunnel.read(12), as: UTF8.self)
        XCTAssertTrue(version.hasPrefix("RFB 003."), version)

        tunnel.send(Array("RFB 003.008\n".utf8))
        let n = Int(try await tunnel.read(1)[0])
        let types = try await tunnel.read(n)
        print("security types via tunnel:", types)
        XCTAssertTrue(types.contains(30))
    }

    func testShellRunsCommands() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "live", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        let shell = try await SSHTunnel.openShell(
            SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
            verifyHostKey: { _ in })
        defer { shell.close() }
        shell.send(Array("echo hi-$((1+2)); echo err >&2; tty\r".utf8))
        var out = ""
        while !(out.contains("hi-3") && out.contains("err") && out.contains("/dev/tty")) {
            out += String(decoding: try await shell.readAvailable(), as: UTF8.self)
        }
    }

    func testUnknownKeyIsRejected() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let allowed = try store.generate(name: "a", kind: .ed25519, requireUserPresence: false)
        let other = try store.generate(name: "b", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: allowed.publicKey)
        do {
            _ = try await SSHTunnel.open(
                SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: other) },
                verifyHostKey: { _ in }, targetHost: "localhost", targetPort: 5900)
            XCTFail("should not connect")
        } catch SSHTunnelError.keyRejected {} catch { XCTFail("\(error)") }
    }

    func testChangedHostKeyBlocks() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "a", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        do {
            _ = try await SSHTunnel.open(
                SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
                verifyHostKey: { key in throw SSHTunnelError.hostKeyChanged(expected: "SHA256:old", got: SSHFingerprint.of(key)) },
                targetHost: "localhost", targetPort: 5900)
            XCTFail("should not connect")
        } catch SSHTunnelError.hostKeyChanged {} catch { XCTFail("\(error)") }
    }

    func testClosedTargetPortReportsForwardFailure() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "a", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        do {
            _ = try await SSHTunnel.open(
                SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
                verifyHostKey: { _ in }, targetHost: "localhost", targetPort: 1)
            XCTFail("should not connect")
        } catch SSHTunnelError.forwardFailed {} catch { XCTFail("\(error)") }
    }

    private func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }
}

final class TunnelErrorTests: XCTestCase {
    func testRefusedPortIsDescribed() async {
        do {
            _ = try await SSHTunnel.open(SSHEndpoint(host: "127.0.0.1", port: 1, username: "x"), key: { fatalError() },
                                         verifyHostKey: { _ in }, targetHost: "localhost", targetPort: 5900)
            XCTFail()
        } catch SSHTunnelError.unreachable(let why) { XCTAssertEqual(why, "Connection refused") } catch { XCTFail("\(error)") }
    }
}
