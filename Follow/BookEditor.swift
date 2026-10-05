import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct BookEditorView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var narrator: Narrator
    @Environment(\.dismiss) private var dismiss
    private let bookID: UUID
    @State private var title: String
    @State private var author: String
    @State private var cover: Data?
    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var loading = false
    @State private var error: String?
    init(book: Book) {
        bookID = book.id
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _cover = State(initialValue: book.cover)
    }
    var body: some View {
        Form {
            Section("Cover") {
                HStack {
                    Spacer()
                    if let cover, let image = UIImage(data: cover) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "book.closed").font(.system(size: 70)).frame(height: 200).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose from Photos", systemImage: "photo") }
                Button("Choose from Files", systemImage: "folder") { choosingFile = true }
                if cover != nil { Button("Remove Cover", role: .destructive) { cover = nil } }
                if loading { ProgressView("Preparing cover…") }
            }
            Section("Book Details") {
                TextField("Title", text: $title, axis: .vertical)
                TextField("Author", text: $author)
            }
            Section { Text("Changes are saved in Follow. Your reading position, bookmarks, and highlights stay with the book.").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Edit Book").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        let updated = try library.editBook(bookID, title: title, author: author, cover: cover)
                        narrator.refreshMetadata(updated)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(loading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task(id: photo) {
            guard let photo else { return }
            loading = true
            defer { loading = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                cover = try Self.prepareCover(data)
            } catch is CancellationError {} catch { self.error = "This image could not be opened. \(error.localizedDescription)" }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                cover = try Self.prepareCover(Data(contentsOf: url))
            } catch { self.error = "This image could not be opened. \(error.localizedDescription)" }
        }
        .alert("Couldn’t Save Changes", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    static func prepareCover(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1400
              ] as CFDictionary), let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return jpeg
    }
}
