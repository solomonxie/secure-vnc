import QuickLookThumbnailing
import SecureVNCKit
import SwiftUI
import UniformTypeIdentifiers

/// What a file is, from its name: how it's shown and opened.
struct FileKind {
    let type: UTType?

    init(_ name: String) { type = UTType(filenameExtension: (name as NSString).pathExtension) }

    private static let previewed: [UTType] = [.image, .audiovisualContent, .pdf, .presentation, .spreadsheet, .rtf, .rtfd,
                                              .threeDContent, .epub]
        + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages"].compactMap(UTType.init)

    /// Opens in Quick Look rather than the text editor.
    var isPreviewed: Bool { type.map { t in Self.previewed.contains { t.conforms(to: $0) } } ?? false }

    var hasThumbnail: Bool { type.map { $0.conforms(to: .image) || $0.conforms(to: .movie) || $0.conforms(to: .pdf) } ?? false }

    var symbol: String {
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// A folder or file icon; a picture or video's thumbnail when it's on this device.
struct FileIcon: View {
    let file: RemoteFile
    let url: URL?
    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
                    .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: file.isDirectory ? "folder.fill" : FileKind(file.name).symbol)
                    .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
            }
        }
        .frame(width: 32)
        .task(id: url) {
            guard let url, !file.isDirectory, FileKind(file.name).hasThumbnail else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: scale,
                                                       representationTypes: .thumbnail)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
