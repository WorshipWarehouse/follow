import XCTest
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import ZIPFoundation
#if PERSONAL_TEST
@testable import FollowPersonal
#else
@testable import Follow
#endif

final class FollowTests: XCTestCase {
    func testPastedEPUBIsCopiedBeforeProviderFileExpires() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        let provider = NSItemProvider()
        let type = "org.idpf.epub-container"
        provider.registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        let staged = try await PasteBookButton.stage(provider, epub: type)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertNotEqual(staged, source)
        XCTAssertEqual(try EPUBImporter.load(staged).title, "The Quiet Hour")
    }
    func testPastedFileURLRejectsNonEPUB() async {
        let provider = NSItemProvider(item: URL(fileURLWithPath: "/tmp/not-a-book.pdf") as NSURL, typeIdentifier: UTType.fileURL.identifier)
        do {
            _ = try await PasteBookButton.stage(provider, epub: "org.idpf.epub-container")
            XCTFail("Non-EPUB clipboard files must be rejected")
        } catch {}
    }
    @MainActor func testFileImportStagesAndPersistsEPUB() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(directory: folder)
        let imported = await library.importBook(source)
        let id = try XCTUnwrap(imported, library.error ?? "Import failed")
        XCTAssertEqual(library.books.first?.title, "The Quiet Hour")
        XCTAssertEqual(Library(directory: folder).books.first?.id, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(id.uuidString + ".epub").path))
        let duplicate = await library.importBook(source)
        XCTAssertEqual(duplicate, id)
        XCTAssertEqual(library.books.count, 1)
    }
    func testPastedRawEPUBDataImports() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        let bytes = try Data(contentsOf: source)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "org.idpf.epub-container", visibility: .all) { completion in
            completion(bytes, nil)
            return nil
        }
        let staged = try await PasteBookButton.stage(provider, epub: "org.idpf.epub-container")
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(try EPUBImporter.load(staged).title, "The Quiet Hour")
    }
    func testIncompleteArchiveExplainsHowToRecover() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Not a ZIP archive".utf8).write(to: url)
        XCTAssertThrowsError(try EPUBImporter.load(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("incomplete"))
            XCTAssertFalse(error.localizedDescription.contains("error 13"))
        }
    }
    @MainActor func testAppleBooksDirectoryImportOnPhone() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent("Apple Books.epub")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: source, to: package)
        let library = Library(directory: folder.appendingPathComponent("Library"))
        let imported = await library.importBook(package)
        let id = try XCTUnwrap(imported, library.error ?? "Import failed")
        XCTAssertEqual(library.books.first?.title, "The Quiet Hour")
        let retained = folder.appendingPathComponent("Library").appendingPathComponent(id.uuidString + ".epub")
        XCTAssertEqual(try EPUBImporter.load(retained).title, "The Quiet Hour")
        let provider = NSItemProvider(item: package as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let pasted = try await PasteBookButton.stage(provider, epub: "org.idpf.epub-container")
        defer { try? FileManager.default.removeItem(at: pasted.deletingLastPathComponent()) }
        XCTAssertEqual(try EPUBImporter.load(pasted).title, "The Quiet Hour")
    }
    private func sample() throws -> Book {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        return try EPUBImporter.load(url)
    }
    func testImportSpineMetadataAndFragmentContents() throws {
        let book = try sample()
        XCTAssertEqual(book.title, "The Quiet Hour")
        XCTAssertEqual(book.author, "Follow Sample")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.contents.count, 2)
        XCTAssertEqual(book.contents[1].location.chapter, 1)
        XCTAssertEqual(book.contents[1].location.offset, book.chapters[1].anchors["p20"])
        XCTAssertTrue(book.chapters[0].text.contains("🐦"))
    }
    func testUTF16SentenceAndExactMidSentenceStart() {
        let chapter = Chapter(id: "one", title: "One", text: "Bird 🐦 sings. Another sentence begins.", anchors: [:])
        let offset = (chapter.text as NSString).range(of: "sings").location
        let range = chapter.sentence(at: offset)
        XCTAssertEqual((chapter.text as NSString).substring(with: range).trimmingCharacters(in: .whitespaces), "Bird 🐦 sings.")
        let utterance = (chapter.text as NSString).substring(with: NSRange(location: offset, length: NSMaxRange(range) - offset))
        XCTAssertEqual(utterance.trimmingCharacters(in: .whitespaces), "sings.")
    }
    @MainActor func testPaginationHasNoLostTextAndContainsPosition() throws {
        let book = try sample()
        let chapter = book.chapters[0]
        let layout = PageLayout(chapter: chapter, size: CGSize(width: 300, height: 500), settings: ReaderSettings(), color: .black)
        XCTAssertGreaterThan(layout.ranges.count, 5)
        XCTAssertEqual(layout.ranges.first?.location, 0)
        XCTAssertEqual(NSMaxRange(try XCTUnwrap(layout.ranges.last)), chapter.length)
        for i in 1..<layout.ranges.count { XCTAssertEqual(layout.ranges[i].location, NSMaxRange(layout.ranges[i-1])) }
        let target = layout.ranges[3].location + 7
        XCTAssertEqual(layout.page(at: target), 3)
        let larger = PageLayout(chapter: chapter, size: CGSize(width: 300, height: 500), settings: { var s = ReaderSettings(); s.size = 30; return s }(), color: .black)
        XCTAssertTrue(NSLocationInRange(target, larger.ranges[larger.page(at: target)]))
    }
    @MainActor func testPositionSurvivesLibraryReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = Library(directory: directory)
        let book = try sample()
        library.books = [book]
        library.save()
        let position = Location(chapter: 1, offset: 314)
        library.update(book.id, location: position)
        let restored = Library(directory: directory)
        XCTAssertEqual(restored.books.first?.location, position)
        XCTAssertGreaterThan(restored.books[0].progress, 0.5)
    }
    @MainActor func testSeekingUsesSharedPositionAndClampsBounds() throws {
        let book = try sample()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = Library(directory: directory)
        library.books = [book]
        library.save()
        let narrator = Narrator()
        narrator.open(book, library: library)
        narrator.seek(Location(chapter: 0, offset: 733))
        XCTAssertEqual(library.books[0].location, narrator.location)
        narrator.seek(Location(chapter: 999, offset: 999999))
        XCTAssertEqual(narrator.location.chapter, 1)
        XCTAssertEqual(narrator.location.offset, book.chapters[1].length)
    }
}

extension FollowTests {
    @MainActor func testEveryPageFitsAndPreservesAllText() throws {
        let fixture = try sample()
        let imported = Library().books.first { $0.title == "Pray First" }
        let books = [fixture] + (imported.map { [$0] } ?? [])
        for book in books {
            for chapter in book.chapters {
                for fontSize in [21.0, 30.0] {
                    var settings = ReaderSettings()
                    settings.size = fontSize
                    let layout = PageLayout(chapter: chapter, size: CGSize(width: 330, height: 590), settings: settings, color: .black)
                    XCTAssertEqual(NSMaxRange(try XCTUnwrap(layout.ranges.last)), chapter.length)
                    for (index, container) in layout.containers.enumerated() {
                        let rect = layout.manager.usedRect(for: container)
                        XCTAssertLessThanOrEqual(rect.maxY, layout.size.height + 1, "\(chapter.id) page \(index)")
                        XCTAssertLessThanOrEqual(rect.maxX, layout.size.width + 1, "\(chapter.id) page \(index)")
                        if index > 0 { XCTAssertEqual(layout.ranges[index].location, NSMaxRange(layout.ranges[index - 1])) }
                    }
                }
            }
        }
    }
    @MainActor func testAdjacentPagesCrossChapterWithoutLosingPosition() throws {
        let book = try sample()
        let doc = ReaderDocument(book: book, size: CGSize(width: 390, height: 660), settings: ReaderSettings(), color: .black, paper: .white)
        let last = PageAddress(chapter: 0, page: doc.layout(0).ranges.count - 1)
        let next = try XCTUnwrap(doc.adjacent(last, direction: 1))
        XCTAssertEqual(next, PageAddress(chapter: 1, page: 0))
        XCTAssertEqual(doc.adjacent(next, direction: -1), last)
        XCTAssertEqual(doc.location(next), Location(chapter: 1, offset: 0))
    }
}

extension FollowTests {
    @MainActor func testTextSelectionRemainsAvailableWithLineGuideOff() throws {
        let book = try sample()
        let chapter = book.chapters[0]
        let layout = PageLayout(chapter: chapter, size: CGSize(width: 330, height: 590), settings: ReaderSettings(), color: .black)
        let canvas = PageCanvas(layout: layout, index: 0, chapter: chapter)
        let hold = try XCTUnwrap(canvas.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
        let pan = try XCTUnwrap(canvas.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        XCTAssertTrue(canvas.gestureRecognizerShouldBegin(hold))
        XCTAssertFalse(canvas.gestureRecognizerShouldBegin(pan))
        var settings = ReaderSettings()
        settings.lineGuide = true
        canvas.update(settings: settings, marks: [], focusOffset: 10)
        XCTAssertTrue(canvas.gestureRecognizerShouldBegin(hold))
        XCTAssertNotNil(canvas.guideRect)
        let counts = layout.ranges
        settings.narrationHighlight = false
        settings.guideDimming = .high
        canvas.update(settings: settings, marks: [], focusOffset: 100)
        XCTAssertEqual(layout.ranges, counts)
    }
    @MainActor func testSeekClearsLiveWordHighlight() throws {
        let book = try sample()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = Library(directory: directory)
        library.books = [book]
        let narrator = Narrator()
        narrator.open(book, library: library)
        narrator.wordHighlight = NSRange(location: 10, length: 3)
        narrator.highlight = NSRange(location: 0, length: 80)
        narrator.seek(Location(chapter: 0, offset: 400))
        XCTAssertNil(narrator.wordHighlight)
        XCTAssertNil(narrator.highlight)
        XCTAssertEqual(narrator.location.offset, 400)
    }
}

extension FollowTests {
    @MainActor func testLineGuideFadesGlyphsWithoutShadingPaper() throws {
        let chapter = Chapter(id: "guide", title: "Guide", text: String(repeating: "A clear line of readable text.\n", count: 8), anchors: [:])
        for theme in ["Light", "Sepia", "Dark", "Dusk"] {
            var settings = ReaderSettings(); settings.theme = theme
            let palette = ReaderPalette(settings: settings, systemDark: false)
            let layout = PageLayout(chapter: chapter, size: CGSize(width: 300, height: 430), settings: settings, color: palette.ink)
            let canvas = PageCanvas(layout: layout, index: 0, chapter: chapter)
            canvas.frame = CGRect(origin: .zero, size: layout.size)
            func render(_ settings: ReaderSettings) -> [UInt8] {
                canvas.update(settings: settings, marks: [], focusOffset: 0)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                let image = UIGraphicsImageRenderer(size: layout.size, format: format).image { context in
                    palette.paper.setFill(); context.fill(canvas.bounds); canvas.draw(canvas.bounds)
                }
                var bytes = [UInt8](repeating: 0, count: 300 * 430 * 4)
                bytes.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 300, height: 430, bitsPerComponent: 8, bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image.cgImage!, in: canvas.bounds)
                }
                return bytes
            }
            let normal = render(settings)
            settings.lineGuide = true; settings.guideDimming = .high
            let dimmed = render(settings)
            let corner = (430 * 300 - 1) * 4
            XCTAssertEqual(Array(normal[corner..<corner + 4]), Array(dimmed[corner..<corner + 4]), "Paper must stay unchanged in \(theme)")
            // Locate a strongly contrasting glyph well away from the first (focused) line.
            var sample = 0, contrast = 0
            let paper = Array(normal[corner..<corner + 3]).map(Int.init)
            for pixel in (40 * 300)..<(380 * 300) {
                let offset = pixel * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(normal[offset + $1]) - paper[$1]) }
                if difference > contrast { contrast = difference; sample = offset }
            }
            XCTAssertGreaterThan(contrast, 150)
            let fadedContrast = (0..<3).reduce(0) { $0 + abs(Int(dimmed[sample + $1]) - paper[$1]) }
            XCTAssertLessThan(fadedContrast, contrast, "Text must fade toward the paper in \(theme)")
        }
    }
    @MainActor func testCurlReverseFacesUseSelectedPaper() throws {
        for theme in ["Light", "Sepia", "Mist", "Dusk", "Dark"] {
            var settings = ReaderSettings(); settings.theme = theme
            let palette = ReaderPalette(settings: settings, systemDark: false)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 660), format: format).image { context in palette.paper.setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 660)) }
            let sheet = CurlSheet(image: image, paper: palette.paper, size: image.size)
            XCTAssertFalse(sheet.reverseFaces.isEmpty)
            for face in sheet.reverseFaces { XCTAssertEqual(face.backgroundColor, palette.paper.cgColor) }
            sheet.update(progress: 0)
            XCTAssertGreaterThan(sheet.strips.last!.position.x, 380)
            sheet.update(progress: 0.5)
            XCTAssertTrue(sheet.strips.contains { $0.zPosition > 0 })
            sheet.update(progress: 1)
            XCTAssertTrue(sheet.strips.allSatisfy { $0.position.x < 0 })
        }
    }
    @MainActor func testEveryTurnStyleCompletesForwardAndBackward() async throws {
        let book = try sample()
        for style in PageTurnStyle.allCases {
            var settings = ReaderSettings(); settings.pageTurn = style; settings.theme = "Dark"
            let palette = ReaderPalette(settings: settings, systemDark: false)
            let document = ReaderDocument(book: book, size: CGSize(width: 390, height: 660), settings: settings, color: palette.ink, paper: palette.paper)
            let controller = PageTurnController(); controller.loadViewIfNeeded(); controller.view.frame = CGRect(origin: .zero, size: document.size)
            let first = PageAddress(chapter: 0, page: 0), next = PageAddress(chapter: 0, page: 1)
            controller.present(BookPageController(document: document, address: first), style: style, direction: 1, animated: false, completion: {})
            for (address, direction) in [(next, 1), (first, -1)] {
                let done = expectation(description: "\(style.rawValue) \(direction)")
                controller.present(BookPageController(document: document, address: address), style: style, direction: direction, animated: true) { done.fulfill() }
                await fulfillment(of: [done], timeout: 3)
                XCTAssertEqual(controller.current?.address, address)
                XCTAssertEqual(controller.view.backgroundColor, palette.paper)
                XCTAssertEqual(controller.children.count, 1)
            }
        }
    }
    @MainActor func testStylingRepaginatesWithoutLosingTextOrPosition() throws {
        let book = try sample()
        let chapter = book.chapters[0]
        var settings = ReaderSettings()
        settings.boldText = true; settings.justified = true; settings.characterSpacing = 1.2; settings.wordSpacing = 4; settings.paragraphSpacing = 24
        let layout = PageLayout(chapter: chapter, size: CGSize(width: 330, height: 590), settings: settings, color: .black)
        XCTAssertEqual(NSMaxRange(try XCTUnwrap(layout.ranges.last)), chapter.length)
        for index in 1..<layout.ranges.count { XCTAssertEqual(layout.ranges[index].location, NSMaxRange(layout.ranges[index - 1])) }
        XCTAssertTrue(NSLocationInRange(500, layout.ranges[layout.page(at: 500)]))
        let font = try XCTUnwrap(layout.text.attribute(.font, at: 100, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        let style = try XCTUnwrap(layout.text.attribute(.paragraphStyle, at: 100, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacing, 24)
    }
}

extension FollowTests {
    @MainActor func testVoiceCatalogIncludesEveryVoiceExposedByDevice() {
        let catalog = VoiceCatalog()
        let exposed = AVSpeechSynthesisVoice.speechVoices()
        XCTAssertFalse(exposed.isEmpty)
        XCTAssertEqual(Set(catalog.matching(query: "", language: "all").map(\.identifier)), Set(exposed.map(\.identifier)))
        let english = exposed.filter { $0.language.hasPrefix("en-") || $0.language == "en" }
        XCTAssertEqual(Set(catalog.matching(query: "", language: "en").map(\.identifier)), Set(english.map(\.identifier)))
        for voice in catalog.voices {
            XCTAssertFalse(VoiceCatalog.qualityName(voice).isEmpty)
            XCTAssertTrue(catalog.matching(query: voice.name, language: "all").contains { $0.identifier == voice.identifier })
        }
        print("Device voice inventory: \(exposed.count) app-accessible voices; \(english.count) English voices; \(english.filter { $0.name.localizedCaseInsensitiveContains("siri") }.count) English voices named Siri.")
    }
    @MainActor func testUnavailableVoiceReportsErrorInsteadOfChangingVoice() throws {
        let book = try sample()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = Library(directory: directory)
        library.settings.voice = "com.follow.test.unavailable.voice"
        let narrator = Narrator(); narrator.open(book, library: library); narrator.play()
        XCTAssertFalse(narrator.playing)
        XCTAssertTrue(narrator.error?.contains("selected voice is no longer available") == true)
        XCTAssertEqual(library.settings.voice, "com.follow.test.unavailable.voice")
    }
}

extension FollowTests {
    @MainActor func testAccessibilityReaderStartsAtCursorAndKeepsRemainingChapters() throws {
        var book = try sample()
        book.chapters = [Chapter(id: "a", title: "One", text: "Before 🐦 after.", anchors: [:]), Chapter(id: "b", title: "Two", text: "Next chapter.", anchors: [:])]
        let bird = (book.chapters[0].text as NSString).range(of: "🐦").location
        let text = AccessibilityReadingView.remainingText(book: book, location: Location(chapter: 0, offset: bird + 1))
        XCTAssertEqual(text, "🐦 after.\n\nNext chapter.")
        XCTAssertFalse(text.contains("Before"))
        XCTAssertEqual(AccessibilityReadingView.remainingText(book: book, location: Location(chapter: 1, offset: 9999)), "")
    }
}
