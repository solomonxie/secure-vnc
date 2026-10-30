import SafariServices
import SecureVNCKit
import SwiftUI

/// Web pages and other ports reachable from the server, opened through the SSH connection.
struct ForwardsView: View {
    let tunnel: SSHTunnel
    @ObservedObject var forwards: ForwardList
    @State private var host = "localhost"
    @State private var port = ""
    @State private var error: String?
    @State private var browsing: URL?

    private static let common: [(String, Int)] = [("Web", 80), ("Dev server", 3000), ("Alt web", 8080), ("Router", 443), ("Proxmox", 8006), ("Home Assistant", 8123), ("Plex", 32400)]

    var body: some View {
        Form {
            Section {
                TextField("Host as the server sees it", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Port", text: $port).keyboardType(.numberPad)
                Button("Open") { open(host.trimmed, Int(port.trimmed) ?? 0) }
                    .disabled(host.trimmed.isEmpty || Int(port.trimmed) == nil)
            } footer: {
                Text("Like ssh -L: listens on 127.0.0.1 of this iPhone while the connection is open, so other apps here can use the address too.")
            }
            Section("Common") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Self.common, id: \.1) { name, p in
                            Button("\(name) :\(p)") { port = String(p) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !forwards.forwards.isEmpty {
                Section("Open") {
                    ForEach(forwards.forwards) { f in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(f.targetHost):\(f.targetPort)")
                                Text(f.url?.absoluteString ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button { browsing = f.url } label: { Image(systemName: "safari") }.buttonStyle(.borderless)
                        }
                        .swipeActions { Button("Close", role: .destructive) { forwards.remove(f) } }
                        .contextMenu {
                            Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = f.url?.absoluteString }
                            Button("Close", systemImage: "xmark", role: .destructive) { forwards.remove(f) }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Open a Port There")
        .sheet(item: $browsing) { SafariView(url: $0).ignoresSafeArea() }
    }

    private func open(_ host: String, _ port: Int) {
        guard (1...65535).contains(port) else { error = "Enter a port from 1 to 65535."; return }
        if let existing = forwards.forwards.first(where: { $0.targetHost == host && $0.targetPort == port }) {
            browsing = existing.url
            return
        }
        Task {
            do {
                let f = try await tunnel.forward(to: host, port: port)
                forwards.add(f)
                error = nil
                browsing = f.url
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
