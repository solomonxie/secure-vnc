import XCTest
@testable import SecureVNCKit

final class LocalShellTests: XCTestCase {
    var root: URL!
    var shell: LocalShell!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("usb"), withIntermediateDirectories: true)
        let files = LocalFiles(mounts: LocalMounts(["Documents": root.appendingPathComponent("home"), "USB": root.appendingPathComponent("usb")]))
        shell = LocalShell(files: files)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func sh(_ line: String) async -> (out: String, code: Int32) {
        let out = Sink()
        let code = await shell.run(line, out: out, err: out)
        return (String(decoding: out.data, as: UTF8.self), code)
    }

    func testSyntax() throws {
        let t = try ShellSyntax.tokens(#"echo "a $X" 'b $X' c\ d *.txt 2>&1 > f"#, variable: { $0 == "X" ? "1" : nil }, home: "/h")
        XCTAssertEqual(t.count, 8)
        guard case .word(let w1) = t[1], case .word(let w2) = t[2], case .word(let w3) = t[3], case .word(let w4) = t[4] else { return XCTFail() }
        XCTAssertEqual([w1.text, w2.text, w3.text], ["a 1", "b $X", "c d"])
        XCTAssertTrue(w4.globbed)
        XCTAssertEqual(t[5], .redirect(.errorToOutput))
        XCTAssertEqual(t[6], .redirect(.output))
        XCTAssertEqual(try ShellSyntax.split("a; b && c || 'd;e' # x").map(\.0), ["a", " b ", " c ", " 'd;e' "])
    }

    func testFilesAndPipes() async throws {
        await sh("mkdir -p a/b && echo hello > a/b/x.txt && printf 'z\\ny\\nz\\n' > a/l.txt")
        var r = await sh("cat a/b/x.txt")
        XCTAssertEqual(r.out, "hello\n")
        r = await sh("sort a/l.txt | uniq -c | wc -l")
        XCTAssertEqual(r.out.trimmingCharacters(in: .whitespacesAndNewlines), "2")
        r = await sh("cp -r a /USB && ls /USB/a/b")
        XCTAssertEqual(r.out, "x.txt\n")
        r = await sh("find /USB -name '*.txt' | sort")
        XCTAssertEqual(r.out, "/USB/a/b/x.txt\n/USB/a/l.txt\n")
        r = await sh("cd /USB/a && echo *.txt && pwd")
        XCTAssertEqual(r.out, "l.txt\n/USB/a\n")
        r = await sh("cd ~ && grep -rn hello . && sed 's/hel\\(lo\\)/HE\\1/' a/b/x.txt")
        XCTAssertEqual(r.out, "./a/b/x.txt:1:hello\nHElo\n")
        r = await sh("mv a/l.txt a/m.txt; ls a; rm a; echo $?")
        XCTAssertEqual(r.out, "b/     m.txt\nrm: a: is a directory\n1\n")
        r = await sh("rm -rf a && test -e a || echo gone")
        XCTAssertEqual(r.out, "gone\n")
    }

    func testMountsAreProtected() async throws {
        var r = await sh("ls /")
        XCTAssertEqual(r.out, "Documents/  USB/\n")
        r = await sh("rm -rf /USB")
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("usb").path))
        r = await sh("cd ../../..; pwd; cat nope")
        XCTAssertEqual(r.out, "/\ncat: nope: No such file or directory\n")
    }

    func testPasteNamesCopies() async throws {
        let files = shell.files
        try files.writeData("/Documents/p.jpg", Data([1, 2]))
        try await files.paste(["/Documents/p.jpg"], into: "/Documents", move: false)
        try await files.paste(["/Documents/p.jpg"], into: "/Documents", move: false)
        let names = try await files.list("/Documents").map(\.name)
        XCTAssertEqual(names, ["p copy 2.jpg", "p copy.jpg", "p.jpg"])
    }

    func testChannelEchoesAndPrompts() async throws {
        shell.send(Array("echo hi\r".utf8))
        var text = ""
        while !text.contains("hi\n~ $ ") { text += String(decoding: try await shell.readAvailable(), as: UTF8.self) }
        XCTAssertTrue(text.hasSuffix("~ $ echo hi\nhi\n~ $ "))
    }
}
