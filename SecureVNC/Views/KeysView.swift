import SecureVNCKit
import SwiftUI

struct KeysView: View {
    @EnvironmentObject private var store: AppStore
    @State private var creating = false

    var body: some View {
        Group {
            if store.keys.isEmpty {
                ContentUnavailableView {
                    Label("No keys yet", systemImage: "key")
                } description: {
                    Text("Keys are made on this iPhone and never leave it.")
                } actions: {
                    Button("Generate key") { creating = true }.buttonStyle(.borderedProminent)
                }
            } else {
                List(store.keys) { key in
                    NavigationLink { KeyDetailView(key: key) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(key.name).font(.headline)
                                Spacer()
                                Text(key.kind.label).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                                if key.requiresUserPresence {
                                    Spacer()
                                    Image(systemName: "faceid").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Keys")
        .toolbar {
            Button { creating = true } label: { Image(systemName: "plus").accessibilityLabel("Generate key") }
        }
        .sheet(isPresented: $creating) { NewKeyView() }
    }
}

struct NewKeyView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onCreate: ((SSHKeyInfo) -> Void)?
    @State private var name = UIDevice.current.name
    @State private var kind: SSHKeyKind = SSHKeyStore.secureEnclaveAvailable ? .secureEnclaveP256 : .ed25519
    @State private var requireFaceID = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name).autocorrectionDisabled()
                    Picker("Type", selection: $kind) {
                        ForEach(SSHKeyKind.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!SSHKeyStore.secureEnclaveAvailable)
                    Toggle("Require Face ID", isOn: $requireFaceID)
                } footer: {
                    Text(kind == .secureEnclaveP256
                         ? "ECDSA P-256 inside the Secure Enclave — the private key can never be exported."
                         : "Ed25519, stored in this iPhone's Keychain only.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("New Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        do {
                            let info = try store.generateKey(name: name.trimmed, kind: kind, requireUserPresence: requireFaceID)
                            onCreate?(info)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmed.isEmpty)
                }
            }
        }
    }
}

struct KeyDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let key: SSHKeyInfo
    @State private var confirmDelete = false
    @State private var copied: String?

    var body: some View {
        List {
            Section {
                Text(key.publicKey).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(6)
                Button("Copy public key", systemImage: "doc.on.doc") { copy(key.publicKey, "Public key") }
                ShareLink(item: key.publicKey) { Label("Share…", systemImage: "square.and.arrow.up") }
                Button("Copy install command", systemImage: "terminal") { copy(key.installCommand, "Install command") }
            } footer: {
                Text("Run the install command on the server, or add the public key to ~/.ssh/authorized_keys.")
            }
            Section {
                LabeledContent("Type", value: key.kind.label)
                LabeledContent("Face ID", value: key.requiresUserPresence ? "Required" : "Off")
                LabeledContent("Fingerprint") {
                    Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Created", value: key.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Button("Delete key", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(key.name)
        .overlay(alignment: .bottom) {
            if let copied {
                Text("\(copied) copied").font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert("Delete \(key.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                store.delete(key)
                dismiss()
            }
        } message: {
            let users = store.hosts.filter { $0.keyID == key.id }.map(\.name)
            Text(users.isEmpty ? "This can't be undone." : "\(users.joined(separator: ", ")) can't connect without it. This can't be undone.")
        }
    }

    private func copy(_ text: String, _ what: String) {
        UIPasteboard.general.string = text
        withAnimation { copied = what }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = nil }
        }
    }
}
