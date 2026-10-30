import SecureVNCKit
import SwiftUI

struct ProcessesView: View {
    let system: RemoteSystem
    @State private var processes: [RemoteProcess] = []
    @State private var error: String?
    @State private var sort = Sort.cpu
    @State private var search = ""
    @State private var pendingKill: RemoteProcess?

    enum Sort: String, CaseIterable { case cpu = "CPU", memory = "Memory", name = "Name" }

    private var shown: [RemoteProcess] {
        let list = search.isEmpty ? processes : processes.filter {
            $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search || $0.user == search
        }
        return switch sort {
        case .cpu: list.sorted { $0.cpu > $1.cpu }
        case .memory: list.sorted { $0.rssKB > $1.rssKB }
        case .name: list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(shown.prefix(200)) { p in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).lineLimit(1)
                        Text("\(p.pid) · \(p.user)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f%%", p.cpu)).monospacedDigit()
                        Text(Format.bytes(p.rssKB * 1024)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Quit", role: .destructive) { pendingKill = p }
                }
                .contextMenu {
                    Button("Quit", systemImage: "xmark.circle") { kill(p, force: false) }
                    Button("Force Quit", systemImage: "bolt.circle", role: .destructive) { kill(p, force: true) }
                    Button("Copy PID", systemImage: "doc.on.doc") { UIPasteboard.general.string = String(p.pid) }
                }
            }
        }
        .navigationTitle("Processes")
        .searchable(text: $search, prompt: "Name, PID or user")
        .toolbar {
            Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.menu)
        }
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Quit \(pendingKill?.name ?? "")?", isPresented: .init(
            get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }), titleVisibility: .visible
        ) {
            if let p = pendingKill {
                Button("Quit (TERM)") { kill(p, force: false) }
                Button("Force Quit (KILL)", role: .destructive) { kill(p, force: true) }
            }
        }
    }

    private func load() async {
        do {
            processes = try await system.processes()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func kill(_ p: RemoteProcess, force: Bool) {
        Task {
            do {
                try await system.kill(p.pid, force: force)
                try? await Task.sleep(for: .milliseconds(300))
                await load()
            } catch {
                self.error = "\(p.name): \(error.localizedDescription)"
            }
        }
    }
}
