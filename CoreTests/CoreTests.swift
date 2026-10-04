import XCTest
@testable import FollowCore

final class CoreTests: XCTestCase {
    func sample() throws -> Book { try EPUBImporter.load(XCTUnwrap(Bundle.module.url(forResource: "Sample", withExtension: "epub"))) }
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
