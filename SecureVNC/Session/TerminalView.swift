import SecureVNCKit
import SwiftUI
import UIKit

/// Line-based shell on a `dumb` pty: commands go in a line at a time, output is plain text.
@MainActor
final class Terminal: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var history: [String] = []
    @Published var clipboard: FileClipboard?
    /// A file the picker chose from an editor pane, for the terminal view to open.
    @Published var fileToOpen: RemoteFile?
    /// A tmux pane mirrored instead of this connection's shell, which keeps running underneath.
    @Published private(set) var pane: RemotePane?
    @Published private(set) var paneOutput = ""
    /// A Claude Code session followed through its transcript; input goes to its tmux pane.
    @Published private(set) var claude: ClaudeSession?
    @Published private(set) var claudeOutput = ""
    /// Show the Claude pane's actual screen instead of the transcript: permission prompts and
    /// option menus only exist there.
    @Published var claudeScreen = false
    private var claudeOffset = -1
    private var claudeBase = ""
    /// A prompt typed here and shown at once, until the transcript records it.
    private var pendingPrompt: String?
    private var mirrorTask: Task<Void, Never>?
    private var tunnel: SSHTunnel?
    private var pending: [UInt8] = []
    private var carriageReturn = false
    private var size = (columns: 0, rows: 0)
    private static let maxOutput = 60_000

    /// Output survives reconnects; each new shell gets a divider.
    func attach(_ tunnel: SSHTunnel) {
        if !output.isEmpty { append("\n──── reconnected ────\n") }
        self.tunnel = tunnel
        pending = []
        carriageReturn = false
        if size.columns > 0 { tunnel.resize(columns: size.columns, rows: size.rows) }
        if pane != nil { pollPane() }
        if claude != nil { pollClaude() }
    }

    func detach() {
        tunnel = nil
        mirrorTask?.cancel()
    }

    var files: RemoteFiles? { tunnel.map(RemoteFiles.init) }
    var panes: RemotePanes? { tunnel.map { RemotePanes(tunnel: $0) } }
    var claudeSessions: ClaudeSessions? { tunnel.map(ClaudeSessions.init) }
    var shown: String {
        if claude != nil { return claudeScreen ? paneOutput : claudeOutput }
        return pane != nil ? paneOutput : output
    }
    /// The tmux pane input goes to, if anything other than this connection's shell is followed.
    private var targetPane: String? { claude?.pane ?? pane?.id }

    func follow(_ pane: RemotePane?) {
        mirrorTask?.cancel()
        claude = nil
        self.pane = pane
        paneOutput = ""
        if pane != nil { pollPane() }
    }

    func follow(claude session: ClaudeSession?) {
        mirrorTask?.cancel()
        pane = nil
        claude = session
        claudeBase = ""
        pendingPrompt = nil
        paneOutput = ""
        claudeScreen = false
        claudeOffset = -1
        renderClaude()
        if session != nil { pollClaude() }
    }

    /// Starting folder for the file browser: the followed pane's or Claude session's, else the shell's.
    func currentDirectory() async -> String {
        if let claude, !claude.cwd.isEmpty { return claude.cwd }
        if let pane, let path = try? await panes?.currentPath(pane.id), !path.isEmpty { return path }
        return (try? await files?.shellDirectory()) ?? "/"
    }

    private func pollPane() {
        mirrorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshPane()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func pollClaude() {
        mirrorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.refreshClaude() == true else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// False once the session is gone, which ends polling but keeps what was shown.
    private func refreshClaude() async -> Bool {
        guard let claude, let claudeSessions else { return false }
        do {
            let update = try await claudeSessions.poll(claude, offset: claudeOffset)
            guard self.claude == claude else { return false }
            if claudeScreen, let pane = claude.pane, let panes, let text = try? await panes.capture(pane, history: 200) {
                paneOutput = text
            }
            claudeOffset = update.offset
            if !update.text.isEmpty {
                claudeBase = Self.trimmed(claudeBase + update.text)
                if let prompt = pendingPrompt, update.text.contains("❯ " + prompt) { pendingPrompt = nil }
            }
            if update.status != claude.status { self.claude?.status = update.status }
            if update.status == "exited" {
                claudeBase += "\n[session ended]\n"
                pendingPrompt = nil
            }
            renderClaude()
            return update.status != "exited"
        } catch {
            guard self.claude == claude else { return false }
            claudeBase += "\n[\(error.localizedDescription)]\n"
            pendingPrompt = nil
            renderClaude()
            return false
        }
    }

    /// Transcript, then the prompt not yet echoed back, then `⋯` while Claude is working.
    private func renderClaude() {
        var out = claudeBase
        if let pendingPrompt { out += "\n❯ \(pendingPrompt)\n" }
        if pendingPrompt != nil || claude?.busy == true { out += "\n⋯\n" }
        claudeOutput = out
    }

    var claudeWorking: Bool { claude != nil && (pendingPrompt != nil || claude?.busy == true) }

    private func refreshPane() async {
        guard let pane, let panes else { return }
        do {
            let text = try await panes.capture(pane.id)
            if self.pane == pane, text != paneOutput { paneOutput = text }
        } catch {
            guard self.pane == pane else { return }
            paneOutput += "\n[\(error.localizedDescription)]"
            follow(nil)
        }
    }

    private func toPane(_ action: @escaping (RemotePanes, String) async throws -> Void) {
        guard let target = targetPane, let panes else {
            if claude != nil {
                claudeBase += "\n[This session isn't in a tmux pane, so it can only be read.]\n"
                pendingPrompt = nil
                renderClaude()
            }
            return
        }
        Task {
            try? await action(panes, target)
            try? await Task.sleep(for: .milliseconds(120))
            if pane != nil { await refreshPane() } else { _ = await refreshClaude() }
        }
    }

    func note(_ text: String) { append("\n[\(text)]\n") }

    /// The last line looks like a password prompt, so input should be hidden.
    var wantsSecret: Bool {
        let line = shown.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return line.range(of: #"(?i)(password|passphrase|passcode)[^:]*:\s*$"#, options: .regularExpression) != nil
    }

    func send(_ line: String, secret: Bool = false) {
        if !secret, !line.isEmpty, history.last != line { history.append(line) }
        if claude != nil, !line.isEmpty {
            pendingPrompt = line
            renderClaude()
        }
        if pane != nil || claude != nil { return toPane { try await $0.sendLine($1, line) } }
        tunnel?.send(Array((line + "\r").utf8))
    }

    func sendControl(_ letter: Character) {
        if pane != nil || claude != nil { return toPane { try await $0.sendKey($1, "C-\(letter.lowercased())") } }
        guard let ascii = letter.uppercased().first?.asciiValue else { return }
        tunnel?.send([ascii & 0x1F])
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, (columns, rows) != size else { return }
        size = (columns, rows)
        tunnel?.resize(columns: columns, rows: rows)
    }

    /// A tmux key name such as `Escape` or `BTab`, for a followed pane or Claude session.
    func sendKey(_ key: String) { toPane { try await $0.sendKey($1, key) } }

    func clear() { if pane == nil, claude == nil { output = "" } }

    func run() async throws {
        guard let tunnel else { throw TransportError.closed }
        while true {
            let bytes = try await tunnel.readAvailable()
            guard tunnel === self.tunnel else { throw TransportError.closed }
            pending += bytes
            let cut = Self.completeUTF8Prefix(pending)
            append(Self.stripEscapes(String(decoding: pending[..<cut], as: UTF8.self)))
            pending.removeFirst(cut)
        }
    }

    /// Applies `\r` (rewrite the current line) and backspace, so progress bars and prompts read cleanly.
    private func append(_ text: String) {
        var out = output
        for ch in text {
            switch ch {
            case "\n", "\r\n":
                out.append("\n")
                carriageReturn = false
            case "\r":
                carriageReturn = true
            case "\u{8}":
                if let last = out.last, last != "\n" { out.removeLast() }
            default:
                if carriageReturn {
                    if let nl = out.lastIndex(of: "\n") { out.removeSubrange(out.index(after: nl)...) } else { out = "" }
                    carriageReturn = false
                }
                out.append(ch)
            }
        }
        output = Self.trimmed(out)
    }

    /// The tail of `text` within `maxOutput`, cut at a line start.
    private static func trimmed(_ text: String) -> String {
        guard text.count > maxOutput else { return text }
        let start = text.index(text.endIndex, offsetBy: -maxOutput)
        return String(text[(text[start...].firstIndex(of: "\n").map { text.index(after: $0) } ?? start)...])
    }

    /// Length up to the last full UTF-8 sequence, so a character split across reads isn't mangled.
    static func completeUTF8Prefix(_ bytes: [UInt8]) -> Int {
        var back = 1
        while back <= min(4, bytes.count) {
            let b = bytes[bytes.count - back]
            if b & 0xC0 != 0x80 {
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
                return need > back ? bytes.count - back : bytes.count
            }
            back += 1
        }
        return bytes.count
    }

    static func stripEscapes(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u001B(\[[0-?]*[ -/]*[@-~]|\][^\u0007\u001B]*(\u0007|\u001B\\)|[@-_])|\u0007"#,
                                  with: "", options: .regularExpression)
    }
}

struct TerminalView: View {
    @ObservedObject var terminal: Terminal
    let title: String
    let phase: SessionModel.Phase
    let reconnect: () -> Void
    let close: () -> Void
    @State private var command = ""
    @State private var recall: Int?
    @State private var browsing = false
    @State private var pickingPane = false
    @State private var openFile: RemoteFile?
    @AppStorage("terminal.wrap") private var wrap = ConsoleWrap.screen
    @AppStorage("terminal.fontSize") private var fontSize = 13.0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ConsoleText(text: terminal.shown, wrap: wrap, fontSize: $fontSize) { terminal.resize(columns: $0, rows: $1) }
            switch phase {
            case .live: inputBar
            case .connecting(let text): statusBar { ProgressView().tint(.white); Text(text) }
            case .failed(let text, _):
                statusBar {
                    Text(text).lineLimit(2)
                    Spacer()
                    Button("Reconnect", action: reconnect).buttonStyle(.borderedProminent)
                }
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
        .onChange(of: terminal.wantsSecret) { focused = true }
        .sheet(isPresented: $browsing) {
            if let files = terminal.files { FileBrowserView(files: files, terminal: terminal) }
        }
        .sheet(isPresented: $pickingPane) { PanePicker(terminal: terminal) }
        .sheet(item: $openFile) { file in
            if let files = terminal.files { FileBrowserView(files: files, terminal: terminal, open: file) }
        }
        .onChange(of: terminal.fileToOpen) { _, file in
            guard let file else { return }
            terminal.fileToOpen = nil
            // Let the picker sheet finish dismissing before presenting another.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                openFile = file
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Disconnect")
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold))
                if let claude = terminal.claude {
                    HStack(spacing: 6) {
                        Text("claude \(claude.name) · \(claude.status)\(terminal.claudeScreen ? " · screen" : "")")
                        if terminal.claudeWorking { ProgressView().controlSize(.mini).tint(.orange) }
                    }
                    .font(.caption2)
                    .foregroundStyle(claude.exited ? .gray : claude.busy ? .orange : .green)
                } else if let pane = terminal.pane {
                    Text("tmux \(pane.target)").font(.caption2).foregroundStyle(.green)
                }
            }
            .lineLimit(1)
            Spacer()
            if terminal.claude != nil {
                Button("esc") { terminal.sendKey("Escape") }.accessibilityLabel("Interrupt Claude")
            } else {
                Button("^C") { terminal.sendControl("c") }.accessibilityLabel("Interrupt")
            }
            Button { browsing = true } label: { Image(systemName: "folder") }
                .disabled(phase != .live).accessibilityLabel("Files")
            Button { pickingPane = true } label: {
                Image(systemName: terminal.claude != nil ? "sparkles" : terminal.pane == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
            }
            .disabled(phase != .live).accessibilityLabel("Talk to")
            Menu {
                if terminal.claude != nil {
                    Toggle("Show Screen", systemImage: "rectangle.on.rectangle", isOn: $terminal.claudeScreen)
                    Button("Send Enter", systemImage: "return") { terminal.sendKey("Enter") }
                    Button("Send Tab", systemImage: "arrow.right.to.line") { terminal.sendKey("Tab") }
                    Button("Cycle Mode (⇧Tab)", systemImage: "arrow.triangle.2.circlepath") { terminal.sendKey("BTab") }
                    Button("Send ^C", systemImage: "xmark.octagon") { terminal.sendControl("c") }
                } else {
                    Button("Send ^D", systemImage: "eject") { terminal.sendControl("d") }
                }
                if terminal.pane == nil, terminal.claude == nil {
                    Button("Clear", systemImage: "trash") { terminal.clear() }
                } else {
                    Button("Back to Shell", systemImage: "terminal") { terminal.follow(nil) }
                }
                Picker(selection: $wrap) {
                    ForEach(ConsoleWrap.allCases, id: \.self) { Text($0.label) }
                } label: {
                    Label("Wrap: \(wrap.label)", systemImage: "text.word.spacing")
                }
                .pickerStyle(.menu)
                Button("Reconnect", systemImage: "arrow.clockwise", action: reconnect)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.body.monospaced().weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func statusBar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10) { content() }
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Group {
                if terminal.wantsSecret {
                    SecureField("password", text: $command)
                } else {
                    TextField(terminal.claude != nil ? "message to Claude" : "command", text: $command)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($focused)
            .onSubmit(submit)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(terminal.history.isEmpty).accessibilityLabel("Previous command")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(recall == nil).accessibilityLabel("Next command")
            Button("Send", action: submit).buttonStyle(.borderedProminent).controlSize(.small)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func submit() {
        terminal.send(command, secret: terminal.wantsSecret)
        command = ""
        recall = nil
        focused = true
    }

    private func step(_ delta: Int) {
        let h = terminal.history
        guard !h.isEmpty else { return }
        let next = (recall ?? h.count) + delta
        if next >= h.count {
            recall = nil
            command = ""
        } else {
            recall = max(0, next)
            command = h[recall!]
        }
    }
}

enum ConsoleWrap: String, CaseIterable {
    case screen, wide, off

    var label: String {
        switch self {
        case .screen: "Fit Screen"
        case .wide: "160 Columns"
        case .off: "No Wrap"
        }
    }
}

/// Read-only console: free-range text selection, appends without losing it, follows the tail,
/// scrolls sideways when lines are wider than the screen, pinch to zoom.
struct ConsoleText: UIViewRepresentable {
    let text: String
    let wrap: ConsoleWrap
    @Binding var fontSize: Double
    let onSize: (_ columns: Int, _ rows: Int) -> Void

    func makeUIView(context: Context) -> ConsoleView { ConsoleView() }

    func updateUIView(_ view: ConsoleView, context: Context) {
        view.onSize = onSize
        view.onFontSize = { fontSize = $0 }
        view.configure(wrap: wrap, fontSize: fontSize)
        view.textView.show(text)
    }
}

/// Horizontal scroller around a vertically scrolling text view.
final class ConsoleView: UIScrollView {
    let textView = ConsoleTextView()
    var onSize: ((Int, Int) -> Void)?
    var onFontSize: ((Double) -> Void)?
    private var wrap = ConsoleWrap.screen
    private var pinchStart: CGFloat = 13

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        addSubview(textView)
        textView.onChange = { [weak self] in if self?.wrap == .off { self?.setNeedsLayout() } }
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(wrap: ConsoleWrap, fontSize: Double) {
        let changed = wrap != self.wrap || CGFloat(fontSize) != textView.fontSize
        self.wrap = wrap
        textView.fontSize = CGFloat(fontSize)
        if changed { setNeedsLayout() }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        if pinch.state == .began { pinchStart = textView.fontSize }
        let size = min(24, max(7, (pinchStart * pinch.scale).rounded()))
        guard size != textView.fontSize else { return }
        textView.fontSize = size
        onFontSize?(Double(size))
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let charWidth = textView.charWidth
        let chrome = textView.textContainerInset.left + textView.textContainerInset.right + 2 * textView.textContainer.lineFragmentPadding
        let fit = max(1, Int((bounds.width - chrome) / charWidth))
        let columns: Int
        let reported: Int
        switch wrap {
        case .screen: (columns, reported) = (fit, fit)
        case .wide: (columns, reported) = (160, 160)
        case .off: (columns, reported) = (max(fit, textView.longestLine), 250)
        }
        let width = max(bounds.width, ceil(CGFloat(columns) * charWidth + chrome))
        if textView.frame.size != CGSize(width: width, height: bounds.height) {
            textView.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        }
        contentSize = CGSize(width: width, height: bounds.height)
        alwaysBounceHorizontal = width > bounds.width
        let rows = max(1, Int((bounds.height - textView.textContainerInset.top - textView.textContainerInset.bottom) / textView.lineHeight))
        onSize?(reported, rows)
    }
}

final class ConsoleTextView: UITextView {
    var onChange: (() -> Void)?
    private(set) var longestLine = 0
    private var shown = ""
    var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            textStorage.addAttribute(.font, value: font(), range: NSRange(location: 0, length: textStorage.length))
        }
    }

    var charWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: font()]).width }
    var lineHeight: CGFloat { font().lineHeight }

    private func font() -> UIFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    private var attributes: [NSAttributedString.Key: Any] { [.font: font(), .foregroundColor: UIColor.white] }

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false
        isSelectable = true
        backgroundColor = .black
        tintColor = .systemGreen
        textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        dataDetectorTypes = []
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        guard text != shown else { return }
        let follow = selectedRange.length == 0 && contentOffset.y >= contentSize.height - bounds.height - 40
        let appends = text.hasPrefix(shown)
        if !appends, selectedRange.length > 0 { return }
        if appends {
            textStorage.append(NSAttributedString(string: String(text.dropFirst(shown.count)), attributes: attributes))
        } else {
            textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        shown = text
        let longest = text.split(separator: "\n", omittingEmptySubsequences: false).lazy.map(\.count).max() ?? 0
        if longest != longestLine {
            longestLine = longest
            onChange?()
        }
        if follow {
            layoutManager.ensureLayout(for: textContainer)
            scrollRangeToVisible(NSRange(location: textStorage.length, length: 0))
        }
    }
}

struct PanePicker: View {
    @ObservedObject var terminal: Terminal
    @Environment(\.dismiss) private var dismiss
    @State private var panes: [RemotePane]?
    @State private var sessions: [ClaudeSession]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(title: "This connection's shell", detail: "Line-based shell",
                        selected: terminal.pane == nil && terminal.claude == nil) { terminal.follow(nil) }
                }
                Section("Claude sessions") {
                    if let sessions {
                        if sessions.isEmpty { Text("No Claude Code running on this host.").foregroundStyle(.secondary) }
                        ForEach(sessions) { claudeRow($0) }
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                Section("tmux panes") {
                    if let panes {
                        if panes.isEmpty { Text("No tmux sessions on this host.").foregroundStyle(.secondary) }
                        ForEach(panes) { pane in
                            row(title: "\(pane.target)  \(pane.windowName)",
                                detail: pane.isEditor ? "\(pane.command) · opens its file in the text editor" : "\(pane.command) · \(pane.path)",
                                selected: terminal.pane?.id == pane.id, icon: pane.isEditor ? "doc.text" : nil) {
                                if pane.isEditor { openEditorFile(pane) } else { terminal.follow(pane) }
                            }
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Talk To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func claudeRow(_ s: ClaudeSession) -> some View {
        Button {
            terminal.follow(claude: s)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Circle().fill(s.busy ? Color.orange : .green).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.body.monospaced()).foregroundStyle(.primary)
                    Text((s.pane == nil ? "read only · " : "") + Self.shortPath(s.cwd))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                Text("\(s.status) · \(Self.age(s.updatedAt))").font(.caption).foregroundStyle(.secondary)
                if terminal.claude?.id == s.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    /// `/Users/me/x` or `/home/me/x` as `~/x`.
    static func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/(Users|home)/[^/]+(?=/|$)"#, with: "~", options: .regularExpression)
    }

    static func age(_ date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        return s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : s < 86400 ? "\(s / 3600)h" : "\(s / 86400)d"
    }

    private func row(title: String, detail: String, selected: Bool, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.monospaced()).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }

    /// Opens the editor's file in the app; falls back to mirroring the pane when it can't be found.
    private func openEditorFile(_ pane: RemotePane) {
        guard let remote = terminal.panes else { return }
        Task {
            if let path = try? await remote.editorFile(pane) {
                terminal.fileToOpen = RemoteFile(name: (path as NSString).lastPathComponent, path: path, isDirectory: false, size: nil)
            } else {
                terminal.follow(pane)
            }
        }
    }

    private func load() async {
        guard let remote = terminal.panes, let claude = terminal.claudeSessions else { return }
        do {
            async let p = remote.list()
            async let s = claude.list()
            panes = try await p
            sessions = try await s
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
