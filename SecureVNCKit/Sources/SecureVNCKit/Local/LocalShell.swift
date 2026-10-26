import Foundation

/// A shell that runs on this device: typed lines in, output out, like a pty. iOS apps can't start
/// programs, so every command is built in (`Builtins`) and works on `LocalFiles`.
public final class LocalShell: ShellChannel, @unchecked Sendable {
    public let files: LocalFiles
    /// `open`/`edit` hand a file to the app to preview or edit.
    public var onOpen: (@Sendable (String) -> Void)? {
        get { lock.withLock { openHandler } }
        set { lock.withLock { openHandler = newValue } }
    }

    private let lock = NSLock()
    private let reader: ChunkReader
    private let output: AsyncThrowingStream<[UInt8], Error>.Continuation
    private var openHandler: (@Sendable (String) -> Void)?
    private var line: [UInt8] = []
    private var queue: [String] = []
    private var draining = false
    private var current: Task<Void, Never>?
    private var cwd: String
    private var previous: String
    private var vars: [String: String]
    private var status: Int32 = 0
    private var commands: [String] = []
    private var width = 80
    private var closed = false

    public init(files: LocalFiles, home: String = "/Documents") {
        self.files = files
        let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
        reader = ChunkReader(stream)
        output = continuation
        cwd = files.exists(home) ? home : "/"
        previous = cwd
        vars = ["HOME": home, "USER": "mobile", "SHELL": "builtin", "TERM": "dumb", "LANG": "en_US.UTF-8", "PWD": cwd]
        emit("Built-in shell on this device: `help` lists the commands. Linked folders and drives are under /.\n" + prompt)
    }

    // MARK: ShellChannel

    public func readAvailable() async throws -> [UInt8] { try await reader.readAvailable() }

    public func send(_ bytes: [UInt8]) {
        for byte in bytes {
            switch byte {
            case 0x03: interrupt()
            case 0x0D, 0x0A:
                let text = lock.withLock { () -> String in
                    defer { line = [] }
                    return String(decoding: line, as: UTF8.self)
                }
                submit(text)
            case 0x7F, 0x08: lock.withLock { _ = line.popLast() }
            case 0x04: break
            default: lock.withLock { line.append(byte) }
            }
        }
    }

    public func resize(columns: Int, rows: Int) { lock.withLock { width = columns } }

    public func close() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            closed = true
            queue = []
            return current
        }
        task?.cancel()
        output.finish()
    }

    // MARK: State

    public var directory: String { lock.withLock { cwd } }
    var home: String { variable("HOME") ?? "/" }
    var columns: Int { lock.withLock { width } }
    var history: [String] { lock.withLock { commands } }

    func variable(_ name: String) -> String? {
        lock.withLock {
            switch name {
            case "?": String(status)
            case "$": String(ProcessInfo.processInfo.processIdentifier)
            case "PWD": cwd
            default: vars[name]
            }
        }
    }

    var environment: [String: String] { lock.withLock { vars.merging(["PWD": cwd]) { $1 } } }

    func setVariable(_ name: String, _ value: String?) { lock.withLock { vars[name] = value } }

    func changeDirectory(_ path: String) {
        lock.withLock {
            if path != cwd { previous = cwd }
            cwd = path
        }
    }

    var previousDirectory: String { lock.withLock { previous } }

    /// A path typed in this shell as a full path in `files`.
    func resolve(_ path: String) -> String {
        LocalFiles.normalize(path.hasPrefix("/") ? path : directory + "/" + path)
    }

    /// `~/x` for a path in `$HOME`.
    func display(_ path: String) -> String {
        let home = home
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var prompt: String { "\(display(directory)) $ " }

    func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        output.yield([UInt8](data))
    }

    private func emit(_ text: String) { emit(Data(text.utf8)) }

    // MARK: Running

    private func submit(_ text: String) {
        let start = lock.withLock { () -> Bool in
            guard !closed else { return false }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty, commands.last != text { commands.append(text) }
            queue.append(text)
            defer { draining = true }
            return !draining
        }
        emit(text + "\n")
        if start { Task { await drain() } }
    }

    private func interrupt() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            queue = []
            line = []
            return current
        }
        emit("^C\n")
        if let task { task.cancel() } else { emit(prompt) }
    }

    private func drain() async {
        while let text = lock.withLock({ () -> String? in
            if queue.isEmpty || closed { draining = false; return nil }
            return queue.removeFirst()
        }) {
            let task = Task { await self.run(text) }
            lock.withLock { current = task }
            await task.value
            lock.withLock { current = nil }
            emit(prompt)
        }
    }

    func run(_ text: String) async {
        let terminal = Sink(forward: { [weak self] in self?.emit($0) })
        let code = await run(text, out: terminal, err: terminal)
        terminal.flush()
        lock.withLock { status = code }
    }

    /// Runs a line of commands; the exit status of the last one run.
    func run(_ text: String, out: Sink, err: Sink, stdin: Data = Data()) async -> Int32 {
        let segments: [(String, Connector)]
        do { segments = try ShellSyntax.split(text) } catch {
            err.line("sh: \(error.localizedDescription)")
            return 2
        }
        var code = lock.withLock { status }
        for (segment, connector) in segments {
            if connector == .and && code != 0 || connector == .or && code == 0 { continue }
            guard !Task.isCancelled else { return 130 }
            code = await pipeline(segment, out: out, err: err, stdin: stdin)
            lock.withLock { status = code }
        }
        return code
    }

    private struct Stage {
        var argv: [String] = []
        var input: String?
        var output: (path: String, append: Bool)?
        var error: (path: String, append: Bool)?
        var errorToOutput = false
    }

    private func pipeline(_ segment: String, out: Sink, err: Sink, stdin: Data) async -> Int32 {
        do {
            let tokens = try ShellSyntax.tokens(segment, variable: variable, home: home)
            var stages = [Stage()]
            var i = 0
            while i < tokens.count {
                switch tokens[i] {
                case .word(let word): stages[stages.count - 1].argv += expand(word)
                case .pipe:
                    guard !stages[stages.count - 1].argv.isEmpty else { throw ShellError("syntax error near |") }
                    stages.append(Stage())
                case .redirect(let kind):
                    if kind == .errorToOutput {
                        stages[stages.count - 1].errorToOutput = true
                        break
                    }
                    guard i + 1 < tokens.count, case .word(let target) = tokens[i + 1] else {
                        throw ShellError("syntax error: redirect without a file")
                    }
                    i += 1
                    let path = target.text
                    switch kind {
                    case .input: stages[stages.count - 1].input = path
                    case .output, .append: stages[stages.count - 1].output = (path, kind == .append)
                    case .errorOutput, .errorAppend: stages[stages.count - 1].error = (path, kind == .errorAppend)
                    case .bothOutput:
                        stages[stages.count - 1].output = (path, false)
                        stages[stages.count - 1].errorToOutput = true
                    case .errorToOutput: break
                    }
                }
                i += 1
            }
            guard !stages[stages.count - 1].argv.isEmpty || stages.count == 1 else { throw ShellError("syntax error near |") }

            var input = stdin
            var code: Int32 = 0
            for (n, stage) in stages.enumerated() {
                try Task.checkCancellation()
                if let path = stage.input { input = try files.readData(resolve(path)) }
                let last = n == stages.count - 1
                let stageOut = stage.output != nil || !last ? Sink() : out
                let stageErr = stage.errorToOutput ? stageOut : stage.error != nil ? Sink() : err
                code = await execute(stage.argv, stdin: input, out: stageOut, err: stageErr)
                if let (path, append) = stage.output { try write(stageOut.data, to: path, append: append) }
                if let (path, append) = stage.error, !stage.errorToOutput { try write(stageErr.data, to: path, append: append) }
                input = last ? Data() : stageOut.data
            }
            return code
        } catch is CancellationError {
            return 130
        } catch {
            err.line("sh: \(Builtins.describe(error))")
            return 1
        }
    }

    private func write(_ data: Data, to path: String, append: Bool) throws {
        guard path != "/dev/null" else { return }
        try files.writeData(resolve(path), data, append: append)
    }

    private func execute(_ argv: [String], stdin: Data, out: Sink, err: Sink) async -> Int32 {
        var argv = argv
        while let first = argv.first, let eq = first.firstIndex(of: "="), Self.isName(first[..<eq]) {
            setVariable(String(first[..<eq]), String(first[first.index(after: eq)...]))
            argv.removeFirst()
        }
        guard let name = argv.first else { return 0 }
        guard let command = Builtins.all[name] else {
            err.line("\(name): command not found (`help` lists the built-in commands)")
            return 127
        }
        let call = Invocation(shell: self, name: name, args: Array(argv.dropFirst()), stdin: stdin, out: out, err: err)
        do {
            return try await command(call)
        } catch is CancellationError {
            return 130
        } catch {
            err.line("\(name): \(Builtins.describe(error))")
            return 1
        }
    }

    static func isName(_ s: Substring) -> Bool {
        guard let first = s.first, first == "_" || first.isLetter else { return false }
        return s.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Glob matches, sorted; the word itself when nothing matches.
    func expand(_ word: Word) -> [String] {
        guard word.globbed else { return [word.text] }
        let absolute = word.pattern.hasPrefix("/")
        var found: [(path: String, shown: String)] = [(absolute ? "/" : directory, absolute ? "/" : "")]
        let parts = word.pattern.split(separator: "/")
        for (n, part) in parts.enumerated() {
            let last = n == parts.count - 1
            var next: [(String, String)] = []
            for (dir, shown) in found {
                let join = { (name: String) in (RemoteFiles.join(dir, name), shown.isEmpty || shown.hasSuffix("/") ? shown + name : shown + "/" + name) }
                if ShellSyntax.hasGlob(part) {
                    guard let names = try? FileManager.default.contentsOfDirectory(atPath: files.url(dir).path) else {
                        if dir == "/" { next += files.mounts.all.keys.filter { fnmatch(String(part), $0, 0) == 0 }.map(join) }
                        continue
                    }
                    for name in names where (!name.hasPrefix(".") || part.hasPrefix(".")) && fnmatch(String(part), name, 0) == 0 {
                        let entry = join(name)
                        if last || (try? files.info(entry.0).isDirectory) == true { next.append(entry) }
                    }
                } else {
                    let entry = join(ShellSyntax.unescape(part))
                    if files.exists(entry.0) { next.append(entry) }
                }
            }
            found = next
        }
        let matches = found.map(\.shown).sorted()
        return matches.isEmpty ? [word.text] : matches
    }
}

/// Collects a command's output: passed on to the terminal in batches, or kept for a pipe or file.
final class Sink: @unchecked Sendable {
    private(set) var data = Data()
    private let forward: ((Data) -> Void)?
    private var lastFlush = Date()

    init(forward: ((Data) -> Void)? = nil) { self.forward = forward }

    func write(_ chunk: Data) {
        data.append(chunk)
        if forward != nil, data.count > 16_384 || Date().timeIntervalSince(lastFlush) > 0.1 { flush() }
    }

    func write(_ text: String) { write(Data(text.utf8)) }
    func line(_ text: String) { write(text + "\n") }

    func flush() {
        guard let forward, !data.isEmpty else { return }
        forward(data)
        data = Data()
        lastFlush = Date()
    }
}
