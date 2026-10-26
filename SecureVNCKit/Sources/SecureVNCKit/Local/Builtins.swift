import CryptoKit
import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

typealias Command = (Invocation) async throws -> Int32

struct Invocation {
    let shell: LocalShell
    let name: String
    let args: [String]
    let stdin: Data
    let out: Sink
    let err: Sink

    var files: LocalFiles { shell.files }
    func path(_ s: String) -> String { shell.resolve(s) }

    func fail(_ message: String) -> Int32 {
        err.line("\(name): \(message)")
        return 1
    }

    func options(_ flags: String, values: String = "") throws -> Options { try Options(args, flags: flags, values: values) }

    /// Each operand's content, or stdin when there are none or for `-`.
    func inputs(_ operands: [String]) -> [(name: String, data: Data?)] {
        (operands.isEmpty ? ["-"] : operands).map { op in
            guard op != "-" else { return (op, stdin) }
            do {
                let p = path(op)
                if try files.info(p).isDirectory {
                    err.line("\(name): \(op): Is a directory")
                    return (op, nil)
                }
                return (op, try files.readData(p))
            } catch {
                err.line("\(name): \(op): \(Builtins.describe(error))")
                return (op, nil)
            }
        }
    }

    var stdinText: String { String(decoding: stdin, as: UTF8.self) }
}

/// `-abc`, `-n 5`, `-n5` and `--`; long options are kept for commands that know them.
struct Options {
    var flags = Set<Character>()
    var values: [Character: String] = [:]
    var operands: [String] = []
    var long: [String] = []

    init(_ args: [String], flags allowed: String, values valued: String = "") throws {
        var i = 0
        var onlyOperands = false
        while i < args.count {
            let arg = args[i]
            i += 1
            if onlyOperands || arg == "-" || !arg.hasPrefix("-") {
                operands.append(arg)
                continue
            }
            if arg == "--" { onlyOperands = true; continue }
            if arg.hasPrefix("--") { long.append(String(arg.dropFirst(2))); continue }
            var chars = arg.dropFirst()
            while let c = chars.first {
                chars = chars.dropFirst()
                if valued.contains(c) {
                    if !chars.isEmpty {
                        values[c] = String(chars)
                    } else if i < args.count {
                        values[c] = args[i]
                        i += 1
                    } else {
                        throw ShellError("option requires an argument -- '\(c)'")
                    }
                    break
                }
                guard allowed.contains(c) else { throw ShellError("invalid option -- '\(c)'") }
                flags.insert(c)
            }
        }
    }

    func has(_ c: Character) -> Bool { flags.contains(c) }
}

enum Builtins {
    static let all: [String: Command] = [
        "help": help, "echo": echo, "printf": printf, "pwd": pwd, "cd": cd, "ls": ls, "ll": { try await ls($0.with(["-l"])) },
        "la": { try await ls($0.with(["-la"])) }, "cat": cat, "less": cat, "more": cat, "head": head, "tail": tail, "wc": wc,
        "grep": grep, "egrep": grep, "fgrep": { try await grep($0.with(["-F"])) }, "sort": sort, "uniq": uniq, "cut": cut,
        "tr": tr, "sed": sed, "rev": rev, "nl": { try await cat($0.with(["-n"])) }, "tee": tee, "cp": { try await copy($0, move: false) },
        "mv": { try await copy($0, move: true) }, "rm": rm, "mkdir": mkdir, "rmdir": rmdir, "touch": touch, "ln": ln,
        "find": find, "du": du, "df": df, "stat": stat, "file": file, "basename": basename, "dirname": dirname,
        "realpath": realpath, "readlink": realpath, "seq": seq, "sleep": sleep, "date": date, "env": env, "printenv": env,
        "export": export, "set": env, "unset": unset, "which": which, "type": which, "true": { _ in 0 }, "false": { _ in 1 },
        "whoami": { $0.out.line($0.shell.variable("USER") ?? "mobile"); return 0 }, "uname": uname, "hostname": hostname,
        "uptime": uptime, "history": history, "clear": { $0.out.write("\u{0C}"); return 0 }, "reset": { $0.out.write("\u{0C}"); return 0 },
        "md5sum": { try await digest($0, Insecure.MD5.self) }, "sha1sum": { try await digest($0, Insecure.SHA1.self) },
        "sha256sum": { try await digest($0, SHA256.self) }, "sha512sum": { try await digest($0, SHA512.self) },
        "base64": base64, "xxd": xxd, "hexdump": xxd, "curl": curl, "wget": wget, "open": open, "edit": open, "vi": open,
        "vim": open, "nano": open, "sh": sh, "bash": sh, "source": sh, ".": sh, "test": test, "[": test, "expr": expr,
        "yes": yes, "exit": { $0.shell.close(); return 0 }, "pbcopy": pbcopy, "pbpaste": pbpaste,
    ]

    static func describe(_ error: Error) -> String {
        if let e = error as? CocoaError {
            switch e.code {
            case .fileNoSuchFile, .fileReadNoSuchFile: return "No such file or directory"
            case .fileWriteFileExists: return "File exists"
            case .fileReadNoPermission, .fileWriteNoPermission: return "Permission denied"
            case .fileWriteOutOfSpace: return "No space left on device"
            case .fileWriteVolumeReadOnly: return "Read-only file system"
            default: break
            }
            if let posix = e.underlying as? POSIXError { return String(cString: strerror(posix.code.rawValue)) }
        }
        return error.localizedDescription
    }

    // MARK: Shell

    static func help(_ c: Invocation) async throws -> Int32 {
        c.out.line("""
        Built-in commands (no other programs can run on iOS):
        \(columns(all.keys.sorted(), width: c.shell.columns))
        Files: ~ is /Documents (also in the Files app under Secure VNC). Folders and USB drives
        linked in the file browser appear under /. `open FILE` previews, `edit FILE` edits.
        Syntax: quotes, $VAR, ~, * ? [..], | < > >> 2> 2>&1, ; && ||, # comments.
        """)
        return 0
    }

    static func echo(_ c: Invocation) async throws -> Int32 {
        var args = c.args, newline = true, escapes = false
        while let first = args.first, first.count > 1, first.hasPrefix("-"), first.dropFirst().allSatisfy({ "neE".contains($0) }) {
            if first.contains("n") { newline = false }
            if first.contains("e") { escapes = true }
            args.removeFirst()
        }
        let text = args.joined(separator: " ")
        c.out.write((escapes ? unescape(text) : text) + (newline ? "\n" : ""))
        return 0
    }

    static func printf(_ c: Invocation) async throws -> Int32 {
        guard let format = c.args.first else { return c.fail("usage: printf FORMAT [ARG]...") }
        var args = Array(c.args.dropFirst())[...]
        let f = Array(unescape(format))
        var out = ""
        repeat {
            var i = 0
            while i < f.count {
                guard f[i] == "%", i + 1 < f.count else { out.append(f[i]); i += 1; continue }
                var j = i + 1, spec = "%"
                while j < f.count, "-+ 0#.123456789".contains(f[j]) { spec.append(f[j]); j += 1 }
                guard j < f.count else { out += spec; break }
                let conv = f[j]
                let arg = args.popFirst() ?? ""
                switch conv {
                case "%": out += "%"; args = [arg] + args
                case "s": out += String(format: spec + "@", arg)
                case "d", "i": out += String(format: spec + "lld", Int64(arg) ?? 0)
                case "x", "X", "o": out += String(format: spec + "ll" + String(conv), Int64(arg) ?? 0)
                case "f", "e", "g": out += String(format: spec + String(conv), Double(arg) ?? 0)
                case "c": out += String(arg.prefix(1))
                default: out += spec + String(conv)
                }
                i = j + 1
            }
        } while !args.isEmpty && format.contains("%")
        c.out.write(out)
        return 0
    }

    static func pwd(_ c: Invocation) async throws -> Int32 {
        c.out.line(c.shell.directory)
        return 0
    }

    static func cd(_ c: Invocation) async throws -> Int32 {
        let arg = c.args.first ?? c.shell.home
        let target = arg == "-" ? c.shell.previousDirectory : c.path(arg)
        guard c.files.exists(target) else { return c.fail("\(arg): No such file or directory") }
        guard try c.files.info(target).isDirectory else { return c.fail("\(arg): Not a directory") }
        c.shell.changeDirectory(target)
        if arg == "-" { c.out.line(target) }
        return 0
    }

    static func env(_ c: Invocation) async throws -> Int32 {
        let vars = c.shell.environment
        if let name = c.args.first, c.name == "printenv" {
            guard let value = vars[name] else { return 1 }
            c.out.line(value)
            return 0
        }
        for (k, v) in vars.sorted(by: { $0.key < $1.key }) { c.out.line("\(k)=\(v)") }
        return 0
    }

    static func export(_ c: Invocation) async throws -> Int32 {
        guard !c.args.isEmpty else { return try await env(c) }
        for arg in c.args {
            guard let eq = arg.firstIndex(of: "=") else { continue }
            guard LocalShell.isName(arg[..<eq]) else { return c.fail("'\(arg)': not a valid identifier") }
            c.shell.setVariable(String(arg[..<eq]), String(arg[arg.index(after: eq)...]))
        }
        return 0
    }

    static func unset(_ c: Invocation) async throws -> Int32 {
        for name in c.args { c.shell.setVariable(name, nil) }
        return 0
    }

    static func which(_ c: Invocation) async throws -> Int32 {
        var code: Int32 = 0
        for name in c.args {
            if all[name] != nil { c.out.line("\(name): shell built-in") } else {
                c.err.line("\(name) not found")
                code = 1
            }
        }
        return code
    }

    static func history(_ c: Invocation) async throws -> Int32 {
        for (i, line) in c.shell.history.enumerated() { c.out.line(String(format: "%5d  ", i + 1) + line) }
        return 0
    }

    static func sh(_ c: Invocation) async throws -> Int32 {
        if c.args.first == "-c" {
            guard c.args.count > 1 else { return c.fail("-c: option requires an argument") }
            return await c.shell.run(c.args[1], out: c.out, err: c.err, stdin: c.stdin)
        }
        let script: String
        if let file = c.args.first {
            script = try await c.files.readText(c.path(file))
        } else {
            script = c.stdinText
        }
        var code: Int32 = 0
        for line in script.split(separator: "\n", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            code = await c.shell.run(String(line), out: c.out, err: c.err)
        }
        return code
    }

    static func test(_ c: Invocation) async throws -> Int32 {
        var a = c.args
        if c.name == "[" {
            guard a.last == "]" else { return c.fail("missing ']'") }
            a.removeLast()
        }
        var negate = false
        if a.first == "!" { negate = true; a.removeFirst() }
        let result: Bool
        switch a.count {
        case 0: result = false
        case 1: result = !a[0].isEmpty
        case 2:
            let p = c.path(a[1])
            let info = try? c.files.info(p)
            switch a[0] {
            case "-e": result = c.files.exists(p)
            case "-f": result = info.map { !$0.isDirectory } ?? false
            case "-d": result = info?.isDirectory ?? false
            case "-s": result = (info?.size ?? 0) > 0
            case "-L", "-h": result = info?.isLink ?? false
            case "-r", "-w": result = c.files.exists(p)
            case "-z": result = a[1].isEmpty
            case "-n": result = !a[1].isEmpty
            default: return c.fail("\(a[0]): unary operator expected")
            }
        case 3:
            let (l, op, r) = (a[0], a[1], a[2])
            switch op {
            case "=", "==": result = l == r
            case "!=": result = l != r
            case "-eq", "-ne", "-lt", "-le", "-gt", "-ge":
                guard let x = Int(l), let y = Int(r) else { return c.fail("integer expression expected") }
                result = ["-eq": x == y, "-ne": x != y, "-lt": x < y, "-le": x <= y, "-gt": x > y, "-ge": x >= y][op]!
            default: return c.fail("\(op): binary operator expected")
            }
        default: return c.fail("too many arguments")
        }
        return result != negate ? 0 : 1
    }

    static func expr(_ c: Invocation) async throws -> Int32 {
        var a = c.args[...]
        guard let first = a.popFirst(), var value = Int(first) else { return c.fail("usage: expr N [+-*/% N]...") }
        while let op = a.popFirst() {
            guard let next = a.popFirst().flatMap({ Int($0) }) else { return c.fail("non-integer argument") }
            switch op {
            case "+": value += next
            case "-": value -= next
            case "*": value *= next
            case "/", "%":
                guard next != 0 else { return c.fail("division by zero") }
                value = op == "/" ? value / next : value % next
            default: return c.fail("syntax error")
            }
        }
        c.out.line(String(value))
        return value == 0 ? 1 : 0
    }

    static func sleep(_ c: Invocation) async throws -> Int32 {
        guard let s = c.args.first.flatMap(Double.init) else { return c.fail("usage: sleep SECONDS") }
        try await Task.sleep(for: .milliseconds(Int(s * 1000)))
        return 0
    }

    static func yes(_ c: Invocation) async throws -> Int32 {
        let line = (c.args.isEmpty ? "y" : c.args.joined(separator: " ")) + "\n"
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            c.out.write(line)
        }
        return 0
    }

    // MARK: Listing

    static func ls(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("laAh1rtSdF")
        let targets = o.operands.isEmpty ? ["."] : o.operands
        var code: Int32 = 0
        var fileRows: [(String, LocalFiles.Info)] = []
        var dirs: [String] = []
        for t in targets {
            let p = c.path(t)
            guard c.files.exists(p), let info = try? c.files.info(p) else {
                c.err.line("ls: \(t): No such file or directory")
                code = 1
                continue
            }
            if info.isDirectory && !o.has("d") { dirs.append(t) } else { fileRows.append((t, info)) }
        }
        if !fileRows.isEmpty { printEntries(c, o, fileRows) }
        for (n, t) in dirs.enumerated() {
            if targets.count > 1 { c.out.line((n > 0 || !fileRows.isEmpty ? "\n" : "") + t + ":") }
            let dir = c.path(t)
            var rows: [(String, LocalFiles.Info)] = []
            for entry in try await c.files.list(dir) where o.has("a") || o.has("A") || !entry.name.hasPrefix(".") {
                guard let info = try? c.files.info(entry.path) else { continue }
                rows.append((entry.name, info))
            }
            printEntries(c, o, rows)
        }
        return code
    }

    private static func printEntries(_ c: Invocation, _ o: Options, _ rows: [(String, LocalFiles.Info)]) {
        var rows = rows.sorted { $0.0.lowercased() < $1.0.lowercased() }
        if o.has("t") { rows.sort { ($0.1.modified ?? .distantPast) > ($1.1.modified ?? .distantPast) } }
        if o.has("S") { rows.sort { $0.1.size > $1.1.size } }
        if o.has("r") { rows.reverse() }
        if o.has("l") {
            let sizes = rows.map { o.has("h") ? human($0.1.size) : String($0.1.size) }
            let w = sizes.map(\.count).max() ?? 0
            for ((name, info), size) in zip(rows, sizes) {
                let kind = info.isLink ? "l" : info.isDirectory ? "d" : "-"
                c.out.line("\(kind)\(permissions(info.permissions))  \(String(repeating: " ", count: w - size.count))\(size)  \(listDate(info.modified))  \(name)\(info.isDirectory ? "/" : "")")
            }
        } else {
            let names = rows.map { $0.0 + ($0.1.isDirectory ? "/" : "") }
            if o.has("1") { names.forEach(c.out.line) } else if !names.isEmpty { c.out.line(columns(names, width: c.shell.columns)) }
        }
    }

    static func columns(_ items: [String], width: Int) -> String {
        let col = (items.map(\.count).max() ?? 0) + 2
        let perRow = max(1, width / col)
        let rows = (items.count + perRow - 1) / perRow
        return (0..<rows).map { r in
            stride(from: r, to: items.count, by: rows).map { items[$0].padding(toLength: col, withPad: " ", startingAt: 0) }
                .joined().trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    static func permissions(_ mode: Int) -> String {
        (0..<9).map { i in mode & (1 << (8 - i)) != 0 ? Array("rwx")[i % 3] : "-" }.map(String.init).joined()
    }

    private static func listDate(_ date: Date?) -> String {
        guard let date else { return "            " }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = abs(date.timeIntervalSinceNow) < 180 * 86400 ? "MMM dd HH:mm" : "MMM dd  yyyy"
        return f.string(from: date)
    }

    static func human(_ n: Int) -> String {
        var v = Double(n), i = 0
        let units = ["B", "K", "M", "G", "T"]
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(n)" }
        return v < 10 ? String(format: "%.1f%@", v, units[i]) : "\(Int(v.rounded()))\(units[i])"
    }

    /// Visits `path` and everything under it, depth first; `visit` returns false to skip a folder's contents.
    static func walk(_ files: LocalFiles, _ path: String, shown: String, depth: Int = 0, maxDepth: Int = .max,
                     _ visit: (String, String, LocalFiles.Info, Int) throws -> Bool) throws {
        try Task.checkCancellation()
        guard let info = try? files.info(path) else { return }
        guard try visit(path, shown, info, depth), info.isDirectory, !info.isLink || depth == 0, depth < maxDepth else { return }
        let names: [String]
        if LocalFiles.normalize(path) == "/" {
            names = files.mounts.all.keys.sorted()
        } else {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: files.url(path).path)) ?? []).sorted()
        }
        for name in names {
            try walk(files, RemoteFiles.join(path, name), shown: shown.hasSuffix("/") ? shown + name : shown + "/" + name,
                     depth: depth + 1, maxDepth: maxDepth, visit)
        }
    }

    static func find(_ c: Invocation) async throws -> Int32 {
        var roots: [String] = []
        var a = c.args[...]
        while let first = a.first, !first.hasPrefix("-") { roots.append(first); a.removeFirst() }
        var name: String?, iname: String?, type: String?, maxDepth = Int.max, minDepth = 0
        while let flag = a.popFirst() {
            guard let value = a.popFirst() else { return c.fail("missing argument to \(flag)") }
            switch flag {
            case "-name": name = value
            case "-iname": iname = value.lowercased()
            case "-type": type = value
            case "-maxdepth": maxDepth = Int(value) ?? .max
            case "-mindepth": minDepth = Int(value) ?? 0
            default: return c.fail("unknown predicate \(flag) (supported: -name -iname -type -maxdepth -mindepth)")
            }
        }
        for root in roots.isEmpty ? ["."] : roots {
            let p = c.path(root)
            guard c.files.exists(p) else {
                c.err.line("find: \(root): No such file or directory")
                continue
            }
            try walk(c.files, p, shown: root, maxDepth: maxDepth) { path, shown, info, depth in
                let base = (path as NSString).lastPathComponent
                let matches = depth >= minDepth
                    && (name.map { fnmatch($0, base, 0) == 0 } ?? true)
                    && (iname.map { fnmatch($0, base.lowercased(), 0) == 0 } ?? true)
                    && (type.map { $0 == (info.isDirectory ? "d" : info.isLink ? "l" : "f") } ?? true)
                if matches { c.out.line(shown) }
                return true
            }
        }
        return 0
    }

    static func du(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("shac")
        var grand = 0
        for root in o.operands.isEmpty ? ["."] : o.operands {
            let p = c.path(root)
            guard c.files.exists(p) else {
                c.err.line("du: \(root): No such file or directory")
                continue
            }
            var totals: [String: Int] = [:]
            var order: [(String, String, Bool)] = []
            try walk(c.files, p, shown: root) { path, shown, info, _ in
                if !info.isDirectory {
                    var dir = path
                    totals[path, default: 0] += info.size
                    while dir != p, dir != "/" {
                        dir = RemoteFiles.parent(dir)
                        totals[dir, default: 0] += info.size
                    }
                }
                order.append((path, shown, info.isDirectory))
                return true
            }
            let show = { (path: String, shown: String) in
                let n = totals[path] ?? 0
                c.out.line((o.has("h") ? human(n) : String((n + 1023) / 1024)) + "\t" + shown)
            }
            if o.has("s") {
                show(p, root)
            } else {
                for (path, shown, isDir) in order.reversed() where isDir || o.has("a") { show(path, shown) }
            }
            grand += totals[p] ?? 0
        }
        if o.has("c") { c.out.line((o.has("h") ? human(grand) : String((grand + 1023) / 1024)) + "\ttotal") }
        return 0
    }

    static func df(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("hk")
        let size = { (n: Int) in o.has("h") ? human(n) : String(n / 1024) }
        var rows = [["Folder", o.has("h") ? "Size" : "1K-blocks", "Used", "Avail", "Use%"]]
        for (name, url) in c.files.mounts.all.sorted(by: { $0.key < $1.key }) {
            let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            guard let total = v?.volumeTotalCapacity, let free = v?.volumeAvailableCapacity, total > 0 else { continue }
            rows.append(["/" + name, size(total), size(total - free), size(free), "\((total - free) * 100 / total)%"])
        }
        let widths = (0..<5).map { i in rows.map { $0[i].count }.max() ?? 0 }
        for row in rows {
            c.out.line(row.enumerated().map { i, s in i == 0 ? s.padding(toLength: widths[0], withPad: " ", startingAt: 0)
                : String(repeating: " ", count: widths[i] - s.count) + s }.joined(separator: "  "))
        }
        return 0
    }

    static func stat(_ c: Invocation) async throws -> Int32 {
        guard !c.args.isEmpty else { return c.fail("missing operand") }
        var code: Int32 = 0
        for arg in c.args {
            do {
                let info = try c.files.info(c.path(arg))
                c.out.line("""
                  File: \(arg)
                  Size: \(info.size)\t\(info.isLink ? "symbolic link" : info.isDirectory ? "directory" : "regular file")
                Access: (\(String(info.permissions, radix: 8))/\(info.isDirectory ? "d" : "-")\(permissions(info.permissions)))
                Modify: \(info.modified.map { ISO8601DateFormatter.string(from: $0, timeZone: .current, formatOptions: [.withInternetDateTime]) } ?? "-")
                """)
            } catch {
                c.err.line("stat: \(arg): \(describe(error))")
                code = 1
            }
        }
        return code
    }

    static func file(_ c: Invocation) async throws -> Int32 {
        for arg in c.args {
            let p = c.path(arg)
            guard let info = try? c.files.info(p) else {
                c.out.line("\(arg): cannot open (No such file or directory)")
                continue
            }
            if info.isDirectory { c.out.line("\(arg): directory"); continue }
            let type = UTType(filenameExtension: (arg as NSString).pathExtension)
            let head = (try? FileHandle(forReadingFrom: c.files.url(p)).read(upToCount: 4096)) ?? nil
            let text = head.map { !$0.contains(0) && String(data: $0, encoding: .utf8) != nil } ?? false
            let kind = info.size == 0 ? "empty" : type?.localizedDescription ?? (text ? "UTF-8 text" : "data")
            c.out.line("\(arg): \(kind)")
        }
        return 0
    }

    static func basename(_ c: Invocation) async throws -> Int32 {
        guard let p = c.args.first else { return c.fail("missing operand") }
        var base = (p as NSString).lastPathComponent
        if c.args.count > 1, base.hasSuffix(c.args[1]), base != c.args[1] { base.removeLast(c.args[1].count) }
        c.out.line(base)
        return 0
    }

    static func dirname(_ c: Invocation) async throws -> Int32 {
        guard let p = c.args.first else { return c.fail("missing operand") }
        let d = (p as NSString).deletingLastPathComponent
        c.out.line(d.isEmpty ? "." : d)
        return 0
    }

    static func realpath(_ c: Invocation) async throws -> Int32 {
        for p in c.args.filter({ !$0.hasPrefix("-") }) { c.out.line(c.path(p)) }
        return 0
    }

    // MARK: Text

    static func lines(_ data: Data) -> [Substring] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    static func cat(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("nbsuAvetE")
        var code: Int32 = 0, n = 0
        for (_, data) in c.inputs(o.operands) {
            guard let data else { code = 1; continue }
            try Task.checkCancellation()
            if o.has("n") || o.has("b") {
                for line in lines(data) {
                    if o.has("b") && line.isEmpty { c.out.line(""); continue }
                    n += 1
                    c.out.line(String(format: "%6d\t", n) + line)
                }
            } else {
                c.out.write(data)
            }
        }
        return code
    }

    /// `-5` as `-n 5`.
    private static func countArgs(_ args: [String]) -> [String] {
        args.flatMap { a in a.count > 1 && a.hasPrefix("-") && a.dropFirst().allSatisfy(\.isNumber) ? ["-n", String(a.dropFirst())] : [a] }
    }

    static func head(_ c: Invocation) async throws -> Int32 {
        let o = try Options(countArgs(c.args), flags: "qv", values: "nc")
        let inputs = c.inputs(o.operands)
        for (i, (name, data)) in inputs.enumerated() {
            guard let data else { continue }
            if inputs.count > 1 { c.out.line((i > 0 ? "\n" : "") + "==> \(name) <==") }
            if let bytes = o.values["c"].flatMap(Int.init) {
                c.out.write(data.prefix(bytes))
            } else {
                let n = o.values["n"].flatMap(Int.init) ?? 10
                lines(data).prefix(max(0, n)).forEach { c.out.line(String($0)) }
            }
        }
        return 0
    }

    static func tail(_ c: Invocation) async throws -> Int32 {
        let o = try Options(countArgs(c.args), flags: "qvf", values: "nc")
        let inputs = c.inputs(o.operands)
        for (i, (name, data)) in inputs.enumerated() {
            guard let data else { continue }
            if inputs.count > 1 { c.out.line((i > 0 ? "\n" : "") + "==> \(name) <==") }
            if let bytes = o.values["c"].flatMap(Int.init) {
                c.out.write(data.suffix(bytes))
            } else {
                let spec = o.values["n"] ?? "10"
                let all = lines(data)
                let shown = spec.hasPrefix("+") ? all.dropFirst(max(0, (Int(spec.dropFirst()) ?? 1) - 1)) : all.suffix(Int(spec) ?? 10)
                shown.forEach { c.out.line(String($0)) }
            }
        }
        return 0
    }

    static func wc(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("lwcm")
        let pick = o.flags.isEmpty ? Set<Character>(["l", "w", "c"]) : o.flags
        var total = [0, 0, 0]
        let inputs = c.inputs(o.operands)
        let show = { (counts: [Int], name: String) in
            let cols = zip(["l", "w", "c"] as [Character], counts).filter { pick.contains($0.0) || ($0.0 == "c" && pick.contains("m")) }
            c.out.line(cols.map { String(format: "%8d", $0.1) }.joined() + (name == "-" ? "" : " " + name))
        }
        for (name, data) in inputs {
            guard let data else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let counts = [data.filter { $0 == 0x0A }.count, text.split(whereSeparator: \.isWhitespace).count,
                          pick.contains("m") ? text.count : data.count]
            total = zip(total, counts).map(+)
            show(counts, name)
        }
        if inputs.count > 1 { show(total, "total") }
        return 0
    }

    static func grep(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("ivnclLrRHhEFwoqsG", values: "e")
        var operands = o.operands
        guard let pattern = o.values["e"] ?? (operands.isEmpty ? nil : operands.removeFirst()) else {
            return c.fail("usage: grep [-ivnclrFwo] PATTERN [FILE]...")
        }
        var source = o.has("F") ? NSRegularExpression.escapedPattern(for: pattern) : o.has("E") || c.name == "egrep" ? pattern : extended(pattern)
        if o.has("w") { source = "\\b(?:\(source))\\b" }
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: source, options: o.has("i") ? [.caseInsensitive] : []) } catch {
            return c.fail("invalid pattern: \(pattern)")
        }
        let recursive = o.has("r") || o.has("R")
        if recursive && operands.isEmpty { operands = ["."] }
        var inputs: [(String, Data?)] = []
        if recursive {
            for root in operands {
                try walk(c.files, c.path(root), shown: root) { path, shown, info, _ in
                    if !info.isDirectory { inputs.append((shown, try? c.files.readData(path))) }
                    return !(path as NSString).lastPathComponent.hasPrefix(".") || shown == root
                }
            }
        } else {
            inputs = c.inputs(operands)
        }
        let named = !o.has("h") && (o.has("H") || recursive || inputs.count > 1)
        var found = false
        for (name, data) in inputs {
            guard let data else { continue }
            if recursive && data.prefix(8000).contains(0) { continue }
            try Task.checkCancellation()
            var count = 0
            for (n, line) in lines(data).enumerated() {
                let s = String(line)
                let range = NSRange(s.startIndex..., in: s)
                let matches = o.has("o") ? regex.matches(in: s, range: range) : []
                let hit = o.has("o") ? !matches.isEmpty : regex.firstMatch(in: s, range: range) != nil
                guard hit != o.has("v") else { continue }
                count += 1
                found = true
                if o.has("q") { return 0 }
                if o.has("c") || o.has("l") || o.has("L") { continue }
                let prefix = (named ? name + ":" : "") + (o.has("n") ? "\(n + 1):" : "")
                if o.has("o") {
                    for m in matches { c.out.line(prefix + (s as NSString).substring(with: m.range)) }
                } else {
                    c.out.line(prefix + s)
                }
            }
            if o.has("c") { c.out.line((named ? name + ":" : "") + String(count)) }
            if o.has("l") && count > 0 { c.out.line(name) }
            if o.has("L") && count == 0 { c.out.line(name) }
        }
        return found ? 0 : 1
    }

    static func sort(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("rnufb", values: "tk")
        var all: [Substring] = []
        for (_, data) in c.inputs(o.operands) { if let data { all += lines(data) } }
        let key = { (line: Substring) -> Substring in
            guard let k = o.values["k"].flatMap({ Int($0.prefix { $0.isNumber }) }), k > 0 else { return line }
            let fields = o.values["t"].map { line.split(separator: Character($0), omittingEmptySubsequences: false) }
                ?? line.split(whereSeparator: \.isWhitespace)
            return k <= fields.count ? fields[k - 1] : ""
        }
        let less = { (a: Substring, b: Substring) -> Bool in
            let (x, y) = (key(a), key(b))
            if o.has("n") { return (Double(x.trimmingCharacters(in: .whitespaces)) ?? 0) < (Double(y.trimmingCharacters(in: .whitespaces)) ?? 0) }
            return o.has("f") ? x.lowercased() < y.lowercased() : x < y
        }
        var sorted = all.sorted(by: less)
        if o.has("r") { sorted.reverse() }
        var last: Substring?
        for line in sorted {
            if o.has("u"), let l = last, !less(l, line), !less(line, l) { continue }
            c.out.line(String(line))
            last = line
        }
        return 0
    }

    static func uniq(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("cdui")
        guard let data = c.inputs(o.operands).first?.data else { return 1 }
        var groups: [(Substring, Int)] = []
        for line in lines(data) {
            if let last = groups.last, o.has("i") ? last.0.lowercased() == line.lowercased() : last.0 == line {
                groups[groups.count - 1].1 += 1
            } else {
                groups.append((line, 1))
            }
        }
        for (line, n) in groups where !(o.has("d") && n < 2) && !(o.has("u") && n > 1) {
            c.out.line((o.has("c") ? String(format: "%7d ", n) : "") + line)
        }
        return 0
    }

    /// `1,3,5-7`, `-3`, `2-` as 1-based positions.
    private static func ranges(_ spec: String) -> (Int) -> Bool {
        let parts = spec.split(separator: ",").map { part -> ClosedRange<Int> in
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            if ends.count == 1 { return (ends[0] ?? 1)...(ends[0] ?? 1) }
            return (ends[0] ?? 1)...(ends[1] ?? .max)
        }
        return { i in parts.contains { $0.contains(i) } }
    }

    static func cut(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("s", values: "dfc")
        guard let spec = o.values["f"] ?? o.values["c"] else { return c.fail("you must specify a list of fields or characters (-f or -c)") }
        let pick = ranges(spec)
        let delim = o.values["d"].flatMap(\.first) ?? "\t"
        for (_, data) in c.inputs(o.operands) {
            guard let data else { continue }
            for line in lines(data) {
                if o.values["c"] != nil {
                    c.out.line(String(line.enumerated().filter { pick($0.offset + 1) }.map(\.element)))
                } else if !line.contains(delim) {
                    if !o.has("s") { c.out.line(String(line)) }
                } else {
                    let fields = line.split(separator: delim, omittingEmptySubsequences: false)
                    c.out.line(fields.enumerated().filter { pick($0.offset + 1) }.map { String($0.element) }.joined(separator: String(delim)))
                }
            }
        }
        return 0
    }

    /// `a-z` spelled out, with `\n` and friends.
    private static func charSet(_ spec: String) -> [Character] {
        let classes = ["[:lower:]": "a-z", "[:upper:]": "A-Z", "[:digit:]": "0-9", "[:alpha:]": "a-zA-Z", "[:alnum:]": "a-zA-Z0-9", "[:space:]": " \t\n\r"]
        let s = Array(unescape(classes.reduce(spec) { $0.replacingOccurrences(of: $1.key, with: $1.value) }))
        var out: [Character] = []
        var i = 0
        while i < s.count {
            if i + 2 < s.count, s[i + 1] == "-", let a = s[i].unicodeScalars.first?.value, let b = s[i + 2].unicodeScalars.first?.value, a <= b {
                out += (a...b).compactMap { Unicode.Scalar($0).map(Character.init) }
                i += 3
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    static func tr(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("ds")
        let text = c.stdinText
        guard let first = o.operands.first else { return c.fail("missing operand") }
        let from = charSet(first)
        if o.has("d") {
            let drop = Set(from)
            c.out.write(String(text.filter { !drop.contains($0) }))
            return 0
        }
        guard o.operands.count > 1 else { return c.fail("missing operand after '\(first)'") }
        let to = charSet(o.operands[1])
        guard let lastTo = to.last else { return c.fail("empty replacement set") }
        var map: [Character: Character] = [:]
        for (i, ch) in from.enumerated() where map[ch] == nil { map[ch] = i < to.count ? to[i] : lastTo }
        var out = ""
        for ch in text {
            let m = map[ch] ?? ch
            if o.has("s"), map[ch] != nil, out.last == m { continue }
            out.append(m)
        }
        c.out.write(out)
        return 0
    }

    /// `s/re/rep/[gi]` scripts only, with `-i` to edit files in place and `-n` + `p`.
    static func sed(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("inE", values: "e")
        var operands = o.operands
        guard let script = o.values["e"] ?? (operands.isEmpty ? nil : operands.removeFirst()) else {
            return c.fail("usage: sed [-i] [-n] 's/regex/replacement/[gip]' [FILE]...")
        }
        let s = Array(script)
        guard s.count > 3, s[0] == "s" else { return c.fail("only s/regex/replacement/flags is supported") }
        let delim = s[1]
        var parts: [String] = [""], i = 2
        while i < s.count {
            if s[i] == "\\", i + 1 < s.count, s[i + 1] == delim {
                parts[parts.count - 1].append(delim)
                i += 2
                continue
            }
            if s[i] == delim { parts.append("") } else { parts[parts.count - 1].append(s[i]) }
            i += 1
        }
        guard parts.count == 3 else { return c.fail("unterminated `s' command") }
        let flags = parts[2]
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: o.has("E") ? parts[0] : extended(parts[0]), options: flags.contains("i") || flags.contains("I") ? [.caseInsensitive] : []) } catch {
            return c.fail("invalid regex: \(parts[0])")
        }
        var template = ""
        var r = Array(parts[1])[...]
        while let ch = r.popFirst() {
            switch ch {
            case "&": template += "$0"
            case "$": template += "\\$"
            case "\\":
                if let next = r.popFirst() {
                    template += next.isNumber ? "$" + String(next) : next == "n" ? "\n" : next == "t" ? "\t" : NSRegularExpression.escapedTemplate(for: String(next))
                }
            default: template.append(ch)
            }
        }
        let global = flags.contains("g")
        let edit = { (line: Substring) -> String? in
            let str = String(line)
            let range = global ? NSRange(str.startIndex..., in: str) : regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str))?.range
            guard let range else { return o.has("n") ? nil : str }
            let replaced = regex.stringByReplacingMatches(in: str, range: range, withTemplate: template)
            if o.has("n") { return flags.contains("p") && replaced != str ? replaced : nil }
            return replaced
        }
        if o.has("i") {
            guard !operands.isEmpty else { return c.fail("-i needs a file") }
            for file in operands {
                let p = c.path(file)
                let data = try c.files.readData(p)
                let text = String(decoding: data, as: UTF8.self)
                let out = lines(data).compactMap(edit).joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")
                try c.files.writeData(p, Data(out.utf8))
            }
            return 0
        }
        for (_, data) in c.inputs(operands) {
            guard let data else { continue }
            lines(data).compactMap(edit).forEach(c.out.line)
        }
        return 0
    }

    /// A basic regex (`\(…\)`, `\{n\}`, `\+`) in extended syntax.
    static func extended(_ basic: String) -> String {
        var out = "", it = Array(basic)[...]
        while let ch = it.popFirst() {
            if ch == "\\", let next = it.popFirst() {
                out += "(){}+?|".contains(next) ? String(next) : "\\" + String(next)
            } else {
                out += "(){}+?|".contains(ch) ? "\\" + String(ch) : String(ch)
            }
        }
        return out
    }

    static func rev(_ c: Invocation) async throws -> Int32 {
        for (_, data) in c.inputs(c.args) { if let data { lines(data).forEach { c.out.line(String($0.reversed())) } } }
        return 0
    }

    static func tee(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("a")
        for file in o.operands { try c.files.writeData(c.path(file), c.stdin, append: o.has("a")) }
        c.out.write(c.stdin)
        return 0
    }

    static func seq(_ c: Invocation) async throws -> Int32 {
        let n = c.args.compactMap { Int($0) }
        guard n.count == c.args.count, (1...3).contains(n.count) else { return c.fail("usage: seq [FIRST [STEP]] LAST") }
        let (first, step, last) = n.count == 1 ? (1, 1, n[0]) : n.count == 2 ? (n[0], 1, n[1]) : (n[0], n[1], n[2])
        guard step != 0 else { return c.fail("step can't be 0") }
        for (i, v) in stride(from: first, through: last, by: step).enumerated() {
            if i % 1000 == 0 { try Task.checkCancellation() }
            c.out.line(String(v))
        }
        return 0
    }

    static func base64(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("dDi", values: "w")
        guard let data = c.inputs(o.operands).first?.data else { return 1 }
        if o.has("d") || o.has("D") {
            let cleaned = String(decoding: data, as: UTF8.self).filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: cleaned) else { return c.fail("invalid input") }
            c.out.write(decoded)
        } else {
            let wrap = o.values["w"].flatMap(Int.init) ?? 76
            let encoded = data.base64EncodedString()
            if wrap <= 0 { c.out.line(encoded) } else {
                stride(from: 0, to: encoded.count, by: wrap).forEach { i in
                    let start = encoded.index(encoded.startIndex, offsetBy: i)
                    c.out.line(String(encoded[start..<(encoded.index(start, offsetBy: wrap, limitedBy: encoded.endIndex) ?? encoded.endIndex)]))
                }
            }
        }
        return 0
    }

    static func xxd(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("C", values: "ls")
        guard var data = c.inputs(o.operands).first?.data else { return 1 }
        let skip = o.values["s"].flatMap(Int.init) ?? 0
        data = data.dropFirst(skip)
        if let n = o.values["l"].flatMap(Int.init) { data = data.prefix(n) }
        let bytes = [UInt8](data)
        for row in stride(from: 0, to: bytes.count, by: 16) {
            if row % 16_384 == 0 { try Task.checkCancellation() }
            let chunk = bytes[row..<min(row + 16, bytes.count)]
            let hex = stride(from: 0, to: 16, by: 2).map { i -> String in
                (0..<2).map { j in row + i + j < bytes.count ? String(format: "%02x", chunk[row + i + j]) : "  " }.joined()
            }.joined(separator: " ")
            let ascii = String(chunk.map { (0x20..<0x7F).contains($0) ? Character(Unicode.Scalar($0)) : "." })
            c.out.line(String(format: "%08x: ", row + skip) + hex + "  " + ascii)
        }
        return 0
    }

    static func digest<H: HashFunction>(_ c: Invocation, _ hash: H.Type) async throws -> Int32 {
        var code: Int32 = 0
        for (name, data) in c.inputs(c.args) {
            guard let data else { code = 1; continue }
            c.out.line(H.hash(data: data).map { String(format: "%02x", $0) }.joined() + "  " + name)
        }
        return code
    }

    // MARK: Files

    static func copy(_ c: Invocation, move: Bool) async throws -> Int32 {
        let o = try c.options(move ? "fniv" : "rRfnaipv")
        guard o.operands.count >= 2 else { return c.fail("missing destination operand") }
        let dest = c.path(o.operands.last!)
        let intoDir = c.files.exists(dest) && (try? c.files.info(dest).isDirectory) == true
        let sources = o.operands.dropLast()
        guard sources.count == 1 || intoDir else { return c.fail("target '\(o.operands.last!)' is not a directory") }
        var code: Int32 = 0
        for s in sources {
            let src = c.path(s)
            do {
                let info = try c.files.info(src)
                if info.isDirectory && !move && !o.has("r") && !o.has("R") && !o.has("a") {
                    c.err.line("cp: -r not specified; omitting directory '\(s)'")
                    code = 1
                    continue
                }
                let target = intoDir ? RemoteFiles.join(dest, (src as NSString).lastPathComponent) : dest
                if c.files.exists(target) {
                    if o.has("n") { continue }
                    if try c.files.info(target).isDirectory {
                        c.err.line("\(c.name): '\(o.operands.last!)/\((src as NSString).lastPathComponent)' already exists")
                        code = 1
                        continue
                    }
                    try c.files.removeItem(target)
                }
                try c.files.copy(src, to: target, move: move)
                if o.has("v") { c.out.line("'\(s)' -> '\(c.shell.display(target))'") }
            } catch {
                c.err.line("\(c.name): \(s): \(describe(error))")
                code = 1
            }
        }
        return code
    }

    static func rm(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("rRfiv")
        guard !o.operands.isEmpty || o.has("f") else { return c.fail("missing operand") }
        var code: Int32 = 0
        for arg in o.operands {
            let p = c.path(arg)
            guard c.files.exists(p) else {
                if !o.has("f") { c.err.line("rm: \(arg): No such file or directory"); code = 1 }
                continue
            }
            do {
                if try c.files.info(p).isDirectory, !(try c.files.info(p).isLink), !o.has("r"), !o.has("R") {
                    c.err.line("rm: \(arg): is a directory")
                    code = 1
                    continue
                }
                try c.files.removeItem(p)
                if o.has("v") { c.out.line("removed '\(arg)'") }
            } catch {
                c.err.line("rm: \(arg): \(describe(error))")
                code = 1
            }
        }
        return code
    }

    static func mkdir(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("pv", values: "m")
        guard !o.operands.isEmpty else { return c.fail("missing operand") }
        var code: Int32 = 0
        for arg in o.operands {
            do {
                try c.files.makeDirectory(c.path(arg), parents: o.has("p"))
            } catch {
                c.err.line("mkdir: \(arg): \(describe(error))")
                code = 1
            }
        }
        return code
    }

    static func rmdir(_ c: Invocation) async throws -> Int32 {
        var code: Int32 = 0
        for arg in c.args {
            let p = c.path(arg)
            guard (try? FileManager.default.contentsOfDirectory(atPath: c.files.url(p).path))?.isEmpty == true else {
                c.err.line("rmdir: \(arg): Directory not empty or not a directory")
                code = 1
                continue
            }
            try c.files.removeItem(p)
        }
        return code
    }

    static func touch(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("acm")
        for arg in o.operands {
            let p = c.path(arg)
            if c.files.exists(p) {
                try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: c.files.url(p).path)
            } else {
                try c.files.writeData(p, Data())
            }
        }
        return 0
    }

    static func ln(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("sfv")
        guard o.has("s") else { return c.fail("only symbolic links (-s) are supported") }
        guard o.operands.count == 2 else { return c.fail("usage: ln -s TARGET LINK") }
        var link = c.path(o.operands[1])
        if (try? c.files.info(link).isDirectory) == true { link = RemoteFiles.join(link, (o.operands[0] as NSString).lastPathComponent) }
        if o.has("f"), c.files.exists(link) { try c.files.removeItem(link) }
        try FileManager.default.createSymbolicLink(atPath: c.files.url(link).path, withDestinationPath: c.files.url(c.path(o.operands[0])).path)
        return 0
    }

    static func open(_ c: Invocation) async throws -> Int32 {
        guard let arg = c.args.first(where: { !$0.hasPrefix("-") }) else { return c.fail("usage: \(c.name) FILE") }
        let p = c.path(arg)
        if !c.files.exists(p) {
            guard c.name != "open" else { return c.fail("\(arg): No such file or directory") }
            try c.files.writeData(p, Data())
        }
        c.shell.onOpen?(p)
        return 0
    }

    // MARK: System

    static func date(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("uR")
        var format = o.operands.first(where: { $0.hasPrefix("+") }).map { String($0.dropFirst()) } ?? "%a %b %e %H:%M:%S %Z %Y"
        if o.has("R") { format = "%a, %d %b %Y %H:%M:%S %z" }
        var t = time(nil)
        var parts = tm()
        if o.has("u") { gmtime_r(&t, &parts) } else { localtime_r(&t, &parts) }
        var buf = [CChar](repeating: 0, count: 512)
        let n = strftime(&buf, buf.count, format, &parts)
        c.out.line(String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self))
        return 0
    }

    private static func systemName() -> (sysname: String, nodename: String, release: String, machine: String) {
        var u = utsname()
        Darwin.uname(&u)
        func field<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return (field(u.sysname), field(u.nodename), field(u.release), field(u.machine))
    }

    static func uname(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("asnrmv")
        let s = systemName()
        var out: [String] = []
        if o.has("a") || o.has("s") || o.flags.isEmpty { out.append(s.sysname) }
        if o.has("a") || o.has("n") { out.append(s.nodename) }
        if o.has("a") || o.has("r") { out.append(s.release) }
        if o.has("a") || o.has("v") { out.append(ProcessInfo.processInfo.operatingSystemVersionString) }
        if o.has("a") || o.has("m") { out.append(s.machine) }
        c.out.line(out.joined(separator: " "))
        return 0
    }

    static func hostname(_ c: Invocation) async throws -> Int32 {
        c.out.line(systemName().nodename)
        return 0
    }

    static func uptime(_ c: Invocation) async throws -> Int32 {
        let s = Int(ProcessInfo.processInfo.systemUptime)
        let mem = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        c.out.line("up \(s / 86400) days, \(s % 86400 / 3600):\(String(format: "%02d", s % 3600 / 60)), \(ProcessInfo.processInfo.activeProcessorCount) CPUs, \(String(format: "%.1f", mem)) GB memory")
        return 0
    }

    static func curl(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("sSLIfkOvi", values: "oXdHA")
        guard let address = o.operands.first, let url = URL(string: address.contains("://") ? address : "https://" + address) else {
            return c.fail("usage: curl [-sLIO] [-o FILE] [-X METHOD] [-d DATA] [-H 'Name: value'] URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = o.values["X"] ?? (o.has("I") ? "HEAD" : o.values["d"] != nil ? "POST" : "GET")
        if let body = o.values["d"] { request.httpBody = Data(body.utf8) }
        if let header = o.values["H"], let colon = header.firstIndex(of: ":") {
            request.setValue(header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: String(header[..<colon]))
        }
        request.setValue(o.values["A"] ?? "curl/8 (Secure VNC)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        if o.has("I") || o.has("i"), let http {
            c.out.line("HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
            for (k, v) in http.allHeaderFields { c.out.line("\(k): \(v)") }
            c.out.line("")
        }
        if o.has("f"), let http, http.statusCode >= 400 { return c.fail("The requested URL returned error: \(http.statusCode)") }
        guard !o.has("I") else { return 0 }
        if let file = o.values["o"] ?? (o.has("O") ? remoteName(url) : nil) {
            try c.files.writeData(c.path(file), data)
        } else {
            c.out.write(data)
        }
        return 0
    }

    static func wget(_ c: Invocation) async throws -> Int32 {
        let o = try c.options("qc", values: "O")
        guard let address = o.operands.first, let url = URL(string: address.contains("://") ? address : "https://" + address) else {
            return c.fail("usage: wget [-O FILE] URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return c.fail("server returned \(http.statusCode)") }
        let file = o.values["O"] ?? remoteName(response.url ?? url)
        if file == "-" { c.out.write(data); return 0 }
        try c.files.writeData(c.path(file), data)
        if !o.has("q") { c.out.line("Saved '\(file)' (\(human(data.count)))") }
        return 0
    }

    private static func remoteName(_ url: URL) -> String {
        url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "index.html" : url.lastPathComponent
    }

    static func pbcopy(_ c: Invocation) async throws -> Int32 {
        #if canImport(UIKit)
        let text = c.stdinText
        await MainActor.run { UIPasteboard.general.string = text }
        return 0
        #else
        return c.fail("no clipboard")
        #endif
    }

    static func pbpaste(_ c: Invocation) async throws -> Int32 {
        #if canImport(UIKit)
        c.out.write(await MainActor.run { UIPasteboard.general.string ?? "" })
        return 0
        #else
        return c.fail("no clipboard")
        #endif
    }

    /// `\n`, `\t`, `\\`, `\e`, `\0NNN`.
    static func unescape(_ s: String) -> String {
        var out = ""
        var it = Array(s)[...]
        while let ch = it.popFirst() {
            guard ch == "\\", let next = it.popFirst() else { out.append(ch); continue }
            switch next {
            case "n": out += "\n"
            case "t": out += "\t"
            case "r": out += "\r"
            case "a": out += "\u{07}"
            case "e": out += "\u{1B}"
            case "\\": out += "\\"
            case "0":
                var digits = ""
                while digits.count < 3, let d = it.first, ("0"..."7").contains(d) { digits.append(d); it.removeFirst() }
                out.append(Character(Unicode.Scalar(UInt8(digits, radix: 8) ?? 0)))
            default: out += "\\" + String(next)
            }
        }
        return out
    }
}

extension Invocation {
    /// The same call with extra leading arguments, for aliases such as `ll`.
    func with(_ extra: [String]) -> Invocation {
        Invocation(shell: shell, name: name, args: extra + args, stdin: stdin, out: out, err: err)
    }
}
