import Foundation

/// Top-level folders of the device's file tree, by name: the app's own folders and any the user linked.
public final class LocalMounts: @unchecked Sendable {
    private let lock = NSLock()
    private var places: [String: URL]

    public init(_ places: [String: URL] = [:]) { self.places = places }

    public var all: [String: URL] {
        get { lock.withLock { places } }
        set { lock.withLock { places = newValue } }
    }
}

/// This device's files under one tree: `/Documents/…`, `/tmp/…`, `/<linked folder>/…`.
public struct LocalFiles: FileSystem {
    public let mounts: LocalMounts

    public init(mounts: LocalMounts) { self.mounts = mounts }

    /// The app's own folders, always mounted.
    public static var standardPlaces: [String: URL] {
        ["Documents": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
         "tmp": FileManager.default.temporaryDirectory]
    }

    /// `/a/./b/../c` as `/a/c`, never above `/`.
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    public func url(_ path: String) throws -> URL {
        let parts = Self.normalize(path).split(separator: "/", maxSplits: 1).map(String.init)
        guard let name = parts.first else { throw LocalFileError.isRoot }
        guard let base = mounts.all[name] else { throw LocalFileError.noSuchFile(Self.normalize(path)) }
        return parts.count > 1 ? base.appendingPathComponent(parts[1]) : base
    }

    public func isMount(_ path: String) -> Bool {
        let parts = Self.normalize(path).split(separator: "/")
        return parts.count == 1 && mounts.all[String(parts[0])] != nil
    }

    public func list(_ dir: String) async throws -> [RemoteFile] {
        let dir = Self.normalize(dir)
        if dir == "/" {
            return mounts.all.keys.sorted { $0.lowercased() < $1.lowercased() }
                .map { RemoteFile(name: $0, path: "/" + $0, isDirectory: true, size: nil) }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: try url(dir).path)
        return names.map { name in
            let path = RemoteFiles.join(dir, name)
            let info = try? info(path)
            return RemoteFile(name: name, path: path, isDirectory: info?.isDirectory ?? false, size: info?.isDirectory == false ? info?.size : nil)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public struct Info: Sendable {
        public var isDirectory: Bool
        public var isLink: Bool
        public var size: Int
        public var modified: Date?
        public var permissions: Int
    }

    /// Follows a symlink for its type and size, as `ls` does.
    public func info(_ path: String) throws -> Info {
        if isMount(path) || Self.normalize(path) == "/" {
            return Info(isDirectory: true, isLink: false, size: 0, modified: nil, permissions: 0o755)
        }
        let p = try url(path).path
        let link = try FileManager.default.attributesOfItem(atPath: p)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: (p as NSString).resolvingSymlinksInPath)) ?? link
        return Info(isDirectory: attrs[.type] as? FileAttributeType == .typeDirectory,
                    isLink: link[.type] as? FileAttributeType == .typeSymbolicLink,
                    size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                    modified: attrs[.modificationDate] as? Date,
                    permissions: (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0)
    }

    public func exists(_ path: String) -> Bool {
        Self.normalize(path) == "/" || ((try? url(path)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }

    public func readData(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    public func readText(_ path: String) async throws -> String {
        let size = try info(path).size
        guard size <= RemoteFiles.maxTextSize else { throw RemoteFileError.tooLarge(size) }
        let data = try readData(path)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw RemoteFileError.binary }
        return text
    }

    public func writeText(_ path: String, _ text: String) async throws {
        try writeData(path, Data(text.utf8))
    }

    public func writeData(_ path: String, _ data: Data, append: Bool = false) throws {
        try writable(path)
        let target = try url(path)
        if append, let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: target)
        }
    }

    /// Copies or moves into `dir`, adding " copy", " copy 2"… instead of overwriting.
    public func paste(_ sources: [String], into dir: String, move: Bool) async throws {
        for src in sources {
            let base = (src as NSString).lastPathComponent
            if move, Self.normalize(RemoteFiles.parent(src)) == Self.normalize(dir) { continue }
            var dest = RemoteFiles.join(dir, base)
            var n = 1
            let dot = base.lastIndex(of: ".").flatMap { $0 > base.startIndex ? $0 : nil }
            let stem = dot.map { String(base[..<$0]) } ?? base, ext = dot.map { String(base[$0...]) } ?? ""
            while exists(dest) {
                dest = RemoteFiles.join(dir, stem + (n == 1 ? " copy" : " copy \(n)") + ext)
                n += 1
            }
            try copy(src, to: dest, move: move)
        }
    }

    /// Exactly to `dest`, which must not exist.
    public func copy(_ src: String, to dest: String, move: Bool) throws {
        if move { try writable(src) }
        try writable(dest)
        let from = try url(src), to = try url(dest)
        let target = Self.normalize(dest), source = Self.normalize(src)
        guard target != source, !target.hasPrefix(source + "/") else { throw LocalFileError.intoItself(src) }
        if move { try FileManager.default.moveItem(at: from, to: to) } else { try FileManager.default.copyItem(at: from, to: to) }
    }

    public func remove(_ paths: [String]) async throws {
        for path in paths { try removeItem(path) }
    }

    public func removeItem(_ path: String) throws {
        try writable(path)
        try FileManager.default.removeItem(at: url(path))
    }

    public func rename(_ path: String, to name: String) async throws {
        let dest = RemoteFiles.join(RemoteFiles.parent(path), name)
        guard !exists(dest) else { throw RemoteFileError.failed("\(name) already exists") }
        try copy(path, to: dest, move: true)
    }

    public func makeDirectory(_ path: String) async throws { try makeDirectory(path, parents: false) }

    public func makeDirectory(_ path: String, parents: Bool) throws {
        if parents && isMount(path) && exists(path) { return }
        try writable(path)
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: parents)
    }

    public func localURL(_ path: String) -> URL? { try? url(path) }

    public func download(_ path: String) async throws -> URL { try url(path) }

    /// The top-level folders themselves can't be changed, only what's inside them.
    private func writable(_ path: String) throws {
        let path = Self.normalize(path)
        if path == "/" || path.split(separator: "/").count == 1 { throw LocalFileError.readOnly(path) }
    }
}

public enum LocalFileError: Error, LocalizedError {
    case isRoot
    case noSuchFile(String)
    case readOnly(String)
    case intoItself(String)

    public var errorDescription: String? {
        switch self {
        case .isRoot: "/ only holds the top-level folders."
        case .noSuchFile: "No such file or directory"
        case .readOnly(let path): "\(path) can't be changed; work inside it."
        case .intoItself(let path): "Can't copy \(path) into itself."
        }
    }
}
