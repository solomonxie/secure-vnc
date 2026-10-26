import Foundation
import SecureVNCKit

/// Folders and drives linked from the Files app, mounted at `/<name>` next to the app's own folders.
/// Access is kept through bookmarks, so a USB drive comes back when it's plugged in again.
@MainActor
final class LocalPlaces: ObservableObject {
    struct Linked: Codable, Identifiable {
        var name: String
        var bookmark: Data
        var id: String { name }
    }

    @Published private(set) var linked: [Linked] = []
    /// Linked but not reachable now: a drive that's unplugged, a folder that was deleted.
    @Published private(set) var missing: Set<String> = []
    let mounts = LocalMounts(LocalFiles.standardPlaces)
    var files: LocalFiles { LocalFiles(mounts: mounts) }
    private var accessing: [String: URL] = [:]
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("places.json")

    init() {
        linked = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Linked].self, from: $0) } ?? []
        refresh()
    }

    func isLinked(_ name: String) -> Bool { linked.contains { $0.name == name } }

    func refresh() {
        var all = LocalFiles.standardPlaces
        var missing = Set<String>()
        for (i, place) in linked.enumerated() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: place.bookmark, bookmarkDataIsStale: &stale) else {
                missing.insert(place.name)
                continue
            }
            if accessing[place.name] != url {
                accessing[place.name]?.stopAccessingSecurityScopedResource()
                _ = url.startAccessingSecurityScopedResource()
                accessing[place.name] = url
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.insert(place.name)
                continue
            }
            if stale, let fresh = try? url.bookmarkData() { linked[i].bookmark = fresh }
            all[place.name] = url
        }
        mounts.all = all
        self.missing = missing
        persist()
    }

    /// A folder picked in the Files app; its name, made unique.
    @discardableResult
    func link(_ url: URL) throws -> String {
        guard url.startAccessingSecurityScopedResource() else { throw Failure("No access to \(url.lastPathComponent).") }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData()
        let base = url.lastPathComponent.isEmpty ? "Drive" : url.lastPathComponent
        var name = base, n = 2
        while mounts.all[name] != nil || isLinked(name) {
            name = "\(base) \(n)"
            n += 1
        }
        linked.append(Linked(name: name, bookmark: bookmark))
        refresh()
        return name
    }

    func unlink(_ name: String) {
        linked.removeAll { $0.name == name }
        accessing.removeValue(forKey: name)?.stopAccessingSecurityScopedResource()
        refresh()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(linked) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
