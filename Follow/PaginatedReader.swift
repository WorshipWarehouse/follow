import SwiftUI
import UIKit

struct ReaderPalette {
    let paper: UIColor
    let ink: UIColor
    let dark: Bool
    init(settings: ReaderSettings, systemDark: Bool) {
        dark = settings.theme == "Dark" || settings.theme == "Dusk" || (settings.theme == "System" && systemDark)
        switch settings.theme {
        case "Sepia": paper = UIColor(red: 0.96, green: 0.92, blue: 0.82, alpha: 1)
        case "Mist": paper = UIColor(red: 0.90, green: 0.93, blue: 0.93, alpha: 1)
        case "Dusk": paper = UIColor(red: 0.18, green: 0.19, blue: 0.21, alpha: 1)
        default: paper = dark ? UIColor(white: 0.09, alpha: 1) : UIColor(red: 0.99, green: 0.98, blue: 0.96, alpha: 1)
        }
        ink = dark ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.16, alpha: 1)
    }
}

@MainActor final class PageLayout {
    let text: NSAttributedString
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let size: CGSize
    var ranges: [NSRange] = []
    var glyphRanges: [NSRange] = []
    var containers: [NSTextContainer] = []
    var highlightedRange: NSRange?

    init(chapter: Chapter, size: CGSize, settings: ReaderSettings, color: UIColor) {
        self.size = CGSize(width: max(40, size.width), height: max(60, size.height))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = settings.spacing
        paragraph.paragraphSpacing = settings.paragraphSpacing
        paragraph.alignment = settings.justified ? .justified : .natural
        var font = UIFont(name: settings.font, size: settings.size) ?? UIFont.systemFont(ofSize: settings.size)
        if settings.boldText, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) { font = UIFont(descriptor: descriptor, size: settings.size) }
        let attributed = NSMutableAttributedString(string: chapter.text, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: color, .kern: settings.characterSpacing])
        if settings.wordSpacing > 0 {
            let ns = chapter.text as NSString
            var offset = 0
            while offset < ns.length {
                let range = ns.range(of: " ", range: NSRange(location: offset, length: ns.length - offset))
                guard range.location != NSNotFound else { break }
                attributed.addAttribute(.kern, value: settings.characterSpacing + settings.wordSpacing, range: range)
                offset = NSMaxRange(range)
            }
        }
        // Ancestors are applied first; nested semantic styles refine their ranges.
        for span in (chapter.spans ?? []).reversed() {
            let range = NSIntersectionRange(NSRange(location: span.offset, length: span.length), NSRange(location: 0, length: attributed.length))
            guard range.length > 0 else { continue }
            if span.scale != 1 || span.heading > 0 {
                attributed.addAttribute(.font, value: font.withSize(settings.size * span.scale), range: range)
            }
            if span.bold || span.italic || span.heading > 0 {
                attributed.enumerateAttribute(.font, in: range) { value, local, _ in
                    guard let current = value as? UIFont else { return }
                    var traits = current.fontDescriptor.symbolicTraits
                    if span.bold || span.heading > 0 { traits.insert(.traitBold) }
                    if span.italic { traits.insert(.traitItalic) }
                    if let descriptor = current.fontDescriptor.withSymbolicTraits(traits) { attributed.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: local) }
                }
            }
            if span.block {
                let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
                switch span.alignment {
                case "center": style.alignment = .center
                case "right": style.alignment = .right
                default: style.alignment = settings.justified ? .justified : .natural
                }
                style.firstLineHeadIndent = min(self.size.width * 0.12, max(0, span.indent * settings.size))
                if span.quote { style.headIndent = 16; style.tailIndent = -16; style.firstLineHeadIndent += 16 }
                if span.heading > 0 { style.paragraphSpacing = settings.spacing + 12 }
                attributed.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        for illustration in chapter.images ?? [] {
            guard illustration.offset < attributed.length, let image = UIImage(data: illustration.data) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            let scale = min(self.size.width / max(1, image.size.width), (self.size.height * 0.72) / max(1, image.size.height))
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            attributed.addAttribute(.attachment, value: attachment, range: NSRange(location: illustration.offset, length: 1))
            let centered = paragraph.mutableCopy() as! NSMutableParagraphStyle
            centered.alignment = .center
            attributed.addAttribute(.paragraphStyle, value: centered, range: (chapter.text as NSString).paragraphRange(for: NSRange(location: illustration.offset, length: 1)))
        }
        text = attributed
        storage = NSTextStorage(attributedString: attributed)
        manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        var cursor = 0
        while cursor < storage.length {
            let container = NSTextContainer(size: self.size)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(for: container)
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard chars.length > 0, NSMaxRange(chars) > cursor else { break }
            containers.append(container)
            ranges.append(chars)
            glyphRanges.append(glyphs)
            cursor = NSMaxRange(chars)
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: 0)]; glyphRanges = ranges }
    }
    func page(at offset: Int) -> Int { ranges.firstIndex(where: { NSMaxRange($0) > offset }) ?? max(0, ranges.count - 1) }
    func highlight(_ range: NSRange?) {
        highlightedRange = range
    }
}

struct PageAddress: Equatable, Comparable {
    var chapter: Int
    var page: Int
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.chapter == rhs.chapter ? lhs.page < rhs.page : lhs.chapter < rhs.chapter }
}
@MainActor final class ReaderDocument {
    let book: Book
    let size: CGSize
    let settings: ReaderSettings
    let color: UIColor
    let paper: UIColor
    private var layouts: [Int: PageLayout] = [:]
    init(book: Book, size: CGSize, settings: ReaderSettings, color: UIColor, paper: UIColor) {
        self.book = book; self.size = size; self.settings = settings; self.color = color; self.paper = paper
    }
    func layout(_ chapter: Int) -> PageLayout {
        if let layout = layouts[chapter] { return layout }
        let layout = PageLayout(chapter: book.chapters[chapter], size: CGSize(width: size.width - settings.margin * 2, height: size.height - 44), settings: settings, color: color)
        layouts[chapter] = layout
        return layout
    }
    func address(_ location: Location) -> PageAddress { PageAddress(chapter: location.chapter, page: layout(location.chapter).page(at: location.offset)) }
    func location(_ address: PageAddress) -> Location { Location(chapter: address.chapter, offset: layout(address.chapter).ranges[address.page].location) }
    func adjacent(_ address: PageAddress, direction: Int) -> PageAddress? {
        let next = address.page + direction
        if layout(address.chapter).ranges.indices.contains(next) { return PageAddress(chapter: address.chapter, page: next) }
        let chapter = address.chapter + direction
        guard book.chapters.indices.contains(chapter) else { return nil }
        return PageAddress(chapter: chapter, page: direction > 0 ? 0 : layout(chapter).ranges.count - 1)
    }
}
@MainActor final class PageCache: ObservableObject {
    private var key = ""
    private var document: ReaderDocument?
    func pageStart(_ location: Location) -> Location { document.map { $0.location($0.address(location)) } ?? location }
    func getDocument(book: Book, size: CGSize, settings: ReaderSettings, color: UIColor, paper: UIColor) -> ReaderDocument {
        let newKey = "\(book.id)|\(book.parserVersion ?? 0)|\(size)|\(settings.font)|\(settings.size)|\(settings.spacing)|\(settings.margin)|\(settings.theme)|\(settings.boldText)|\(settings.justified)|\(settings.characterSpacing)|\(settings.wordSpacing)|\(settings.paragraphSpacing)|\(color.description)|\(paper.description)"
        if key != newKey || document == nil { document = ReaderDocument(book: book, size: size, settings: settings, color: color, paper: paper); key = newKey }
        return document!
    }
}
extension HighlightColor {
    var uiColor: UIColor {
        switch self { case .yellow: return .systemYellow; case .green: return .systemGreen; case .blue: return .systemBlue; case .pink: return .systemPink; case .purple: return .systemPurple; case .orange: return .systemOrange }
    }
}
@MainActor final class PageCanvas: UIView, @preconcurrency UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    let layout: PageLayout
    let index: Int
    let chapter: Chapter
    var settings = ReaderSettings()
    var marks: [BookAnnotation] = []
    var focusOffset = 0
    var selectedRange: NSRange?
    var guideRect: CGRect?
    var saveSelection: ((NSRange, HighlightColor) -> Void)?
    var readSelection: ((Int) -> Void)?
    private var selectionAnchor: NSRange?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    init(layout: PageLayout, index: Int, chapter: Chapter) {
        self.layout = layout; self.index = index; self.chapter = chapter
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = layout.text.attributedSubstring(from: layout.ranges[index]).string.replacingOccurrences(of: "\u{FFFC}", with: "Illustration")
        addInteraction(editMenu)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(selectPassage(_:)))
        hold.minimumPressDuration = 0.45
        addGestureRecognizer(hold)
        let guide = UIPanGestureRecognizer(target: self, action: #selector(moveGuide(_:)))
        guide.delegate = self
        guide.require(toFail: hold)
        addGestureRecognizer(guide)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(settings: ReaderSettings, marks: [BookAnnotation], focusOffset: Int) {
        let moved = self.focusOffset != focusOffset
        self.settings = settings; self.marks = marks; self.focusOffset = focusOffset
        if guideRect == nil || moved { guideRect = line(at: focusOffset) }
        setNeedsDisplay()
    }
    private func line(at offset: Int) -> CGRect? {
        guard layout.containers.indices.contains(index), layout.ranges[index].length > 0 else { return nil }
        let offset = min(max(layout.ranges[index].location, offset), NSMaxRange(layout.ranges[index]) - 1)
        let glyph = layout.manager.glyphIndexForCharacter(at: offset)
        let rect = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return CGRect(x: 0, y: max(0, rect.minY - 2), width: layout.size.width, height: rect.height + 4)
    }
    private func character(at point: CGPoint) -> Int? {
        guard layout.containers.indices.contains(index), layout.ranges[index].length > 0 else { return nil }
        let glyph = layout.manager.glyphIndex(for: point, in: layout.containers[index], fractionOfDistanceThroughGlyph: nil)
        guard NSLocationInRange(glyph, layout.glyphRanges[index]) else { return nil }
        return layout.manager.characterIndexForGlyph(at: glyph)
    }
    private func word(at offset: Int) -> NSRange {
        let ns = chapter.text as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: offset, length: 0))
        let value = ns.substring(with: paragraph)
        var result = ns.rangeOfComposedCharacterSequence(at: offset)
        value.enumerateSubstrings(in: value.startIndex..<value.endIndex, options: .byWords) { _, range, _, stop in
            let r = NSRange(range, in: value)
            let absolute = NSRange(location: paragraph.location + r.location, length: r.length)
            if NSLocationInRange(offset, absolute) { result = absolute; stop = true }
        }
        return result
    }
    @objc private func selectPassage(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let offset = character(at: point) else { return }
        switch gesture.state {
        case .began:
            editMenu.dismissMenu()
            selectionAnchor = word(at: offset)
            selectedRange = selectionAnchor
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            if let anchor = selectionAnchor {
                let end = word(at: offset)
                let start = min(anchor.location, end.location)
                selectedRange = NSRange(location: start, length: max(NSMaxRange(anchor), NSMaxRange(end)) - start)
            }
        case .ended:
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        case .cancelled: selectedRange = nil
        default: break
        }
        setNeedsDisplay()
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let range = selectedRange else { return nil }
        let colors = HighlightColor.allCases.map { color in
            UIAction(title: color.rawValue, image: UIImage(systemName: "circle.fill")?.withTintColor(color.uiColor, renderingMode: .alwaysOriginal)) { [weak self] _ in self?.save(range, color: color) }
        }
        return UIMenu(children: [
            UIAction(title: "Save Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in guard let self else { return }; self.save(range, color: self.settings.savedHighlightColor) },
            UIMenu(title: "Highlight Color", children: colors),
            UIAction(title: "Select Sentence") { [weak self] _ in
                guard let self else { return }; self.selectedRange = NSIntersectionRange(self.chapter.sentence(at: range.location), self.layout.ranges[self.index]); self.setNeedsDisplay()
                self.editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: configuration.sourcePoint))
            },
            UIAction(title: "Read From Here", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in self?.readSelection?(range.location); self?.selectedRange = nil; self?.setNeedsDisplay() },
            UIAction(title: "Copy") { [weak self] _ in guard let self else { return }; UIPasteboard.general.string = (self.chapter.text as NSString).substring(with: range) }
        ] + suggestedActions)
    }
    private func save(_ range: NSRange, color: HighlightColor) {
        saveSelection?(range, color); selectedRange = nil; setNeedsDisplay()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard settings.lineGuide else { return false }
        let velocity = pan.velocity(in: self)
        return abs(velocity.y) > abs(velocity.x)
    }
    @objc private func moveGuide(_ gesture: UIPanGestureRecognizer) {
        guard let offset = character(at: gesture.location(in: self)) else { return }
        guideRect = line(at: offset); setNeedsDisplay()
    }
    private func paint(_ range: NSRange, color: UIColor) {
        guard layout.containers.indices.contains(index) else { return }
        let visible = NSIntersectionRange(range, layout.ranges[index])
        guard visible.length > 0 else { return }
        let glyphs = layout.manager.glyphRange(forCharacterRange: visible, actualCharacterRange: nil)
        color.setFill()
        layout.manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: layout.containers[index]) { rect, _ in
            UIBezierPath(roundedRect: rect, cornerRadius: 3).fill()
        }
    }
    override func draw(_ rect: CGRect) {
        let glyphs = layout.glyphRanges[index]
        layout.manager.drawBackground(forGlyphRange: glyphs, at: .zero)
        if settings.showSavedHighlights {
            for mark in marks where !mark.bookmark { paint(NSRange(location: mark.location.offset, length: mark.length), color: mark.color.uiColor.withAlphaComponent(0.24)) }
        }
        if settings.narrationHighlight, let highlight = layout.highlightedRange { paint(highlight, color: settings.highlightColor.uiColor.withAlphaComponent(settings.highlightOpacity)) }
        if let selectedRange { paint(selectedRange, color: UIColor.systemBlue.withAlphaComponent(0.22)) }
        guard settings.lineGuide, let guide = guideRect, let context = UIGraphicsGetCurrentContext() else {
            layout.manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            return
        }
        // Fade glyphs, never the paper or highlight backgrounds. Attachments retain full opacity.
        layout.text.enumerateAttribute(.attachment, in: layout.ranges[index]) { attachment, range, _ in
            let segment = layout.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if attachment != nil {
                layout.manager.drawGlyphs(forGlyphRange: segment, at: .zero)
            } else {
                context.saveGState()
                let outside = CGMutablePath()
                outside.addRect(CGRect(x: 0, y: 0, width: bounds.width, height: max(0, guide.minY)))
                outside.addRect(CGRect(x: 0, y: guide.maxY, width: bounds.width, height: max(0, bounds.height - guide.maxY)))
                context.addPath(outside); context.clip()
                context.setAlpha(1 - settings.guideDimming.opacity)
                layout.manager.drawGlyphs(forGlyphRange: segment, at: .zero)
                context.restoreGState()
                context.saveGState(); context.clip(to: guide)
                layout.manager.drawGlyphs(forGlyphRange: segment, at: .zero)
                context.restoreGState()
            }
        }
        settings.highlightColor.uiColor.withAlphaComponent(0.45).setStroke()
        let edge = UIBezierPath(); edge.move(to: CGPoint(x: 0, y: guide.maxY)); edge.addLine(to: CGPoint(x: bounds.width, y: guide.maxY)); edge.lineWidth = 1; edge.stroke()
    }
}
@MainActor final class BookPageController: UIViewController {
    let document: ReaderDocument
    let address: PageAddress
    let canvas: PageCanvas
    let footer = UILabel()
    init(document: ReaderDocument, address: PageAddress) {
        self.document = document; self.address = address
        canvas = PageCanvas(layout: document.layout(address.chapter), index: address.page, chapter: document.book.chapters[address.chapter])
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = document.paper
        view.clipsToBounds = true
        view.isOpaque = true
        view.addSubview(canvas)
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = document.color.withAlphaComponent(0.6)
        footer.textAlignment = .center
        footer.lineBreakMode = .byTruncatingMiddle
        footer.text = "\(document.book.chapters[address.chapter].title) · \(address.page + 1) / \(document.layout(address.chapter).ranges.count)"
        view.addSubview(footer)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Drawing uses exactly the same width and height used for measurement.
        canvas.frame = CGRect(x: document.settings.margin, y: 12, width: document.layout(address.chapter).size.width, height: document.layout(address.chapter).size.height)
        footer.frame = CGRect(x: 24, y: view.bounds.height - 25, width: max(0, view.bounds.width - 48), height: 18)
    }
}
// A segmented sheet gives every reverse face an explicit paper color. This avoids
// UIKit's implicit white backing and double-sided controller inconsistencies.
@MainActor final class CurlSheet: UIView {
    let paper: UIColor
    let strips: [CALayer]
    let reverseFaces: [CALayer]
    private let stripWidth: CGFloat
    init(image: UIImage, paper: UIColor, size: CGSize) {
        self.paper = paper
        let count = 64
        stripWidth = size.width / CGFloat(count)
        var strips: [CALayer] = [], backs: [CALayer] = []
        for index in 0..<count {
            let strip = CALayer()
            strip.bounds = CGRect(x: 0, y: 0, width: stripWidth + 0.5, height: size.height)
            strip.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let front = CALayer(); front.frame = strip.bounds
            front.contents = image.cgImage
            front.contentsRect = CGRect(x: CGFloat(index) / CGFloat(count), y: 0, width: 1 / CGFloat(count), height: 1)
            front.isDoubleSided = false
            let back = CALayer(); back.frame = strip.bounds
            back.backgroundColor = paper.cgColor
            back.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            back.isDoubleSided = false
            strip.addSublayer(front); strip.addSublayer(back)
            strips.append(strip); backs.append(back)
        }
        self.strips = strips; reverseFaces = backs
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .clear; isUserInteractionEnabled = false
        for strip in strips { layer.addSublayer(strip) }
        update(progress: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(progress: CGFloat) {
        let progress = min(1, max(0, progress))
        let radius = min(65, bounds.width * 0.14)
        let fold = bounds.width - progress * (bounds.width * 1.5 + radius)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, strip) in strips.enumerated() {
            let originalX = (CGFloat(index) + 0.5) * stripWidth
            let distance = max(0, originalX - fold)
            let angle = min(.pi, distance / max(1, radius))
            let x: CGFloat, z: CGFloat
            if distance == 0 { x = originalX; z = 0 }
            else if distance < .pi * radius { x = fold + radius * sin(angle); z = radius * (1 - cos(angle)) }
            else { x = fold - (distance - .pi * radius); z = radius * 2 }
            strip.position = CGPoint(x: x, y: bounds.midY)
            var transform = CATransform3DIdentity
            transform.m34 = -1 / max(1, bounds.width * 4)
            transform = CATransform3DTranslate(transform, 0, 0, z)
            transform = CATransform3DRotate(transform, -angle, 0, 1, 0)
            strip.transform = transform
            strip.zPosition = z
        }
        CATransaction.commit()
    }
}
@MainActor final class PageTurnController: UIViewController {
    private(set) var current: BookPageController?
    private var displayLink: CADisplayLink?
    private var sheet: CurlSheet?
    private var started: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var finishing: (() -> Void)?
    private var reverse = false
    var navigate: ((Int) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad(); view.clipsToBounds = true
        let next = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:))); next.direction = .left
        let previous = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:))); previous.direction = .right
        view.addGestureRecognizer(next); view.addGestureRecognizer(previous)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:))); tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for child in children { child.view.frame = view.bounds }
    }
    func present(_ page: BookPageController, style: PageTurnStyle, direction: Int, animated: Bool, completion: @escaping () -> Void) {
        loadViewIfNeeded()
        let old = current
        view.backgroundColor = page.document.paper
        addChild(page); page.view.frame = view.bounds
        view.addSubview(page.view); page.didMove(toParent: self); page.view.layoutIfNeeded()
        current = page
        let finish = { [weak self, weak old, weak page] in
            old?.willMove(toParent: nil); old?.view.removeFromSuperview(); old?.removeFromParent()
            page?.view.alpha = 1; page?.view.isHidden = false; page?.view.transform = .identity
            self?.sheet?.removeFromSuperview(); self?.sheet = nil
            completion()
        }
        guard animated, style != .none, !UIAccessibility.isReduceMotionEnabled, let old, view.bounds.width > 0 else { finish(); return }
        switch style {
        case .curl:
            reverse = direction < 0
            let source = reverse ? page : old
            let format = UIGraphicsImageRendererFormat(); format.opaque = true
            let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
                source.document.paper.setFill(); context.fill(view.bounds)
                source.view.layer.render(in: context.cgContext)
            }
            if reverse { page.view.isHidden = true }
            else { old.view.isHidden = true }
            let sheet = CurlSheet(image: image, paper: page.document.paper, size: view.bounds.size)
            self.sheet = sheet; view.addSubview(sheet); sheet.update(progress: reverse ? 1 : 0)
            finishing = finish
            started = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        case .slide:
            let width = view.bounds.width * CGFloat(direction)
            page.view.transform = CGAffineTransform(translationX: width, y: 0)
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: {
                page.view.transform = .identity; old.view.transform = CGAffineTransform(translationX: -width, y: 0)
            }) { _ in finish() }
        case .fade:
            page.view.alpha = 0
            UIView.animate(withDuration: 0.22, animations: { page.view.alpha = 1 }) { _ in finish() }
        case .none: finish()
        }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let progress = min(1, (CACurrentMediaTime() - started) / 0.45)
        let eased = CGFloat(progress * progress * (3 - 2 * progress))
        sheet?.update(progress: reverse ? 1 - eased : eased)
        if progress >= 1 { displayLink?.invalidate(); displayLink = nil; let finish = finishing; finishing = nil; finish?() }
    }
    func cancelAnimation() {
        displayLink?.invalidate(); displayLink = nil
        let finish = finishing; finishing = nil; finish?()
    }
    @objc private func swipe(_ gesture: UISwipeGestureRecognizer) { navigate?(gesture.direction == .left ? 1 : -1) }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: view).x
        if x < view.bounds.width * 0.2 { navigate?(-1) }
        else if x > view.bounds.width * 0.8 { navigate?(1) }
    }
}
struct TurningReader: UIViewControllerRepresentable {
    let document: ReaderDocument
    let location: Location
    let highlight: NSRange?
    let settings: ReaderSettings
    let marks: [BookAnnotation]
    let saveHighlight: (Location, NSRange, HighlightColor) -> Void
    let readFrom: (Location) -> Void
    let navigate: (Location) -> Void
    var turnStyle: PageTurnStyle { UIAccessibility.isReduceMotionEnabled ? .none : settings.pageTurn }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PageTurnController {
        let controller = PageTurnController()
        context.coordinator.controller = controller
        controller.navigate = { [weak coordinator = context.coordinator] direction in coordinator?.manualTurn(direction) }
        document.layout(location.chapter).highlight(highlight)
        controller.present(context.coordinator.page(document.address(location)), style: turnStyle, direction: 1, animated: false, completion: {})
        return controller
    }
    func updateUIViewController(_ controller: PageTurnController, context: Context) {
        let coordinator = context.coordinator
        let replaced = coordinator.parent.document !== document
        coordinator.parent = self
        document.layout(location.chapter).highlight(highlight)
        guard !coordinator.transitioning else { return }
        let address = document.address(location)
        if let current = controller.current, current.address == address && !replaced { coordinator.configure(current) }
        else { coordinator.show(address, animated: !replaced) }
    }
    static func dismantleUIViewController(_ controller: PageTurnController, coordinator: Coordinator) {
        controller.navigate = nil; controller.cancelAnimation()
    }
    @MainActor final class Coordinator: NSObject {
        var parent: TurningReader
        weak var controller: PageTurnController?
        var transitioning = false
        init(_ parent: TurningReader) { self.parent = parent }
        func page(_ address: PageAddress) -> BookPageController {
            let page = BookPageController(document: parent.document, address: address)
            configure(page); return page
        }
        func configure(_ page: BookPageController) {
            let chapter = page.address.chapter
            page.canvas.update(settings: parent.settings, marks: parent.marks.filter { $0.location.chapter == chapter }, focusOffset: parent.location.chapter == chapter ? parent.location.offset : parent.document.location(page.address).offset)
            page.canvas.saveSelection = { [weak self] range, color in self?.parent.saveHighlight(Location(chapter: chapter, offset: range.location), range, color) }
            page.canvas.readSelection = { [weak self] offset in self?.parent.readFrom(Location(chapter: chapter, offset: offset)) }
        }
        func show(_ address: PageAddress, animated: Bool) {
            guard let controller, !transitioning else { return }
            let direction = controller.current.map { address < $0.address ? -1 : 1 } ?? 1
            transitioning = true
            controller.present(page(address), style: parent.turnStyle, direction: direction, animated: animated) { [weak self] in
                guard let self else { return }; self.transitioning = false; self.reconcile()
            }
        }
        func manualTurn(_ direction: Int) {
            guard !transitioning, let current = controller?.current, let next = parent.document.adjacent(current.address, direction: direction) else { return }
            parent.navigate(parent.document.location(next))
        }
        func reconcile() {
            guard let current = controller?.current else { return }
            let desired = parent.document.address(parent.location)
            if current.address != desired || current.document !== parent.document { show(desired, animated: false) }
            else { configure(current) }
        }
    }
}
