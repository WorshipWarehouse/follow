import Foundation
import Combine
import NaturalLanguage

struct Location: Codable, Equatable {
    var chapter: Int = 0
    var offset: Int = 0 // UTF-16: shared by TextKit, NSRange and speech callbacks.
}
struct StyleSpan: Codable {
    var offset: Int
    var length: Int
    var bold: Bool
    var italic: Bool
    var heading: Int
    var alignment: String?
    var indent: Double
    var scale: Double
    var block: Bool
    var quote: Bool
}
struct BookImage: Codable { var offset: Int; var data: Data; var alt: String }
struct Chapter: Codable, Identifiable {
    var id: String
    var title: String
    var text: String
    var anchors: [String: Int]
    var spans: [StyleSpan]? = nil
    var images: [BookImage]? = nil
    var length: Int { (text as NSString).length }
    func nextSpokenOffset(_ offset: Int) -> Int {
        let ns = text as NSString
        var cursor = max(0, offset)
        while cursor < ns.length {
            let unit = ns.character(at: cursor)
            if unit != 0xFFFC && unit != 0x00AD, let scalar = UnicodeScalar(unit), !CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            // Surrogate pairs are valid text; the high surrogate starts a word/emoji.
            if (0xD800...0xDBFF).contains(unit) { break }
            cursor += 1
        }
        return cursor
    }
    func sentence(at offset: Int) -> NSRange {
        let ns = text as NSString
        let cursor = nextSpokenOffset(offset)
        guard cursor < ns.length else { return NSRange(location: ns.length, length: 0) }
        let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
        let value = ns.substring(with: paragraph)
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = value
        var result = NSRange(location: cursor, length: NSMaxRange(paragraph) - cursor)
        tokenizer.enumerateTokens(in: value.startIndex..<value.endIndex) { range, _ in
            let r = NSRange(range, in: value)
            if paragraph.location + NSMaxRange(r) > cursor {
                result = NSRange(location: paragraph.location + r.location, length: r.length)
                return false
            }
            return true
        }
        return result
    }

}
struct ContentsEntry: Codable, Identifiable {
    var id: String
    var title: String
    var location: Location
}
struct Book: Codable, Identifiable {
    var id: UUID
    var title: String
    var author: String
    var language: String
    var cover: Data?
    var chapters: [Chapter]
    var contents: [ContentsEntry]
    var location = Location()
    var parserVersion: Int? = nil
    var progress: Double {
        let total = chapters.reduce(0) { $0 + $1.length }
        guard total > 0 else { return 0 }
        let previous = chapters.prefix(location.chapter).reduce(0) { $0 + $1.length }
        return min(1, Double(previous + location.offset) / Double(total))
    }
}
enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow = "Yellow", green = "Green", blue = "Blue", pink = "Pink", purple = "Purple", orange = "Orange"
    var id: String { rawValue }
}
enum HighlightMode: String, Codable, CaseIterable, Identifiable {
    case word = "Word", sentence = "Sentence"
    var id: String { rawValue }
}
enum GuideDimming: String, Codable, CaseIterable, Identifiable {
    case none = "None", low = "Low", medium = "Medium", high = "High"
    var id: String { rawValue }
    var opacity: Double { switch self { case .none: return 0; case .low: return 0.16; case .medium: return 0.34; case .high: return 0.58 } }
}
enum PageTurnStyle: String, Codable, CaseIterable, Identifiable {
    case curl = "Curl", slide = "Slide", fade = "Fade", none = "None"
    var id: String { rawValue }
}
enum ReadingPreset: String, CaseIterable, Identifiable {
    case classic = "Classic", paper = "Paper", calm = "Calm", bold = "Bold", focus = "Focus", night = "Night"
    var id: String { rawValue }
    func apply(to settings: inout ReaderSettings) {
        settings.boldText = false; settings.justified = false
        settings.characterSpacing = 0; settings.wordSpacing = 0; settings.paragraphSpacing = 12
        switch self {
        case .classic: settings.font = "Georgia"; settings.size = 21; settings.spacing = 7; settings.margin = 24; settings.theme = "Light"
        case .paper: settings.font = "Palatino"; settings.size = 22; settings.spacing = 6; settings.margin = 26; settings.theme = "Sepia"
        case .calm: settings.font = "AvenirNext-Regular"; settings.size = 23; settings.spacing = 10; settings.margin = 30; settings.theme = "Mist"; settings.paragraphSpacing = 16
        case .bold: settings.font = "Georgia"; settings.size = 23; settings.spacing = 8; settings.margin = 24; settings.theme = "Light"; settings.boldText = true
        case .focus: settings.font = "AvenirNext-Regular"; settings.size = 25; settings.spacing = 12; settings.margin = 32; settings.theme = "Sepia"; settings.characterSpacing = 0.3; settings.paragraphSpacing = 18
        case .night: settings.font = "Palatino"; settings.size = 22; settings.spacing = 8; settings.margin = 26; settings.theme = "Dusk"
        }
    }
}
struct ReaderSettings: Codable, Equatable {
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]
    var font = "Georgia"
    var size: Double = 21
    var spacing: Double = 7
    var margin: Double = 24
    var theme = "System"
    var pageTurn = PageTurnStyle.curl
    var boldText = false
    var justified = false
    var characterSpacing: Double = 0
    var wordSpacing: Double = 0
    var paragraphSpacing: Double = 12
    var speed: Double = 1
    var voice = ""
    var narrationHighlight = true
    var highlightMode = HighlightMode.sentence
    var highlightColor = HighlightColor.yellow
    var highlightOpacity: Double = 0.30
    var savedHighlightColor = HighlightColor.yellow
    var showSavedHighlights = true
    var lineGuide = false
    var guideDimming = GuideDimming.medium
    var searchWholeWords = false
    var searchCaseSensitive = false
    init() {}
    // Preserve installed users' preferences when adding new settings.
    enum CodingKeys: String, CodingKey {
        case font, size, spacing, margin, theme, pageTurn, boldText, justified, characterSpacing, wordSpacing, paragraphSpacing, speed, voice, narrationHighlight, highlightMode, highlightColor, highlightOpacity, savedHighlightColor, showSavedHighlights, lineGuide, guideDimming, searchWholeWords, searchCaseSensitive
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? font
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? spacing
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? theme
        pageTurn = try c.decodeIfPresent(PageTurnStyle.self, forKey: .pageTurn) ?? pageTurn
        boldText = try c.decodeIfPresent(Bool.self, forKey: .boldText) ?? boldText
        justified = try c.decodeIfPresent(Bool.self, forKey: .justified) ?? justified
        characterSpacing = try c.decodeIfPresent(Double.self, forKey: .characterSpacing) ?? characterSpacing
        wordSpacing = try c.decodeIfPresent(Double.self, forKey: .wordSpacing) ?? wordSpacing
        paragraphSpacing = try c.decodeIfPresent(Double.self, forKey: .paragraphSpacing) ?? (spacing + 5)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? voice
        narrationHighlight = try c.decodeIfPresent(Bool.self, forKey: .narrationHighlight) ?? narrationHighlight
        highlightMode = try c.decodeIfPresent(HighlightMode.self, forKey: .highlightMode) ?? highlightMode
        highlightColor = try c.decodeIfPresent(HighlightColor.self, forKey: .highlightColor) ?? highlightColor
        highlightOpacity = try c.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? highlightOpacity
        savedHighlightColor = try c.decodeIfPresent(HighlightColor.self, forKey: .savedHighlightColor) ?? savedHighlightColor
        showSavedHighlights = try c.decodeIfPresent(Bool.self, forKey: .showSavedHighlights) ?? showSavedHighlights
        lineGuide = try c.decodeIfPresent(Bool.self, forKey: .lineGuide) ?? lineGuide
        guideDimming = try c.decodeIfPresent(GuideDimming.self, forKey: .guideDimming) ?? guideDimming
        searchWholeWords = try c.decodeIfPresent(Bool.self, forKey: .searchWholeWords) ?? searchWholeWords
        searchCaseSensitive = try c.decodeIfPresent(Bool.self, forKey: .searchCaseSensitive) ?? searchCaseSensitive
    }
}
struct BookAnnotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var bookID: UUID
    var location: Location
    var length: Int // Zero denotes a bookmark.
    var excerpt: String
    var color: HighlightColor
    var created = Date()
    var bookmark: Bool { length == 0 }
}
struct BookSearchResult: Identifiable, Sendable {
    var chapter: Int
    var offset: Int
    var length: Int
    var title: String
    var excerpt: String
    var id: String { "\(chapter):\(offset)" }
    var location: Location { Location(chapter: chapter, offset: offset) }
}
enum BookSearch {
    static func find(in book: Book, query: String, wholeWords: Bool, caseSensitive: Bool) -> [BookSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let escaped = NSRegularExpression.escapedPattern(for: query)
        let pattern = wholeWords ? "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])" : escaped
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        var results: [BookSearchResult] = []
        for (index, chapter) in book.chapters.enumerated() {
            regex.enumerateMatches(in: chapter.text, range: NSRange(location: 0, length: chapter.length)) { match, _, _ in
                guard let range = match?.range else { return }
                let ns = chapter.text as NSString
                let start = max(0, range.location - 45)
                let end = min(ns.length, NSMaxRange(range) + 85)
                let safe = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
                let excerpt = ns.substring(with: safe).replacingOccurrences(of: "\n", with: " ")
                results.append(BookSearchResult(chapter: index, offset: range.location, length: range.length, title: chapter.title, excerpt: excerpt))
            }
        }
        return results
    }
}

@MainActor final class Library: ObservableObject {
    @Published var books: [Book] = []
    @Published var settings = ReaderSettings()
    @Published var error: String?
    @Published var importing = false
    @Published var annotations: [BookAnnotation] = []
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Follow", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: self.directory.appendingPathComponent("annotations.json")) { annotations = try JSONDecoder().decode([BookAnnotation].self, from: data) }
            let url = self.directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: url.path) { books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: url)) }
            if let data = try? Data(contentsOf: self.directory.appendingPathComponent("positions.json")), let positions = try? JSONDecoder().decode([String: Location].self, from: data) {
                for i in books.indices { if let position = positions[books[i].id.uuidString] { books[i].location = position } }
            }
            var upgraded = false
            for i in books.indices where books[i].parserVersion != 2 {
                let original = self.directory.appendingPathComponent(books[i].id.uuidString + ".epub")
                if FileManager.default.fileExists(atPath: original.path) {
                    let old = books[i]
                    var fresh = try EPUBImporter.load(original)
                    fresh.id = old.id
                    fresh.location = PositionMigration.restore(old: old, new: fresh)
                    books[i] = fresh
                    upgraded = true
                }
            }
            if upgraded {
                try JSONEncoder().encode(books).write(to: self.directory.appendingPathComponent("library.json"), options: .atomic)
                let positions = Dictionary(uniqueKeysWithValues: books.map { ($0.id.uuidString, $0.location) })
                try JSONEncoder().encode(positions).write(to: self.directory.appendingPathComponent("positions.json"), options: .atomic)
            }
            if let data = UserDefaults.standard.data(forKey: "readerSettings") { settings = try JSONDecoder().decode(ReaderSettings.self, from: data) }
        } catch { self.error = "Your library could not be loaded: \(error.localizedDescription)" }
    }
    func save() {
        do {
            try JSONEncoder().encode(books).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
            UserDefaults.standard.set(try JSONEncoder().encode(settings), forKey: "readerSettings")
        } catch { self.error = "Your reading position could not be saved: \(error.localizedDescription)" }
    }
    func update(_ id: UUID, location: Location) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].location = location
        do {
            let positions = Dictionary(uniqueKeysWithValues: books.map { ($0.id.uuidString, $0.location) })
            try JSONEncoder().encode(positions).write(to: directory.appendingPathComponent("positions.json"), options: .atomic)
        } catch { self.error = "Your reading position could not be saved: \(error.localizedDescription)" }
    }
    func marks(for book: UUID) -> [BookAnnotation] {
        annotations.filter { $0.bookID == book }.sorted { $0.location.chapter == $1.location.chapter ? $0.location.offset < $1.location.offset : $0.location.chapter < $1.location.chapter }
    }
    func addHighlight(book: Book, location: Location, range: NSRange, color: HighlightColor) {
        guard book.chapters.indices.contains(location.chapter) else { return }
        let chapter = book.chapters[location.chapter]
        let range = NSIntersectionRange(range, NSRange(location: 0, length: chapter.length))
        guard range.length > 0 else { return }
        if let i = annotations.firstIndex(where: { $0.bookID == book.id && !$0.bookmark && $0.location == Location(chapter: location.chapter, offset: range.location) && $0.length == range.length }) {
            annotations[i].color = color
        } else {
            annotations.append(BookAnnotation(bookID: book.id, location: Location(chapter: location.chapter, offset: range.location), length: range.length, excerpt: (chapter.text as NSString).substring(with: range), color: color))
        }
        saveAnnotations()
    }
    func toggleBookmark(book: Book, location: Location) {
        if let i = annotations.firstIndex(where: { $0.bookID == book.id && $0.bookmark && $0.location == location }) { annotations.remove(at: i) }
        else if book.chapters.indices.contains(location.chapter) {
            let chapter = book.chapters[location.chapter]
            let range = chapter.sentence(at: location.offset)
            let excerpt = (chapter.text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            annotations.append(BookAnnotation(bookID: book.id, location: location, length: 0, excerpt: excerpt.isEmpty ? chapter.title : excerpt, color: .orange))
        }
        saveAnnotations()
    }
    func removeAnnotation(_ id: UUID) { annotations.removeAll { $0.id == id }; saveAnnotations() }
    func recolorAnnotation(_ id: UUID, color: HighlightColor) {
        if let i = annotations.firstIndex(where: { $0.id == id }) { annotations[i].color = color; saveAnnotations() }
    }
    private func saveAnnotations() {
        do { try JSONEncoder().encode(annotations).write(to: directory.appendingPathComponent("annotations.json"), options: .atomic) }
        catch { self.error = "Your highlights could not be saved: \(error.localizedDescription)" }
    }
    func pendingSharedBooks() -> [URL] {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var pending = ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension.lowercased() == "epub" }
        #if os(iOS) && !PERSONAL_BUILD
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.local.Follow") else { return pending }
        let inbox = group.appendingPathComponent("Inbox", isDirectory: true)
        pending += ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "epub" }
        return pending
        #else
        return pending
        #endif
    }
    func consumeSharedBook(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch { self.error = error.localizedDescription }
    }
    func importBook(_ url: URL) async -> UUID? {
        importing = true
        defer { importing = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let book = try await Task.detached(priority: .userInitiated) { try EPUBImporter.load(url) }.value
            if let existing = books.first(where: { $0.title == book.title && $0.author == book.author && $0.chapters.map(\.id) == book.chapters.map(\.id) }) { return existing.id }
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(book.id.uuidString + ".epub"))
            books.append(book)
            save()
            return book.id
        } catch { self.error = error.localizedDescription; return nil }
    }
}

enum PositionMigration {
    static func restore(old: Book, new: Book) -> Location {
        guard old.chapters.indices.contains(old.location.chapter) else { return new.location }
        let chapter = old.chapters[old.location.chapter]
        guard let index = new.chapters.firstIndex(where: { $0.id == chapter.id }) else { return new.location }
        let oldText = chapter.text as NSString
        let cursor = min(old.location.offset, oldText.length)
        let excerpt = oldText.substring(from: cursor).prefix(90)
        let tokens = excerpt.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let needle = tokens.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        let replacement = new.chapters[index]
        if !needle.isEmpty, let expression = try? NSRegularExpression(pattern: needle) {
            let matches = expression.matches(in: replacement.text, range: NSRange(location: 0, length: replacement.length))
            if let match = matches.min(by: { abs($0.range.location - cursor) < abs($1.range.location - cursor) }) { return Location(chapter: index, offset: match.range.location) }
        }
        return Location(chapter: index, offset: min(cursor, replacement.length))
    }
}
