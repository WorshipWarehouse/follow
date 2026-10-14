import XCTest
import ZIPFoundation
@testable import FollowCore

final class CoreTests: XCTestCase {
    func sample() throws -> Book { try EPUBImporter.load(XCTUnwrap(Bundle.module.url(forResource: "Sample", withExtension: "epub"))) }
    @MainActor func testMetadataEditsPersistWithoutLosingReadingDataOrDuplicatingImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = Library(directory: directory)
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Sample", withExtension: "epub"))
        let imported = await library.importBook(source)
        let id = try XCTUnwrap(imported)
        let original = try XCTUnwrap(library.books.first)
        let position = Location(chapter: 1, offset: 20)
        library.update(id, location: position)
        library.toggleBookmark(book: original, location: position)
        library.addHighlight(book: original, location: position, range: NSRange(location: 20, length: 8), color: .blue)
        let cover = Data([1, 2, 3])
        let edited = try library.editBook(id, title: " Correct Title ", author: "New Author", cover: cover)
        XCTAssertEqual(edited.location, position)
        XCTAssertEqual(edited.chapters.map(\.text), original.chapters.map(\.text))
        let restored = Library(directory: directory)
        XCTAssertEqual(restored.books.first?.title, "Correct Title")
        XCTAssertEqual(restored.books.first?.author, "New Author")
        XCTAssertEqual(restored.books.first?.cover, cover)
        XCTAssertEqual(restored.books.first?.location, position)
        XCTAssertEqual(restored.marks(for: id).count, 2)
        let duplicate = await restored.importBook(source)
        XCTAssertEqual(duplicate, id)
        XCTAssertEqual(restored.books.count, 1)
        _ = try restored.editBook(id, title: "Correct Title", author: "", cover: nil)
        XCTAssertNil(Library(directory: directory).books.first?.cover)
        XCTAssertThrowsError(try restored.editBook(id, title: "   ", author: "", cover: nil))
    }
    @MainActor func testUnpackedEPUBImportPreservesContentAndArchivedCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Sample", withExtension: "epub"))
        let package = folder.appendingPathComponent("Unpacked.epub")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: source, to: package)
        let expected = try EPUBImporter.load(source)
        let library = Library(directory: folder.appendingPathComponent("Library"))
        let imported = await library.importBook(package)
        let id = try XCTUnwrap(imported, library.error ?? "Import failed")
        let actual = try XCTUnwrap(library.books.first)
        XCTAssertEqual(actual.title, expected.title)
        XCTAssertEqual(actual.chapters.map(\.text), expected.chapters.map(\.text))
        let archive = folder.appendingPathComponent("Library").appendingPathComponent(id.uuidString + ".epub")
        XCTAssertEqual(try EPUBImporter.load(archive).chapters.map(\.text), expected.chapters.map(\.text))
        XCTAssertTrue(try package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }
    func testProvidedAppleBooksPackages() throws {
        guard let root = ProcessInfo.processInfo.environment["FOLLOW_APPLE_BOOKS_TEST_DIRECTORY"] else { throw XCTSkip("Local user books are not bundled") }
        let names = ["3198baa3-9d9b-41db-8a7c-b1c65f169bf0.epub", "Becoming a Level 5 Multiplying Church Field Guide.epub", "Church Unique How Missional Leaders Cast Vision Capture Culture and Cr.epub", "Gods Voice Within The Ignatian Way to Discover Gods Will.epub", "If Trading Your if Only Regrets for Gods What if Possibilities.epub", "pdfcoffeecom james-m-kouzes-barry-z-posner-the-leadership-pdf-free.epub", "The Bible Recap Study Guide.epub", "The Bible Recap.epub", "The Circle Maker.epub", "The Purpose-Driven Life What on Earth Am I Here For.epub"]
        for name in names {
            let book = try EPUBImporter.load(URL(fileURLWithPath: root).appendingPathComponent(name))
            XCTAssertFalse(book.chapters.isEmpty, name)
            print("Imported Apple Books package: \(name); \(book.chapters.count) chapters")
        }
    }
    @MainActor func testLibraryOrdersRecentBooksBeforeFinishedAndPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var first = try sample()
        var second = first; second.id = UUID()
        var third = first; third.id = UUID()
        first.lastOpened = Date(timeIntervalSince1970: 10)
        second.lastOpened = Date(timeIntervalSince1970: 20)
        third.lastOpened = Date(timeIntervalSince1970: 30); third.finished = true
        let library = Library(directory: folder)
        library.books = [first, second, third]
        XCTAssertEqual(library.sortedBooks.map(\.id), [second.id, first.id, third.id])
        library.markOpened(first.id, at: Date(timeIntervalSince1970: 40))
        XCTAssertEqual(library.sortedBooks.map(\.id), [first.id, second.id, third.id])
        library.markFinished(first.id, finished: true)
        let restored = Library(directory: folder)
        XCTAssertEqual(restored.sortedBooks.map(\.id), [second.id, first.id, third.id])
        restored.markFinished(third.id, finished: false)
        XCTAssertEqual(restored.sortedBooks.map(\.id), [third.id, second.id, first.id])
        restored.update(second.id, location: Location(chapter: second.chapters.count - 1, offset: second.chapters.last!.length))
        XCTAssertTrue(Library(directory: folder).books.first(where: { $0.id == second.id })!.isFinished)
    }
    func testEPUBSpineAndFragmentNavigation() throws {
        let book = try sample()
        XCTAssertEqual(book.title, "The Quiet Hour")
        XCTAssertEqual(book.author, "Follow Sample")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.contents[1].location.chapter, 1)
        XCTAssertEqual(book.contents[1].location.offset, book.chapters[1].anchors["p20"])
        XCTAssertTrue(book.chapters[0].text.contains("🐦"))
    }
    func testUTF16OffsetsAfterEmoji() {
        let chapter = Chapter(id: "a", title: "A", text: "Bird 🐦 sings. Another sentence begins.", anchors: [:])
        let offset = (chapter.text as NSString).range(of: "sings").location
        let sentence = chapter.sentence(at: offset)
        XCTAssertEqual((chapter.text as NSString).substring(with: sentence).trimmingCharacters(in: .whitespaces), "Bird 🐦 sings.")
        XCTAssertEqual((chapter.text as NSString).substring(with: NSRange(location: offset, length: NSMaxRange(sentence) - offset)).trimmingCharacters(in: .whitespaces), "sings.")
        XCTAssertEqual(chapter.sentence(at: NSMaxRange(sentence)).location, (chapter.text as NSString).range(of: "Another").location)
    }
    @MainActor func testPositionRestorationAndProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = try sample()
        let library = Library(directory: directory)
        library.books = [book]
        library.save()
        let position = Location(chapter: 1, offset: 314)
        library.update(book.id, location: position)
        let restored = Library(directory: directory)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.books[0].location, position)
        XCTAssertGreaterThan(restored.books[0].progress, 0.5)
    }
    func testInvalidArchiveRejected() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("Not an EPUB".utf8).write(to: url)
        XCTAssertThrowsError(try EPUBImporter.load(url))
    }
}

extension CoreTests {
    func testHiddenNavigationAndInlineTextAreHandled() throws {
        let xml = """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <p class="indent">Fish &amp; <em>chips</em> stay together.</p>
        <p hidden="hidden">Hidden text.</p><p class="hidden">Invisible CSS text.</p>
        <nav epub:type="page-list" hidden=""><a>Page 4</a></nav>
        <p>Before<span epub:type="pagebreak">9</span> after<a epub:type="noteref">1</a>.</p>
        <p><a href="https://example.com">Example.com</a></p>
        </body></html>
        """
        let tree = try XMLReader.parse(Data(xml.utf8))
        let renderer = ChapterRenderer(sheet: StyleSheet(".hidden {display:none;} .indent {text-indent:1.5em;}")) { _ in Data() }
        try renderer.render(XCTUnwrap(tree.nodes.first(where: { $0.name == "body" })))
        XCTAssertEqual(renderer.text, "Fish & chips stay together.\nBefore after.\n")
        XCTAssertTrue(renderer.spans.contains(where: { $0.italic }))
        XCTAssertTrue(renderer.spans.contains(where: { $0.indent == 1.5 }))
    }
    func testParagraphBoundariesAndImageSpeechOffsets() {
        let chapter = Chapter(id: "p", title: "P", text: "\u{FFFC}\nA heading\nFirst sentence. Next one.\n", anchors: [:])
        XCTAssertEqual(chapter.nextSpokenOffset(0), 2)
        XCTAssertEqual((chapter.text as NSString).substring(with: chapter.sentence(at: 0)), "A heading\n")
        let first = (chapter.text as NSString).range(of: "First").location
        XCTAssertEqual((chapter.text as NSString).substring(with: chapter.sentence(at: first)).trimmingCharacters(in: .whitespacesAndNewlines), "First sentence.")
    }
    func testMigrationPreservesWordDespiteWhitespaceChanges() throws {
        var old = try sample()
        old.chapters[0].text = "A title\n\nHere is the reading position. More follows."
        old.location = Location(chapter: 0, offset: (old.chapters[0].text as NSString).range(of: "reading").location)
        var new = old
        new.chapters[0].text = "A title\nHere is the reading position. More follows."
        let restored = PositionMigration.restore(old: old, new: new)
        XCTAssertEqual(restored.offset, (new.chapters[0].text as NSString).range(of: "reading").location)
    }
    func testUserProvidedEPUB() throws {
        guard let path = ProcessInfo.processInfo.environment["FOLLOW_TEST_EPUB"] else { throw XCTSkip("Provide FOLLOW_TEST_EPUB for the local regression book.") }
        let book = try EPUBImporter.load(URL(fileURLWithPath: path))
        XCTAssertEqual(book.title, "Pray First")
        XCTAssertEqual(book.author, "Chris Hodges")
        XCTAssertEqual(book.parserVersion, 2)
        XCTAssertEqual(book.chapters.filter { $0.id.contains("_Chapter_") }.count, 17)
        XCTAssertFalse(book.chapters.contains { $0.id.hasSuffix("nav.xhtml") })
        XCTAssertTrue(book.chapters[book.location.chapter].id.contains("Introduction"))
        XCTAssertNotNil(book.cover)
        XCTAssertGreaterThan(book.chapters.flatMap { $0.images ?? [] }.count, 15)
        XCTAssertFalse(book.chapters.contains { $0.text.contains("OceanofPDF.com") })
        XCTAssertTrue(book.chapters.contains { ($0.spans ?? []).contains(where: { $0.italic }) })
        XCTAssertGreaterThan(book.contents.count, 20)
        for entry in book.contents { XCTAssertLessThanOrEqual(entry.location.offset, book.chapters[entry.location.chapter].length) }
        print("Regression EPUB: \(book.chapters.count) spine sections, \(book.contents.count) TOC entries, \(book.chapters.reduce(0) { $0 + $1.length }) UTF-16 units.")
    }
}

extension CoreTests {
    func testExistingPreferencesKeepValuesAndNewOptionsDefault() throws {
        let data = Data(#"{"font":"Palatino","size":28,"spacing":10,"margin":32,"theme":"Sepia","speed":2.5,"voice":"saved-voice"}"#.utf8)
        let settings = try JSONDecoder().decode(ReaderSettings.self, from: data)
        XCTAssertEqual(settings.size, 28)
        XCTAssertEqual(settings.voice, "saved-voice")
        XCTAssertEqual(settings.speed, 2.5)
        XCTAssertTrue(settings.narrationHighlight)
        XCTAssertFalse(settings.lineGuide)
        XCTAssertEqual(settings.highlightMode, .sentence)
        XCTAssertEqual(try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertTrue(ReaderSettings.speeds.contains(3))
        XCTAssertTrue(ReaderSettings.speeds.contains(4))
    }
    func testSearchEscapesLiteralsAndPreservesUTF16Locations() throws {
        var book = try sample()
        book.chapters = [Chapter(id: "a", title: "One", text: "🐦 Prayer, prayerful PRAYER. [pray]", anchors: [:]), Chapter(id: "b", title: "Two", text: "prayer", anchors: [:])]
        let all = BookSearch.find(in: book, query: "prayer", wholeWords: false, caseSensitive: false)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.first?.offset, 3)
        let whole = BookSearch.find(in: book, query: "prayer", wholeWords: true, caseSensitive: false)
        XCTAssertEqual(whole.count, 3)
        XCTAssertEqual(BookSearch.find(in: book, query: "prayer", wholeWords: true, caseSensitive: true).count, 1)
        let literal = BookSearch.find(in: book, query: "[pray]", wholeWords: false, caseSensitive: false)
        XCTAssertEqual(literal.count, 1)
        XCTAssertEqual((book.chapters[0].text as NSString).substring(with: NSRange(location: literal[0].offset, length: literal[0].length)), "[pray]")
    }
    @MainActor func testAnnotationsSurviveReloadAndRemainIndependentOfReadingCursor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = try sample()
        let library = Library(directory: directory)
        library.books = [book]; library.save()
        let range = book.chapters[0].sentence(at: 20)
        library.addHighlight(book: book, location: Location(), range: range, color: .pink)
        library.addHighlight(book: book, location: Location(), range: range, color: .blue)
        let bookmark = Location(chapter: 1, offset: 300)
        library.toggleBookmark(book: book, location: bookmark)
        library.update(book.id, location: Location(chapter: 0, offset: 500))
        let restored = Library(directory: directory)
        XCTAssertEqual(restored.marks(for: book.id).count, 2)
        let highlight = try XCTUnwrap(restored.marks(for: book.id).first { !$0.bookmark })
        XCTAssertEqual(highlight.color, .blue)
        XCTAssertEqual(highlight.excerpt, (book.chapters[0].text as NSString).substring(with: range))
        XCTAssertEqual(restored.books[0].location.offset, 500)
        restored.toggleBookmark(book: book, location: bookmark)
        restored.removeAnnotation(highlight.id)
        XCTAssertTrue(Library(directory: directory).marks(for: book.id).isEmpty)
    }
}

extension CoreTests {
    func testNewStylingDefaultsPreserveOldParagraphSpacingAndSpeechChoices() throws {
        let legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"spacing":10,"speed":4,"voice":"chosen"}"#.utf8))
        XCTAssertEqual(legacy.paragraphSpacing, 15)
        XCTAssertEqual(legacy.pageTurn, .curl)
        XCTAssertFalse(legacy.boldText)
        XCTAssertEqual(legacy.characterSpacing, 0)
        var settings = legacy
        settings.narrationHighlight = false
        ReadingPreset.focus.apply(to: &settings)
        XCTAssertEqual(settings.speed, 4)
        XCTAssertEqual(settings.voice, "chosen")
        XCTAssertFalse(settings.narrationHighlight)
        settings.pageTurn = .fade
        XCTAssertEqual(try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
