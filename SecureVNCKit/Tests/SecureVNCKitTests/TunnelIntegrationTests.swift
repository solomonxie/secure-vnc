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

    func testRemoteFilesFollowShellDirectory() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "live", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        let shell = try await SSHTunnel.openShell(
            SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
            verifyHostKey: { _ in })
        defer { shell.close() }
        let work = dir.appendingPathComponent("work it").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        shell.send(Array("cd \(RemoteFiles.quote(work)); echo ready-$((1+1))\r".utf8))
        var out = ""
        while !out.contains("ready-2") {
            out += String(decoding: try await shell.readAvailable(), as: UTF8.self)
        }

        let files = RemoteFiles(tunnel: shell)
        let cwd = try await files.shellDirectory()
        XCTAssertTrue(cwd.hasSuffix("/work it"), cwd)

        try await files.writeText(work + "/a's.txt", "héllo\n")
        try await files.makeDirectory(work + "/sub")
        try await files.paste([work + "/a's.txt"], into: work, move: false)
        try await files.paste([work + "/a's.txt"], into: work + "/sub", move: true)
        try await files.rename(work + "/a's copy.txt", to: "b.txt")
        let names = try await files.list(work).map(\.name)
        XCTAssertEqual(names, ["sub", "b.txt"])
        let readBack = try await files.readText(work + "/sub/a's.txt")
        XCTAssertEqual(readBack, "héllo\n")
        try await files.remove([work + "/sub"])
        let after = try await files.list(work).map(\.name)
        XCTAssertEqual(after, ["b.txt"])
        do { _ = try await files.list(work + "/missing"); XCTFail("should fail") } catch RemoteFileError.failed {}
    }

    func testMacScreenLockStateMatchesRegistry() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "live", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        let shell = try await SSHTunnel.openShell(
            SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
            verifyHostKey: { _ in })
        defer { shell.close() }
        let locked = try await shell.macScreenLocked()
        let local = Process()
        local.executableURL = URL(fileURLWithPath: "/bin/sh")
        local.arguments = ["-c", #"ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'"#]
        try local.run()
        local.waitUntilExit()
        XCTAssertEqual(locked, local.terminationStatus == 0)
    }

    func testTmuxPaneMirror() async throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "live", kind: .ed25519, requireUserPresence: false)
        try startSSHD(authorizing: info.publicKey)
        let shell = try await SSHTunnel.openShell(
            SSHEndpoint(host: "127.0.0.1", port: 2222, username: NSUserName()), key: { try store.privateKey(for: info) },
            verifyHostKey: { _ in })
        defer { shell.close() }
        let socket = "securevnc-test-\(UUID().uuidString.prefix(8))"
        let panes = RemotePanes(tunnel: shell, socket: socket)
        let none = try await panes.list()
        XCTAssertEqual(none, [])
        _ = try await shell.exec(RemoteFiles.command(
            #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; tmux -L "$1" new-session -d -s t -x 80 -y 20 /bin/sh </dev/null >/dev/null 2>&1"#, [socket]))

        let list = try await panes.list()
        let pane = try XCTUnwrap(list.first)
        XCTAssertTrue(pane.target.hasPrefix("t:"), pane.target)
        try await panes.sendLine(pane.id, "echo pane-$((40+2))")
        var text = ""
        for _ in 0..<20 where !text.contains("pane-42") {
            try await Task.sleep(for: .milliseconds(150))
            text = try await panes.capture(pane.id)
        }
        XCTAssertTrue(text.contains("pane-42"), text)
        let path = try await panes.currentPath(pane.id)
        XCTAssertFalse(path.isEmpty)
        try await panes.sendKey(pane.id, "C-d")
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

    /// The phone is the SSH server; this Mac's own ssh client connects to it and wires up a shell.
    func startReverse(port: Int, identity: String) throws -> Process {
        let command = ReverseSSH.serverCommand(phone: "127.0.0.1", port: port)
            .replacingOccurrences(of: "/tmp/f", with: dir.appendingPathComponent("fifo").path)
            .replacingOccurrences(of: "ssh ", with: "ssh -i \(identity) -oIdentitiesOnly=yes -oIdentityAgent=none"
                + " -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin"]
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    /// The shell `script` started outlives the disconnect until it's interrupted, as with Ctrl-C.
    func stop(_ p: Process) {
        try? run("/usr/bin/pkill", ["-P", "\(p.processIdentifier)"])
        p.terminate()
    }

    func clientKey(_ name: String) throws -> (path: String, publicKey: String) {
        let path = dir.appendingPathComponent(name).path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path])
        return (path, try String(contentsOfFile: path + ".pub", encoding: .utf8))
    }

    func testReverseShellAndExecPerRun() async throws {
        let client = try clientKey("client")
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let phone = try store.generate(name: "phone", kind: .ed25519, requireUserPresence: false)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        for round in 1...2 {
            let mac = try startReverse(port: 2299, identity: client.path)
            defer { stop(mac) }
            let shell = try await SSHTunnel.acceptReverse(
                port: 2299, hostKey: hostKey, clientKey: client.publicKey, phoneKey: phone.publicKey, key: { try store.privateKey(for: phone) })
            shell.send(Array("echo reversed-$((\(round)+1)); tty\r".utf8))
            var out = ""
            while !(out.contains("reversed-\(round + 1)") && out.contains("/dev/tty")) {
                out += String(decoding: try await shell.readAvailable(), as: UTF8.self)
            }
            let exec = try await shell.exec("echo exec-$((2+3))")
            XCTAssertEqual(exec.text, "exec-5\n")
            shell.close()
        }
    }

    func testReverseShellRejectsOtherKey() async throws {
        let saved = try clientKey("saved")
        let other = try clientKey("other")
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let phone = try store.generate(name: "phone", kind: .ed25519, requireUserPresence: false)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let mac = try startReverse(port: 2297, identity: other.path)
        defer { stop(mac) }
        do {
            _ = try await SSHTunnel.acceptReverse(
                port: 2297, hostKey: hostKey, clientKey: saved.publicKey, phoneKey: phone.publicKey, key: { try store.privateKey(for: phone) })
            XCTFail("should reject")
        } catch SSHTunnelError.clientKeyRejected {} catch { XCTFail("\(error)") }
    }

    func testReverseLoginRejectsUnsetupPhoneKey() async throws {
        let client = try clientKey("client")
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let authorized = try store.generate(name: "a", kind: .ed25519, requireUserPresence: false)
        let phone = try store.generate(name: "b", kind: .ed25519, requireUserPresence: false)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let mac = try startReverse(port: 2296, identity: client.path)
        defer { stop(mac) }
        do {
            _ = try await SSHTunnel.acceptReverse(
                port: 2296, hostKey: hostKey, clientKey: client.publicKey, phoneKey: authorized.publicKey, key: { try store.privateKey(for: phone) })
            XCTFail("should reject")
        } catch SSHTunnelError.keyRejected {} catch { XCTFail("\(error)") }
    }

    func testCancelStopsListening() async throws {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let key = try clientKey("client").publicKey
        for _ in 1...2 {
            let task = Task { try await SSHTunnel.acceptReverse(port: 2298, hostKey: hostKey, clientKey: key, phoneKey: key, key: { fatalError() }) }
            try await Task.sleep(for: .milliseconds(300))
            task.cancel()
            if case .failure(SSHTunnelError.unreachable(let why)) = await task.result { XCTFail(why) }
        }
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
