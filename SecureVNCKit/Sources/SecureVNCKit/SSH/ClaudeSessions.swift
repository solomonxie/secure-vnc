import Foundation

/// A running Claude Code session on the host, from `~/.claude/sessions/<pid>.json`.
public struct ClaudeSession: Hashable, Sendable, Identifiable {
    public var id: String
    public var pid: Int
    public var name: String
    public var cwd: String
    /// `idle`, `busy`, `shell`, or `exited` once the process is gone.
    public var status: String
    /// tmux pane id (`%12`) the session runs in; nil when it isn't under tmux.
    public var pane: String?
    public var transcript: String?
    public var updatedAt: Date
    var registry: String

    public var busy: Bool { status == "busy" || status == "shell" }
    public var exited: Bool { status == "exited" }
}

public struct ClaudeUpdate: Sendable {
    public var text: String
    public var offset: Int
    public var status: String
}

/// Claude Code sessions without touching their screen: the session registry says which are
/// alive, the `.jsonl` transcript is the output, and keystrokes go to the pane via tmux.
public struct ClaudeSessions: Sendable {
    let tunnel: SSHTunnel
    let panes: RemotePanes
    /// Bytes of transcript shown on first attach.
    public static let initialWindow = 300_000

    public init(tunnel: SSHTunnel) {
        self.tunnel = tunnel
        panes = RemotePanes(tunnel: tunnel)
    }

    public func list() async throws -> [ClaudeSession] {
        let out = try await run(#"""
        for f in "$HOME"/.claude/sessions/*.json; do
          [ -f "$f" ] || continue
          pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f" | head -1)
          [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
          sid=$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' "$f" | head -1)
          t=$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
          printf '%s\t%s\t' "$f" "$t"; cat "$f"; echo
        done
        """#)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let json = Self.json(String(parts[2])),
                  let id = json["sessionId"] as? String, let pid = json["pid"] as? Int else { return nil }
            let tmux = json["tmux"] as? String ?? ""
            let pane = tmux.split(separator: ".").last.map(String.init).flatMap { $0.hasPrefix("%") ? $0 : nil }
            return ClaudeSession(
                id: id, pid: pid, name: json["name"] as? String ?? id, cwd: json["cwd"] as? String ?? "",
                status: json["status"] as? String ?? "idle", pane: pane,
                transcript: parts[1].isEmpty ? nil : String(parts[1]),
                updatedAt: Date(timeIntervalSince1970: ((json["updatedAt"] as? Double) ?? 0) / 1000),
                registry: String(parts[0]))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Transcript past `offset` rendered as text, with the session's current status.
    /// A negative offset starts from the last `initialWindow` bytes.
    public func poll(_ session: ClaudeSession, offset: Int) async throws -> ClaudeUpdate {
        let out = try await run(#"""
        t=$1; o=$2; s=$3; w=$4
        st=$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$s" 2>/dev/null | head -1)
        sz=$(wc -c < "$t" 2>/dev/null | tr -d ' '); [ -n "$sz" ] || sz=0
        [ "$o" -lt 0 ] && { o=$((sz - w)); [ "$o" -lt 0 ] && o=0; }
        [ "$o" -gt "$sz" ] && o=0
        printf '%s\t%s\t%s\n' "$sz" "${st:-exited}" "$o"
        [ "$sz" -gt "$o" ] && tail -c +$((o + 1)) "$t" | head -c $((sz - o))
        exit 0
        """#, [session.transcript ?? "", String(offset), session.registry, String(Self.initialWindow)])
        guard let header = out.firstIndex(of: "\n") else { throw RemoteFileError.failed("No transcript.") }
        let fields = out[..<header].split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, let size = Int(fields[0]), let start = Int(fields[2]) else {
            throw RemoteFileError.failed("Bad transcript reply.")
        }
        var body = out[out.index(after: header)...]
        if start > 0, let nl = body.firstIndex(of: "\n") { body = body[body.index(after: nl)...] }
        // Keep an unfinished last line for the next poll.
        var consumed = size
        if let lastNL = body.lastIndex(of: "\n") {
            consumed -= body.distance(from: body.index(after: lastNL), to: body.endIndex)
            body = body[...lastNL]
        } else if !body.isEmpty {
            consumed = size - body.utf8.count
            body = ""
        }
        let text = body.split(separator: "\n").compactMap { ClaudeTranscript.render(String($0)) }.joined()
        return ClaudeUpdate(text: text, offset: consumed, status: String(fields[1]))
    }

    public func sendLine(_ session: ClaudeSession, _ text: String) async throws {
        guard let pane = session.pane else { throw RemoteFileError.failed("This session isn't in a tmux pane.") }
        try await panes.sendLine(pane, text)
    }

    public func sendKey(_ session: ClaudeSession, _ key: String) async throws {
        guard let pane = session.pane else { throw RemoteFileError.failed("This session isn't in a tmux pane.") }
        try await panes.sendKey(pane, key)
    }

    static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private func run(_ script: String, _ args: [String] = []) async throws -> String {
        let result = try await tunnel.exec(RemoteFiles.command(script, args))
        guard result.status == 0 else {
            throw RemoteFileError.failed(result.errorText.isEmpty ? "Command failed (\(result.status))." : result.errorText)
        }
        return result.text
    }
}

/// One transcript `.jsonl` line as a few lines of console text; nil for records not worth showing.
public enum ClaudeTranscript {
    static let resultLimit = 400

    public static func render(_ line: String) -> String? {
        guard let record = ClaudeSessions.json(line), record["isMeta"] as? Bool != true,
              record["isSidechain"] as? Bool != true, let message = record["message"] as? [String: Any] else { return nil }
        switch record["type"] as? String {
        case "user": return user(message["content"])
        case "assistant": return assistant(message["content"])
        default: return nil
        }
    }

    private static func user(_ content: Any?) -> String? {
        if let text = content as? String { return prompt(text) }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return (block["text"] as? String).flatMap(prompt)
            case "tool_result": return "  ↳ " + indent(clip(resultText(block["content"]), resultLimit), "    ") + "\n"
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    private static func prompt(_ text: String) -> String? {
        if let name = tag("command-name", in: text) {
            let args = tag("command-args", in: text) ?? ""
            return "\n❯ \(name)\(args.isEmpty ? "" : " " + args)\n"
        }
        if text.hasPrefix("<") { return nil }
        return "\n❯ \(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    private static func assistant(_ content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : "\n" + text + "\n"
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                return "⚙ \(name)\(summary(block["input"]).map { "  " + $0 } ?? "")\n"
            default: return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    private static func summary(_ input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        for key in ["description", "command", "file_path", "path", "pattern", "query", "prompt", "skill", "url"] {
            if let v = input[key] as? String, !v.isEmpty {
                return clip(v.split(separator: "\n").first.map(String.init) ?? v, 120)
            }
        }
        return nil
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }

    private static func indent(_ text: String, _ pad: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n" + pad)
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
