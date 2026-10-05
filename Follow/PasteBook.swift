import SwiftUI
import UniformTypeIdentifiers

struct PasteBookButton: View {
    let receive: (URL) async -> Void
    let reportError: (String) -> Void
    private var epub: UTType { UTType(filenameExtension: "epub") ?? UTType(importedAs: "org.idpf.epub-container") }
    var body: some View {
        PasteButton(supportedContentTypes: [epub, .fileURL]) { providers in
            Task {
                for provider in providers {
                    do {
                        let url = try await Self.stage(provider, epub: epub.identifier)
                        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                        await receive(url)
                    } catch { reportError("Couldn’t paste this book. Copy an EPUB file from Files and try again. \(error.localizedDescription)") }
                }
            }
        }.labelStyle(.titleAndIcon).accessibilityLabel("Paste Book")
    }
    static func stage(_ provider: NSItemProvider, epub: String) async throws -> URL {
        if provider.hasItemConformingToTypeIdentifier(epub) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: epub) { url, error in
                    do {
                        if let url { continuation.resume(returning: try copy(url)); return }
                        provider.loadDataRepresentation(forTypeIdentifier: epub) { data, dataError in
                            do {
                                guard let data else { throw dataError ?? error ?? CocoaError(.fileReadCorruptFile) }
                                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                                let destination = folder.appendingPathComponent("Pasted Book.epub")
                                try data.write(to: destination, options: .atomic)
                                continuation.resume(returning: destination)
                            } catch { continuation.resume(throwing: error) }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                do {
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else { url = nil }
                    guard let url, url.isFileURL, url.pathExtension.lowercased() == "epub" else {
                        throw error ?? CocoaError(.fileReadUnsupportedScheme)
                    }
                    continuation.resume(returning: try copy(url))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func copy(_ url: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("Pasted Book.epub")
        do { try EPUBArchive.copy(from: url, to: destination); return destination }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
