import SecureVNCKit
import SwiftUI
import UIKit

/// Line-based shell on a `dumb` pty: commands go in a line at a time, output is plain text.
@MainActor
final class Terminal: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var history: [String] = []
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
    }

    func detach() { tunnel = nil }

    func note(_ text: String) { append("\n[\(text)]\n") }

    /// The last line looks like a password prompt, so input should be hidden.
    var wantsSecret: Bool {
        let line = output.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        return line.range(of: #"(?i)(password|passphrase|passcode)[^:]*:\s*$"#, options: .regularExpression) != nil
    }

    func send(_ line: String, secret: Bool = false) {
        if !secret, !line.isEmpty, history.last != line { history.append(line) }
        tunnel?.send(Array((line + "\r").utf8))
    }

    func sendControl(_ letter: Character) {
        guard let ascii = letter.uppercased().first?.asciiValue else { return }
        tunnel?.send([ascii & 0x1F])
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0, (columns, rows) != size else { return }
        size = (columns, rows)
        tunnel?.resize(columns: columns, rows: rows)
    }

    func clear() { output = "" }

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
        if out.count > Self.maxOutput {
            let start = out.index(out.endIndex, offsetBy: -Self.maxOutput)
            out = String(out[(out[start...].firstIndex(of: "\n").map { out.index(after: $0) } ?? start)...])
        }
        output = out
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
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ConsoleText(text: terminal.output) { terminal.resize(columns: $0, rows: $1) }
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
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button(action: close) { Image(systemName: "xmark") }.accessibilityLabel("Disconnect")
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer()
            Button("^C") { terminal.sendControl("c") }.accessibilityLabel("Interrupt")
            Button("^D") { terminal.sendControl("d") }.accessibilityLabel("End of input")
            Button { terminal.clear() } label: { Image(systemName: "trash") }.accessibilityLabel("Clear")
            Button(action: reconnect) { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reconnect")
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
                    TextField("command", text: $command)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.send)
            .focused($focused)
            .onSubmit(submit)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(terminal.history.isEmpty).accessibilityLabel("Previous command")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .disabled(recall == nil).accessibilityLabel("Next command")
            Button(action: submit) { Image(systemName: "return") }.accessibilityLabel("Send")
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

/// Read-only UITextView: free-range text selection, appends without losing it, follows the tail.
struct ConsoleText: UIViewRepresentable {
    let text: String
    let onSize: (_ columns: Int, _ rows: Int) -> Void

    func makeUIView(context: Context) -> ConsoleTextView {
        let view = ConsoleTextView()
        view.onSize = onSize
        return view
    }

    func updateUIView(_ view: ConsoleTextView, context: Context) {
        view.onSize = onSize
        view.show(text)
    }
}

final class ConsoleTextView: UITextView {
    var onSize: ((Int, Int) -> Void)?
    private var shown = ""
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .foregroundColor: UIColor.white,
    ]

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
        if text.hasPrefix(shown) {
            textStorage.append(NSAttributedString(string: String(text.dropFirst(shown.count)), attributes: attributes))
        } else {
            textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        shown = text
        if follow {
            layoutManager.ensureLayout(for: textContainer)
            scrollRangeToVisible(NSRange(location: textStorage.length, length: 0))
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let font = attributes[.font] as! UIFont
        let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let width = bounds.width - textContainerInset.left - textContainerInset.right - 2 * textContainer.lineFragmentPadding
        let height = bounds.height - textContainerInset.top - textContainerInset.bottom
        onSize?(Int(width / charWidth), max(1, Int(height / font.lineHeight)))
    }
}
