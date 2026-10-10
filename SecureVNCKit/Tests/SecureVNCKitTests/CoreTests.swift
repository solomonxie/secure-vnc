import BigInt
import CommonCrypto
import CryptoKit
import XCTest
import zlib
@testable import SecureVNCKit

final class FakeTransport: ByteTransport {
    var incoming: [UInt8]
    var sent: [UInt8] = []
    init(_ incoming: [UInt8]) { self.incoming = incoming }
    func read(_ count: Int) async throws -> [UInt8] {
        guard incoming.count >= count else { throw TransportError.closed }
        defer { incoming.removeFirst(count) }
        return Array(incoming.prefix(count))
    }
    func send(_ bytes: [UInt8]) { sent += bytes }
    func close() {}
}

func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

final class KeyTests: XCTestCase {
    func testEd25519KeyMatchesSSHKeygenFingerprint() throws {
        let store = SSHKeyStore(secrets: MemorySecretStore())
        let info = try store.generate(name: "test key", kind: .ed25519, requireUserPresence: false)
        XCTAssertTrue(info.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(info.publicKey.hasSuffix(" test-key@secure-vnc"))
        _ = try store.privateKey(for: info)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("k.pub")
        try info.publicKey.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-lf", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(out.contains(info.fingerprint), "\(out) vs \(info.fingerprint)")
    }
}

final class RFBTests: XCTestCase {
    func serverInit(w: Int, h: Int) -> [UInt8] {
        be16(w) + be16(h) + [UInt8](repeating: 0, count: 16) + be32(3) + Array("Mac".utf8)
    }

    func testHandshakeNoneAndRawUpdate() async throws {
        var s = Array("RFB 003.889\n".utf8) + [1, 1] + be32(0) + serverInit(w: 4, h: 2)
        s += [0, 0] + be16(1) + be16(1) + be16(1) + be16(2) + be16(1) + be32(0)
        s += [0x33, 0x22, 0x11, 0, 0x66, 0x55, 0x44, 0]
        let t = FakeTransport(s)
        let c = RFBClient(transport: t)
        try await c.handshake(auth: .none)
        XCTAssertEqual(c.desktopName, "Mac")
        XCTAssertEqual(Array(t.sent.prefix(13)), Array("RFB 003.008\n".utf8) + [1])
        do { try await c.run() } catch TransportError.closed {}
        XCTAssertEqual(c.framebuffer.pixel(x: 1, y: 1), 0x112233)
        XCTAssertEqual(c.framebuffer.pixel(x: 2, y: 1), 0x445566)
        XCTAssertEqual(c.framebuffer.pixel(x: 0, y: 0), 0)
    }

    func testUnsupportedSecurity() async {
        let t = FakeTransport(Array("RFB 003.889\n".utf8) + [2, 33, 36])
        do {
            try await RFBClient(transport: t).handshake(auth: .macOS(username: "a", password: "b"))
            XCTFail()
        } catch RFBError.unsupportedSecurity(let offered) { XCTAssertEqual(offered, [33, 36]) } catch { XCTFail("\(error)") }
    }

    func testAuthFailureReason() async {
        let t = FakeTransport(Array("RFB 003.008\n".utf8) + [1, 2] + [UInt8](repeating: 7, count: 16) + be32(1) + be32(4) + Array("nope".utf8))
        do {
            try await RFBClient(transport: t).handshake(auth: .password("secret"))
            XCTFail()
        } catch RFBError.authFailed(let why) { XCTAssertEqual(why, "nope") } catch { XCTFail("\(error)") }
    }

    func testVNCPasswordKnownVector() {
        // DES of an all-zero challenge with key "password" bit-reversed, from `openssl enc -des-ecb -K 0e86ceceeef64e26`.
        let r = RFBAuth.vncResponse(challenge: [UInt8](repeating: 0, count: 16), password: "password")
        XCTAssertEqual(r, [0xFF, 0x97, 0x50, 0x2E, 0x94, 0x22, 0xF0, 0x89, 0xFF, 0x97, 0x50, 0x2E, 0x94, 0x22, 0xF0, 0x89])
    }

    func testAppleAuthRoundTrip() throws {
        // 512-bit prime keeps the test fast; real servers send 4096-bit.
        let p = BigUInt("d4bcd52406f69b35994b88de5db89682c8157f62d8f33633ee5772f11f05ab22d6b5145b9f241e5acc31ff090a4bc71148976f76795094e71e7f0f6aa7d1a7b5", radix: 16)!
        let g = BigUInt(2)
        let serverSecret = BigUInt(123_456_789_123_456_789)
        let serverPub = g.power(serverSecret, modulus: p)
        let prime = RFBAuth.pad(p, 64)
        let response = RFBAuth.appleResponse(generator: [0, 2], prime: prime, serverKey: RFBAuth.pad(serverPub, 64),
                                             username: "alex", password: "hunter2")
        XCTAssertEqual(response.count, 128 + 64)
        let clientPub = BigUInt(Data(response[128...]))
        let shared = clientPub.power(serverSecret, modulus: p)
        let key = Array(Insecure.MD5.hash(data: RFBAuth.pad(shared, 64)))
        var plain = [UInt8](repeating: 0, count: 128)
        var moved = 0
        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, 16, nil,
                Array(response[0..<128]), 128, &plain, 128, &moved)
        XCTAssertEqual(Array(plain[0..<5]), Array("alex".utf8) + [0])
        XCTAssertEqual(Array(plain[64..<72]), Array("hunter2".utf8) + [0])
    }

    func testZRLETiles() async throws {
        // 66x2 rect = two tiles: 64x2 solid red, then 2x2 packed palette (blue/green).
        var tiles: [UInt8] = [1, 0, 0, 0xFF]
        tiles += [2, 0xFF, 0, 0, 0, 0xFF, 0] + [0b0100_0000, 0b1000_0000]
        var compressed = [UInt8](repeating: 0, count: 256)
        var len = uLongf(compressed.count)
        XCTAssertEqual(compress(&compressed, &len, tiles, uLong(tiles.count)), Z_OK)
        compressed = Array(compressed.prefix(Int(len)))

        var s = Array("RFB 003.008\n".utf8) + [1, 1] + be32(0) + serverInit(w: 66, h: 2)
        s += [0, 0] + be16(1) + be16(0) + be16(0) + be16(66) + be16(2) + be32(16) + be32(compressed.count) + compressed
        let c = RFBClient(transport: FakeTransport(s))
        try await c.handshake(auth: .none)
        do { try await c.run() } catch TransportError.closed {}
        XCTAssertEqual(c.framebuffer.pixel(x: 63, y: 1), 0xFF0000)
        XCTAssertEqual(c.framebuffer.pixel(x: 64, y: 0), 0x0000FF)
        XCTAssertEqual(c.framebuffer.pixel(x: 65, y: 0), 0x00FF00)
        XCTAssertEqual(c.framebuffer.pixel(x: 64, y: 1), 0x00FF00)
        XCTAssertEqual(c.framebuffer.pixel(x: 65, y: 1), 0x0000FF)
    }
}

final class ClaudeTranscriptTests: XCTestCase {
    func testRendersPromptsToolsAndResults() {
        let user = #"{"type":"user","message":{"role":"user","content":"fix the build"},"isMeta":false}"#
        let slash = #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}"#
        let tool = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls\n-la","description":"List files"}}]}}"#
        let result = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a\nb"}]}}"#
        let text = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done.\n"}]}}"#
        XCTAssertEqual(ClaudeTranscript.render(user), "\n❯ fix the build\n")
        XCTAssertEqual(ClaudeTranscript.render(slash), "\n❯ /clear\n")
        XCTAssertEqual(ClaudeTranscript.render(tool), "⚙ Bash  List files\n")
        XCTAssertEqual(ClaudeTranscript.render(result), "  ↳ a\n    b\n")
        XCTAssertEqual(ClaudeTranscript.render(text), "\nDone.\n")
    }

    func testSkipsNoise() {
        XCTAssertNil(ClaudeTranscript.render(#"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#))
        XCTAssertNil(ClaudeTranscript.render(#"{"type":"user","message":{"content":"<task-notification>done</task-notification>"}}"#))
        XCTAssertNil(ClaudeTranscript.render(#"{"type":"user","isSidechain":true,"message":{"content":"sub"}}"#))
        XCTAssertNil(ClaudeTranscript.render(#"{"type":"ai-title","aiTitle":"x"}"#))
        XCTAssertNil(ClaudeTranscript.render("not json"))
    }
}
