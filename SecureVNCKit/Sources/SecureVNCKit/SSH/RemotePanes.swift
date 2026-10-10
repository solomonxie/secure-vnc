import Foundation

public struct RemotePane: Hashable, Sendable, Identifiable {
    public var id: String
    /// `session:window.pane`
    public var target: String
    public var windowName: String
    public var command: String
    public var path: String
    public var active: Bool
}

/// One tmux pane without attaching: `capture-pane` to read it, `send-keys` to type into it.
public struct RemotePanes: Sendable {
    let tunnel: SSHTunnel
    let socket: String?

    /// `socket` is a tmux `-L` name; nil for the default server.
    public init(tunnel: SSHTunnel, socket: String? = nil) {
        self.tunnel = tunnel
        self.socket = socket
    }

    public func list() async throws -> [RemotePane] {
        // tmux turns tabs into `_` in some locales, so fields are split on a printable marker.
        let sep = "|~|"
        let format = ["#{pane_id}", "#{session_name}:#{window_index}.#{pane_index}", "#{window_name}",
                      "#{pane_current_command}", "#{pane_current_path}", "#{pane_active}#{window_active}"].joined(separator: sep)
        let out = try await tmux(["list-panes", "-a", "-F", format], noServerIsEmpty: true)
        return out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: sep)
            guard f.count == 6 else { return nil }
            return RemotePane(id: f[0], target: f[1], windowName: f[2], command: f[3], path: f[4], active: f[5] == "11")
        }
    }

    /// Pane text with its scrollback, wrapped lines joined and trailing blanks trimmed.
    public func capture(_ pane: String, history: Int = 2000) async throws -> String {
        let out = try await tmux(["capture-pane", "-p", "-J", "-S", "-\(history)", "-t", pane])
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0.reversed().drop(while: { $0 == " " }).reversed())
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Types `text` literally, then Enter.
    public func sendLine(_ pane: String, _ text: String) async throws {
        if !text.isEmpty { _ = try await tmux(["send-keys", "-t", pane, "-l", "--", text]) }
        _ = try await tmux(["send-keys", "-t", pane, "Enter"])
    }

    /// A tmux key name such as `C-c`.
    public func sendKey(_ pane: String, _ key: String) async throws {
        _ = try await tmux(["send-keys", "-t", pane, key])
    }

    public func currentPath(_ pane: String) async throws -> String {
        try await tmux(["display-message", "-p", "-t", pane, "#{pane_current_path}"]).trimmingCharacters(in: .newlines)
    }

    private func tmux(_ args: [String], noServerIsEmpty: Bool = false) async throws -> String {
        let script = #"""
        PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/snap/bin"
        command -v tmux >/dev/null || { echo "tmux isn't installed on this host" >&2; exit 127; }
        exec tmux -u "$@"
        """#
        let result = try await tunnel.exec(RemoteFiles.command(script, (socket.map { ["-L", $0] } ?? []) + args))
        if result.status != 0 {
            if noServerIsEmpty, result.errorText.contains("no server running") || result.errorText.contains("error connecting") { return "" }
            throw RemoteFileError.failed(result.errorText.isEmpty ? "tmux failed (\(result.status))." : result.errorText)
        }
        return result.text
    }
}
