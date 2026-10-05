import Foundation
import ZIPFoundation

// Apple Books stores imported EPUBs as directory packages. Normalize a local
// copy without changing the source; reject symlinks and excessive resources.
enum EPUBArchive {
    static func copy(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        guard values.isDirectory == true else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("META-INF/container.xml").path),
              (try? String(contentsOf: source.appendingPathComponent("mimetype"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "application/epub+zip" else {
            throw NSError(domain: "Follow.EPUB", code: 1, userInfo: [NSLocalizedDescriptionKey: "This folder isn’t an EPUB book. Choose the .epub package containing mimetype and META-INF/container.xml."])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var files: [String] = []
        var total = 0
        let prefix = source.standardizedFileURL.path + "/"
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            guard values.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadCorruptFile) }
            let size = values.fileSize ?? 0
            total += size
            guard size < 40_000_000, total < 150_000_000, files.count < 20_000 else { throw CocoaError(.fileReadTooLarge) }
            files.append(String(path.dropFirst(prefix.count)))
        }
        if let enumerationError { throw enumerationError }
        let archive = try Archive(url: destination, accessMode: .create)
        do {
            try archive.addEntry(with: "mimetype", relativeTo: source, compressionMethod: .none)
            for path in files.sorted() where path != "mimetype" {
                try archive.addEntry(with: path, relativeTo: source, compressionMethod: .deflate)
            }
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}
