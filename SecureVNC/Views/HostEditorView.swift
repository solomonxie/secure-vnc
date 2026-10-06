import SecureVNCKit
import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var sshPort = ""
    @State private var vncPort = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var keyPickerOpen = false
    @State private var creatingKey = false
    @State private var showVNCInfo = false
    private let isNew: Bool

    init(host: Host) {
        _host = State(initialValue: host)
        isNew = host.name.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    field("Studio Mac", text: $host.name)
                }
                Section("SSH") {
                    field("192.168.1.20 or mac.local", text: $host.sshHost)
                    field("Port", text: $sshPort).keyboardType(.numberPad)
                    field("User", text: $host.username)
                    keyRow
                    if keyPickerOpen { keyOptions }
                }
                Section {
                    field("localhost", text: $host.vncHost)
                    field("5900", text: $vncPort).keyboardType(.numberPad)
                    Picker("Auth", selection: $host.auth) {
                        ForEach(VNCAuthKind.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                    if host.auth == .macOS {
                        field(host.username.isEmpty ? "macOS user" : host.username, text: $host.macUser)
                    }
                    if host.auth != .none { secretField }
                } header: {
                    HStack(spacing: 4) {
                        Text("VNC")
                        Button { showVNCInfo = true } label: { Image(systemName: "info.circle") }
                            .popover(isPresented: $showVNCInfo) {
                                Text("Address as seen from the SSH server, like `ssh -L 5901:localhost:5900`. VNC traffic never leaves the SSH connection.\n\nmacOS Screen Sharing: choose macOS and enter that Mac's account login.")
                                    .font(.callout).padding().frame(width: 300)
                                    .presentationCompactAdaptation(.popover)
                            }
                    }
                }
            }
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!draft.isComplete)
                }
            }
            .sheet(isPresented: $creatingKey) {
                NewKeyView { host.keyID = $0.id; keyPickerOpen = false }
            }
            .onAppear {
                sshPort = String(host.sshPort)
                vncPort = String(host.vncPort)
                if !isNew { password = store.password(for: host.id) }
                if host.keyID == nil { host.keyID = store.keys.first?.id }
            }
        }
    }

    private var draft: Host {
        var h = host
        h.sshPort = Int(sshPort) ?? 22
        h.vncPort = Int(vncPort) ?? 5900
        return h
    }

    private var keyRow: some View {
        Button { withAnimation { keyPickerOpen.toggle() } } label: {
            HStack {
                Text("Key").foregroundStyle(.primary)
                Spacer()
                Text(store.key(host.keyID)?.name ?? "None").foregroundStyle(.secondary)
                Image(systemName: keyPickerOpen ? "chevron.down" : "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var keyOptions: some View {
        ForEach(store.keys) { key in
            Button {
                host.keyID = key.id
                withAnimation { keyPickerOpen = false }
            } label: {
                HStack {
                    Text(key.name).foregroundStyle(.primary)
                    Text(key.kind.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if key.id == host.keyID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
        Button("New key…") { creatingKey = true }
    }

    private var secretField: some View {
        HStack {
            Group {
                if showPassword { field("Password", text: $password) } else { SecureField("Password", text: $password) }
            }
            Button { showPassword.toggle() } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    private func save() {
        var h = draft
        h.name = h.name.trimmed
        h.sshHost = h.sshHost.trimmed
        h.username = h.username.trimmed
        h.vncHost = h.vncHost.trimmed
        h.macUser = h.macUser.trimmed
        if let old = store.host(h.id), old.sshHost != h.sshHost || old.sshPort != h.sshPort {
            h.hostKeyFingerprint = nil
        }
        store.save(h, password: h.auth == .none ? "" : password)
        dismiss()
    }
}
