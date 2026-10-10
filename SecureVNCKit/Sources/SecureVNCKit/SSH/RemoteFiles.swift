import Foundation

public struct RemoteFile: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int?

    public var id: String { path }
}

public enum RemoteFileError: Error, LocalizedError {
    case failed(String)
    case binary
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .failed(let why): why
        case .binary: "Not a text file."
        case .tooLarge(let size): "Too large to open (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
        }
    }
}

/// File operations as POSIX `sh` one-liners over exec channels, so no SFTP server is needed.
public struct RemoteFiles: Sendable {
    let tunnel: SSHTunnel
    public static let maxTextSize = 1_000_000

    public init(tunnel: SSHTunnel) { self.tunnel = tunnel }

    /// Working directory of the interactive shell on this connection, else `$HOME`.
    public func shellDirectory() async throws -> String {
        try await run(#"""
        p=$$
        while [ "${p:-1}" -gt 1 ]; do
          case "$(ps -o comm= -p "$p")" in *sshd*) break;; esac
          p=$(ps -o ppid= -p "$p" | tr -d ' ')
        done
        for s in $(pgrep -P "$p"); do
          case "$(ps -o tty= -p "$s" | tr -d ' ')" in ""|"?"|"??") continue;; esac
          d=$(lsof -a -p "$s" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
          [ -n "$d" ] || d=$(readlink "/proc/$s/cwd" 2>/dev/null)
          [ -n "$d" ] && { printf '%s' "$d"; exit 0; }
        done
        printf '%s' "$HOME"
        """#)
    }

    public func list(_ dir: String) async throws -> [RemoteFile] {
        let out = try await run(#"""
        cd -- "$1" || exit 1
        for f in .[!.]* ..?* *; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          if [ -d "$f" ]; then printf 'd\t\t%s\n' "$f"
          elif [ -f "$f" ]; then printf 'f\t%s\t%s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
          else printf 'o\t\t%s\n' "$f"; fi
        done
        """#, dir)
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let name = String(parts[2])
            return RemoteFile(name: name, path: Self.join(dir, name), isDirectory: parts[0] == "d", size: Int(parts[1]))
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func readText(_ path: String) async throws -> String {
        let size = Int(try await run(#"wc -c < "$1" | tr -d ' '"#, path).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard size <= Self.maxTextSize else { throw RemoteFileError.tooLarge(size) }
        let result = try await tunnel.exec(Self.command(#"cat -- "$1""#, [path]))
        guard result.status == 0 else { throw RemoteFileError.failed(result.errorText) }
        guard !result.output.contains(0), let text = String(bytes: result.output, encoding: .utf8) else { throw RemoteFileError.binary }
        return text
    }

    public func writeText(_ path: String, _ text: String) async throws {
        try await run(#"cat > "$1""#, path, input: Array(text.utf8))
    }

    /// Copies or moves into `dir`, adding " copy", " copy 2"… instead of overwriting.
    public func paste(_ sources: [String], into dir: String, move: Bool) async throws {
        try await run(#"""
        mode=$1; dir=$2; shift 2
        for src in "$@"; do
          base=$(basename -- "$src"); dest="$dir/$base"
          if [ "$mode" = mv ] && [ "$(cd -- "$(dirname -- "$src")" && pwd -P)" = "$(cd -- "$dir" && pwd -P)" ]; then continue; fi
          n=1
          while [ -e "$dest" ] || [ -L "$dest" ]; do
            case "$base" in ?*.*) stem=${base%.*}; ext=.${base##*.};; *) stem=$base; ext=;; esac
            [ $n -eq 1 ] && dest="$dir/$stem copy$ext" || dest="$dir/$stem copy $n$ext"
            n=$((n + 1))
          done
          if [ "$mode" = mv ]; then mv -- "$src" "$dest" || exit 1; else cp -R -- "$src" "$dest" || exit 1; fi
        done
        """#, [move ? "mv" : "cp", dir] + sources)
    }

    public func remove(_ paths: [String]) async throws { try await run(#"rm -rf -- "$@""#, paths) }

    public func rename(_ path: String, to name: String) async throws {
        try await run(#"[ ! -e "$2" ] || { echo "$2 already exists" >&2; exit 1; }; mv -- "$1" "$2""#,
                      [path, Self.join(Self.parent(path), name)])
    }

    public func makeDirectory(_ path: String) async throws { try await run(#"mkdir -- "$1""#, path) }

    public static func join(_ dir: String, _ name: String) -> String { dir.hasSuffix("/") ? dir + name : dir + "/" + name }

    public static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    static func command(_ script: String, _ args: [String]) -> String {
        (["/bin/sh", "-c", script, "sh"] + args).map(quote).joined(separator: " ")
    }

    @discardableResult
    private func run(_ script: String, _ args: String..., input: [UInt8] = []) async throws -> String {
        try await run(script, args, input: input)
    }

    @discardableResult
    private func run(_ script: String, _ args: [String], input: [UInt8] = []) async throws -> String {
        let result = try await tunnel.exec(Self.command(script, args), input: input)
        guard result.status == 0 else {
            throw RemoteFileError.failed(result.errorText.isEmpty ? "Command failed (\(result.status))." : result.errorText)
        }
        return result.text
    }
}
