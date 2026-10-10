import SwiftUI

struct HostsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var editing: Host?
    @State private var connecting: Host?
    @State private var pendingDelete: Host?

    var body: some View {
        NavigationStack {
            Group {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No hosts yet", systemImage: "desktopcomputer")
                    } description: {
                        Text("Add your Mac to connect over SSH.")
                    } actions: {
                        Button("Add host") { editing = Host() }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List(store.hosts) { host in
                        Button { connecting = host } label: { row(host) }
                            .swipeActions {
                                Button("Delete", role: .destructive) { pendingDelete = host }
                                Button("Edit") { editing = host }.tint(.gray)
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editing = host }
                                Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = host }
                            }
                    }
                }
            }
            .navigationTitle("Secure VNC")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { KeysView() } label: { Image(systemName: "key").accessibilityLabel("Keys") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = Host() } label: { Image(systemName: "plus").accessibilityLabel("Add host") }
                }
            }
            .sheet(item: $editing) { HostEditorView(host: $0) }
            .fullScreenCover(item: $connecting) { SessionView(host: $0) }
            .alert("Delete \(pendingDelete?.name ?? "")?", isPresented: .init(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
            ) {
                Button("Delete", role: .destructive) { if let h = pendingDelete { store.delete(h) } }
            } message: {
                Text("Its saved password and trusted host key are removed too.")
            }
        }
    }

    private func row(_ host: Host) -> some View {
        HStack(spacing: 12) {
            Image(systemName: host.type.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(host.type == .vnc ? Color.white : Color.green)
                .frame(width: 40, height: 40)
                .background(host.type == .vnc ? Color.accentColor : Color(white: 0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).font(.headline).foregroundStyle(.primary)
                Text(host.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
