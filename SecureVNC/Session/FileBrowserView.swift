import SecureVNCKit
import SwiftUI
import UIKit

struct FileClipboard {
    var paths: [String]
    var move: Bool
}

@MainActor
final class FileBrowser: ObservableObject {
    let files: RemoteFiles
    let terminal: Terminal
    @Published var root: String?
    @Published var stack = NavigationPath()
    @Published private(set) var closed = false
    /// Bumped after a change so every open folder reloads.
    @Published private(set) var revision = 0
    @Published var error: String?

    init(files: RemoteFiles, terminal: Terminal) {
        self.files = files
        self.terminal = terminal
    }

    func start() async {
        guard root == nil else { return }
        root = await terminal.currentDirectory()
    }

    func jump(to dir: String) {
        root = dir
        stack = NavigationPath()
    }

    func openInTerminal(_ dir: String) {
        terminal.send("cd " + RemoteFiles.quote(dir))
        closed = true
    }

    func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch { self.error = error.localizedDescription }
        revision += 1
    }

    func paste(into dir: String) async {
        guard let clip = terminal.clipboard else { return }
        await perform { try await files.paste(clip.paths, into: dir, move: clip.move) }
        if clip.move { terminal.clipboard = nil }
    }
}

struct FileBrowserView: View {
    @StateObject private var browser: FileBrowser
    @Environment(\.dismiss) private var dismiss

    init(files: RemoteFiles, terminal: Terminal) {
        _browser = StateObject(wrappedValue: FileBrowser(files: files, terminal: terminal))
    }

    var body: some View {
        NavigationStack(path: $browser.stack) {
            Group {
                if let root = browser.root {
                    DirectoryView(dir: root, isRoot: true)
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: String.self) { DirectoryView(dir: $0, isRoot: false) }
            .navigationDestination(for: RemoteFile.self) { FileEditorView(file: $0) }
        }
        .environmentObject(browser)
        .environmentObject(browser.terminal)
        .task { await browser.start() }
        .onChange(of: browser.closed) { dismiss() }
        .alert("Couldn't do that", isPresented: .init(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.error ?? "")
        }
    }
}

struct DirectoryView: View {
    let dir: String
    let isRoot: Bool
    @EnvironmentObject private var browser: FileBrowser
    @EnvironmentObject private var terminal: Terminal
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RemoteFile]?
    @State private var loadError: String?
    @State private var selection = Set<String>()
    @State private var editMode = EditMode.inactive
    @State private var renaming: RemoteFile?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var pendingDelete: [String] = []

    private var title: String { dir == "/" ? "/" : (dir as NSString).lastPathComponent }

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { ancestors }
            .toolbar { toolbar }
            .environment(\.editMode, $editMode)
            .task(id: "\(dir)#\(browser.revision)") { await load() }
            .refreshable { await load() }
            .alert("Rename", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                nameField
                Button("Rename") {
                    if let file = renaming { act { try await browser.files.rename(file.path, to: newName) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("New Folder", isPresented: $creatingFolder) {
                nameField
                Button("Create") { act { try await browser.files.makeDirectory(RemoteFiles.join(dir, newName)) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(deleteTitle, isPresented: .init(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let paths = pendingDelete
                    act { try await browser.files.remove(paths) }
                    selection = []
                    editMode = .inactive
                }
            } message: {
                Text("This can't be undone.")
            }
    }

    @ViewBuilder private var content: some View {
        if let items {
            List(selection: editMode.isEditing ? $selection : nil) {
                ForEach(items) { row($0) }
            }
            .overlay {
                if items.isEmpty { ContentUnavailableView("Empty folder", systemImage: "folder") }
            }
        } else if let loadError {
            ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else {
            ProgressView()
        }
    }

    private func row(_ file: RemoteFile) -> some View {
        link(file) {
            HStack(spacing: 12) {
                Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                    .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let size = file.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tag(file.path)
        .swipeActions {
            Button("Delete", role: .destructive) { pendingDelete = [file.path] }
            Button("Rename") { startRename(file) }.tint(.gray)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { terminal.clipboard = FileClipboard(paths: [file.path], move: false) }
            Button("Cut", systemImage: "scissors") { terminal.clipboard = FileClipboard(paths: [file.path], move: true) }
            Button("Rename", systemImage: "pencil") { startRename(file) }
            Button("Copy Path", systemImage: "link") { UIPasteboard.general.string = file.path }
            if file.isDirectory {
                Button("Open in Terminal", systemImage: "terminal") { openInTerminal(file.path) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = [file.path] }
        }
    }

    @ViewBuilder private func link(_ file: RemoteFile, @ViewBuilder label: () -> some View) -> some View {
        if file.isDirectory { NavigationLink(value: file.path, label: label) } else { NavigationLink(value: file, label: label) }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if editMode.isEditing {
                Button("Done") { editMode = .inactive; selection = [] }
            } else {
                Menu {
                    Button("Select", systemImage: "checkmark.circle") { editMode = .active }
                    if let clip = terminal.clipboard {
                        Button("Paste \(clip.paths.count == 1 ? "1 item" : "\(clip.paths.count) items")",
                               systemImage: "doc.on.clipboard") { Task { await browser.paste(into: dir) } }
                    }
                    Button("New Folder", systemImage: "folder.badge.plus") { newName = ""; creatingFolder = true }
                    Button("Open in Terminal", systemImage: "terminal") { openInTerminal(dir) }
                    Button("Copy Path", systemImage: "link") { UIPasteboard.general.string = dir }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        if editMode.isEditing {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Copy") { clip(move: false) }.disabled(selection.isEmpty)
                Spacer()
                Button("Cut") { clip(move: true) }.disabled(selection.isEmpty)
                Spacer()
                Button("Delete", role: .destructive) { pendingDelete = Array(selection) }.disabled(selection.isEmpty)
            }
        }
    }

    @ViewBuilder private var ancestors: some View {
        let parts = dir.split(separator: "/").map(String.init)
        ForEach((0..<parts.count).reversed(), id: \.self) { i in
            let path = "/" + parts[..<i].joined(separator: "/")
            Button(i == 0 ? "/" : parts[i - 1], systemImage: "folder") { browser.jump(to: path) }
        }
    }

    private var nameField: some View {
        TextField("Name", text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete \((pendingDelete[0] as NSString).lastPathComponent)?" : "Delete \(pendingDelete.count) items?"
    }

    private func load() async {
        do {
            items = try await browser.files.list(dir)
            loadError = nil
        } catch {
            if items == nil { loadError = error.localizedDescription }
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        Task { await browser.perform(action) }
    }

    private func startRename(_ file: RemoteFile) {
        newName = file.name
        renaming = file
    }

    private func clip(move: Bool) {
        terminal.clipboard = FileClipboard(paths: Array(selection), move: move)
        selection = []
        editMode = .inactive
    }

    private func openInTerminal(_ path: String) { browser.openInTerminal(path) }
}

struct FileEditorView: View {
    let file: RemoteFile
    @EnvironmentObject private var browser: FileBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var original: String?
    @State private var text = ""
    @State private var loadError: String?
    @State private var saving = false
    @State private var confirmDiscard = false
    /// Opens read-only; Edit unlocks typing so a stray touch can't change a file.
    @State private var editing = false

    private var dirty: Bool { original != nil && text != original }

    var body: some View {
        Group {
            if original != nil {
                CodeEditor(text: $text, editable: editing)
            } else if let loadError {
                ContentUnavailableView("Can't open", systemImage: "doc.questionmark", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmDiscard = true } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else if editing {
                    Button(dirty ? "Save" : "Done") { dirty ? save() : (editing = false) }
                } else if original != nil {
                    Button("Edit") { editing = true }
                }
            }
        }
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                text = original ?? text
                editing = false
            }
        }
        .task {
            do {
                text = try await browser.files.readText(file.path)
                original = text
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func save() {
        saving = true
        let content = text
        Task {
            await browser.perform { try await browser.files.writeText(file.path, content) }
            if browser.error == nil {
                original = content
                editing = false
            }
            saving = false
        }
    }
}

/// UITextView without smart quotes, dashes or autocorrect, which would corrupt code and config files.
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    var editable = true

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        view.text = text
        view.isEditable = editable
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        if view.isEditable != editable {
            view.isEditable = editable
            if editable { view.becomeFirstResponder() } else { view.resignFirstResponder() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ view: UITextView) { text.wrappedValue = view.text }
    }
}
