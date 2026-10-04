import Foundation
import ZIPFoundation

final class XMLNode {
    var name: String
    var attributes: [String: String]
    var children: [XMLNode] = []
    var value = ""
    init(name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    var text: String { name == "#text" ? value : children.map(\.text).joined() }
    var descendants: [XMLNode] { [self] + children.flatMap(\.descendants) }
    func types(_ type: String) -> Bool { (attributes["epub:type"] ?? "").split(separator: " ").contains(Substring(type)) }
}
final class XMLReader: NSObject, XMLParserDelegate {
    var root = XMLNode(name: "document")
    var stack: [XMLNode] = []
    var nodes: [XMLNode] { root.descendants }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = XMLNode(name: elementName.components(separatedBy: ":").last!.lowercased(), attributes: attributeDict)
        (stack.last ?? root).children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let parent = stack.last else { return }
        if let last = parent.children.last, last.name == "#text" { last.value += string }
        else { let node = XMLNode(name: "#text"); node.value = string; parent.children.append(node) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    static func parse(_ data: Data) throws -> XMLReader {
        let reader = XMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw ImportFailure.invalid("The EPUB contains invalid XML or XHTML.") }
        return reader
    }
}
struct StyleSheet {
    var rules: [String: [String: String]] = [:]
    init(_ css: String) {
        let cleaned = css.replacingOccurrences(of: "(?s)/\\*.*?\\*/", with: "", options: [.regularExpression])
        let expression = try! NSRegularExpression(pattern: "([^{}]+)\\{([^{}]*)\\}")
        let ns = cleaned as NSString
        for match in expression.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let declaration = Self.declarations(ns.substring(with: match.range(at: 2)))
            for selector in ns.substring(with: match.range(at: 1)).split(separator: ",") {
                let key = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.contains(" ") && !key.contains(":") { rules[key, default: [:]].merge(declaration) { _, new in new } }
            }
        }
    }
    static func declarations(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in value.split(separator: ";") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        }
        return result
    }
    func properties(_ node: XMLNode) -> [String: String] {
        var result = rules[node.name] ?? [:]
        for cls in (node.attributes["class"] ?? "").split(separator: " ") {
            result.merge(rules["." + cls] ?? [:]) { _, new in new }
            result.merge(rules[node.name + "." + cls] ?? [:]) { _, new in new }
        }
        result.merge(Self.declarations(node.attributes["style"] ?? "")) { _, new in new }
        return result
    }
}
final class ChapterRenderer {
    var text = ""
    var anchors: [String: Int] = [:]
    var spans: [StyleSpan] = []
    var images: [BookImage] = []
    private var pendingSpace = false
    let sheet: StyleSheet
    let imageData: (String) throws -> Data
    init(sheet: StyleSheet, imageData: @escaping (String) throws -> Data) { self.sheet = sheet; self.imageData = imageData }
    private var offset: Int { (text as NSString).length }
    private func lineBreak() { pendingSpace = false; if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" } }
    private func append(_ value: String) {
        for char in value {
            if char == "\u{00AD}" || char == "\u{200B}" { continue }
            if char.isWhitespace { pendingSpace = !text.isEmpty && !text.hasSuffix("\n"); continue }
            if pendingSpace { text += " "; pendingSpace = false }
            text.append(char)
        }
    }
    func render(_ node: XMLNode, bold: Bool = false, italic: Bool = false) throws {
        if let id = node.attributes["id"] { anchors[id] = offset }
        if node.name == "#text" { append(node.value); return }
        let properties = sheet.properties(node)
        if ["head", "script", "style"].contains(node.name) || node.attributes["hidden"] != nil || node.attributes["aria-hidden"] == "true" || properties["display"] == "none" || properties["visibility"] == "hidden" || node.types("pagebreak") || node.types("noteref") || (node.name == "nav" && !node.types("toc")) { return }
        // Standalone external-domain links are distributor footers, not book prose.
        if node.name == "p", node.children.filter({ $0.name != "#text" }).count == 1,
           let link = node.children.first(where: { $0.name == "a" }), (link.attributes["href"] ?? "").hasPrefix("http"),
           node.text.trimmingCharacters(in: .whitespacesAndNewlines).range(of: "^[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", options: .regularExpression) != nil { return }
        if node.name == "img", let src = node.attributes["src"] {
            lineBreak()
            let data = try imageData(src)
            images.append(BookImage(offset: offset, data: data, alt: node.attributes["alt"] ?? "Illustration"))
            text += "\u{FFFC}\n"
            pendingSpace = false
            return
        }
        if node.name == "br" { text += "\n"; pendingSpace = false; return }
        let block = ["p", "div", "h1", "h2", "h3", "h4", "li", "section", "blockquote", "tr"].contains(node.name)
        if block { lineBreak() }
        let start = offset
        let isBold = bold || ["strong", "b"].contains(node.name) || properties["font-weight"] == "bold"
        let isItalic = italic || ["em", "i"].contains(node.name) || properties["font-style"] == "italic"
        for child in node.children { try render(child, bold: isBold, italic: isItalic) }
        if block { lineBreak() }
        let heading = node.name.hasPrefix("h") && node.name.count == 2 ? Int(node.name.dropFirst()) ?? 0 : 0
        if offset > start {
            let indentation = properties["text-indent"]?.hasSuffix("em") == true ? Double(properties["text-indent"]!.dropLast(2)) ?? 0 : 0
            let scale = properties["font-size"]?.hasSuffix("em") == true ? Double(properties["font-size"]!.dropLast(2)) ?? 1 : (heading > 0 ? 1.45 : 1)
            spans.append(StyleSpan(offset: start, length: offset - start, bold: isBold, italic: isItalic, heading: heading, alignment: properties["text-align"], indent: indentation, scale: min(1.65, max(0.8, scale)), block: block, quote: node.name == "blockquote" || (node.attributes["class"] ?? "").contains("extract")))
        }
    }
}
enum ImportFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
enum EPUBImporter {
    static func load(_ url: URL) throws -> Book {
        let archive = try Archive(url: url, accessMode: .read)
        var consumed = 0
        func data(_ path: String) throws -> Data {
            guard !path.hasPrefix("/"), !path.components(separatedBy: "/").contains(".."), let entry = archive[path] else { throw ImportFailure.invalid("A required EPUB resource is missing: \(path)") }
            guard entry.uncompressedSize < 40_000_000 else { throw ImportFailure.invalid("This EPUB resource is too large.") }
            var output = Data()
            _ = try archive.extract(entry) { chunk in
                consumed += chunk.count
                guard consumed < 150_000_000 else { throw ImportFailure.invalid("This EPUB is too large to import safely.") }
                output.append(chunk)
            }
            return output
        }
        guard String(data: try data("mimetype"), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else { throw ImportFailure.invalid("Choose a valid DRM-free EPUB file.") }
        if archive["META-INF/encryption.xml"] != nil {
            let encryption = try XMLReader.parse(data("META-INF/encryption.xml"))
            let algorithms = encryption.nodes.filter { $0.name == "encryptionmethod" }.compactMap { $0.attributes["Algorithm"] }
            guard algorithms.allSatisfy({ $0 == "http://www.idpf.org/2008/embedding" || $0 == "http://ns.adobe.com/pdf/enc#RC" }) else { throw ImportFailure.invalid("This EPUB is protected by DRM. Follow opens DRM-free books only.") }
        }
        let container = try XMLReader.parse(data("META-INF/container.xml"))
        guard let opfPath = container.nodes.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else { throw ImportFailure.invalid("The EPUB has no package document.") }
        let package = try XMLReader.parse(data(opfPath))
        let base = (opfPath as NSString).deletingLastPathComponent
        func resolve(_ href: String, base: String) -> String {
            let decoded = href.removingPercentEncoding ?? href
            let rooted = URL(fileURLWithPath: "/" + base).appendingPathComponent(decoded).standardized.path
            return String(rooted.dropFirst())
        }
        let items = package.nodes.filter { $0.name == "item" }
        let metadata = { (name: String) in package.nodes.first(where: { $0.name == name })?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let css = try items.filter { $0.attributes["media-type"] == "text/css" }.compactMap { item -> String? in
            guard let href = item.attributes["href"] else { return nil }
            return String(data: try data(resolve(href, base: base)), encoding: .utf8)
        }.joined(separator: "\n")
        let sheet = StyleSheet(css)
        var chapters: [Chapter] = []
        var bodyStart: Location?

        for ref in package.nodes.filter({ $0.name == "itemref" && $0.attributes["linear"] != "no" }) {
            guard let item = items.first(where: { $0.attributes["id"] == ref.attributes["idref"] }), let href = item.attributes["href"] else { continue }
            guard item.attributes["media-type"] == "application/xhtml+xml" else { throw ImportFailure.invalid("This book uses a spine format that Follow does not support.") }
            let path = resolve(href, base: base)
            let document = try XMLReader.parse(data(path))
            guard let body = document.nodes.first(where: { $0.name == "body" }) else { continue }
            // Navigation remains in the contents sheet, not the narration spine.
            if (item.attributes["properties"] ?? "").split(separator: " ").contains("nav") { continue }
            let renderer = ChapterRenderer(sheet: sheet) { href in try data(resolve(href, base: (path as NSString).deletingLastPathComponent)) }
            try renderer.render(body)
            if renderer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if bodyStart == nil && body.types("bodymatter") { bodyStart = Location(chapter: chapters.count) }
            let title = document.nodes.first(where: { $0.name == "section" && $0.attributes["title"] != nil })?.attributes["title"] ?? document.nodes.first(where: { ["h1", "h2"].contains($0.name) })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Chapter \(chapters.count + 1)"
            chapters.append(Chapter(id: path, title: title, text: renderer.text, anchors: renderer.anchors, spans: renderer.spans, images: renderer.images))
        }
        guard !chapters.isEmpty else { throw ImportFailure.invalid("This EPUB has no readable text. Image-only and fixed-layout books are not supported.") }
        if package.nodes.contains(where: { $0.name == "meta" && $0.attributes["property"] == "rendition:layout" && $0.text == "pre-paginated" }) { throw ImportFailure.invalid("Follow currently supports reflowable EPUBs. Fixed-layout books are not supported.") }
        var contents: [ContentsEntry] = []
        if let nav = items.first(where: { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }), let href = nav.attributes["href"] {
            let path = resolve(href, base: base)
            let document = try XMLReader.parse(data(path))
            for link in (document.nodes.first(where: { $0.name == "nav" && $0.types("toc") })?.descendants ?? document.nodes).filter({ $0.name == "a" }) {
                guard let href = link.attributes["href"] else { continue }
                let parts = href.components(separatedBy: "#")
                let target = parts[0].isEmpty ? path : resolve(parts[0], base: (path as NSString).deletingLastPathComponent)
                guard let index = chapters.firstIndex(where: { $0.id == target }) else { continue }
                let offset = parts.count > 1 ? chapters[index].anchors[parts[1].removingPercentEncoding ?? parts[1]] ?? 0 : 0
                contents.append(ContentsEntry(id: "\(contents.count)", title: link.text.trimmingCharacters(in: .whitespacesAndNewlines), location: Location(chapter: index, offset: offset)))
            }
        } else if let ncx = items.first(where: { $0.attributes["media-type"] == "application/x-dtbncx+xml" }), let href = ncx.attributes["href"] {
            let path = resolve(href, base: base)
            let document = try XMLReader.parse(data(path))
            let labels = document.nodes.filter { $0.name == "navlabel" }
            let targets = document.nodes.filter { $0.name == "content" }
            for (label, target) in zip(labels, targets) {
                guard let src = target.attributes["src"] else { continue }
                let parts = src.components(separatedBy: "#")
                let resource = resolve(parts[0], base: (path as NSString).deletingLastPathComponent)
                guard let index = chapters.firstIndex(where: { $0.id == resource }) else { continue }
                contents.append(ContentsEntry(id: "\(contents.count)", title: label.text.trimmingCharacters(in: .whitespacesAndNewlines), location: Location(chapter: index, offset: parts.count > 1 ? chapters[index].anchors[parts[1]] ?? 0 : 0)))
            }
        }
        for entry in contents {
            if entry.location.offset == 0 || chapters[entry.location.chapter].title.hasPrefix("Chapter ") { chapters[entry.location.chapter].title = entry.title }
        }
        if contents.isEmpty { contents = chapters.enumerated().map { ContentsEntry(id: "\($0.offset)", title: $0.element.title, location: Location(chapter: $0.offset)) } }
        let legacyCover = package.nodes.first(where: { $0.name == "meta" && $0.attributes["name"] == "cover" })?.attributes["content"]
        let coverItem = items.first { ($0.attributes["properties"] ?? "").contains("cover-image") || (legacyCover != nil && $0.attributes["id"] == legacyCover) }
        let cover = try coverItem?.attributes["href"].map { try data(resolve($0, base: base)) }
        return Book(id: UUID(), title: metadata("title") ?? url.deletingPathExtension().lastPathComponent, author: metadata("creator") ?? "Unknown author", language: metadata("language") ?? "en-US", cover: cover, chapters: chapters, contents: contents, location: bodyStart ?? Location(), parserVersion: 2)
    }
}
