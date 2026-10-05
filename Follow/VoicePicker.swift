import SwiftUI
import AVFoundation
import UIKit

@MainActor final class VoiceCatalog: ObservableObject {
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []
    init() { refresh() }
    func refresh() {
        voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.quality.rawValue > $1.quality.rawValue
        }
    }
    func matching(query: String, language: String) -> [AVSpeechSynthesisVoice] {
        voices.filter { voice in
            (language == "all" || voice.language.components(separatedBy: "-").first == language) &&
            (query.isEmpty || "\(voice.name) \(voice.language) \(Self.languageName(voice.language)) \(Self.qualityName(voice))".localizedCaseInsensitiveContains(query))
        }
    }
    static func qualityName(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality { case .premium: return "Premium"; case .enhanced: return "Enhanced"; default: return "Standard" }
    }
    static func languageName(_ language: String) -> String { Locale.current.localizedString(forIdentifier: language) ?? language }
    var languages: [String] { Array(Set(voices.map { $0.language.components(separatedBy: "-").first ?? $0.language })).sorted { Self.languageName($0) < Self.languageName($1) } }
}
@MainActor final class VoicePreview: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var identifier: String?
    @Published var error: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    override init() { super.init(); synthesizer.delegate = self }
    func preview(_ voice: AVSpeechSynthesisVoice, narrator: Narrator) {
        if identifier == voice.identifier { stop(); return }
        stop(); narrator.pause()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = error.localizedDescription; return }
        let sample = AVSpeechUtterance(string: "Hello. This is \(voice.name), reading a short preview of this voice.")
        sample.voice = voice; current = sample; identifier = voice.identifier
        synthesizer.speak(sample)
    }
    func stop() { current = nil; synthesizer.stopSpeaking(at: .immediate); identifier = nil }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in guard let self, self.current === utterance else { return }; self.current = nil; self.identifier = nil }
    }
}
struct VoicePickerView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.scenePhase) var phase
    @StateObject private var catalog = VoiceCatalog()
    @StateObject private var preview = VoicePreview()
    @State private var query = ""
    @State private var language = "all"
    private var filtered: [AVSpeechSynthesisVoice] { catalog.matching(query: query, language: language) }
    var body: some View {
        List {
            Section {
                choice("Automatic · book language", detail: "Follow selects an available voice for the book’s language.", id: "")
                choice("Device spoken voice", detail: "Uses Apple’s device preference. A Siri preference is replaced by Apple’s fallback voice.", id: "system")
            }
            Section {
                Picker("Language", selection: $language) {
                    Text("All languages").tag("all")
                    ForEach(catalog.languages, id: \.self) { Text(VoiceCatalog.languageName($0)).tag($0) }
                }
                Button("Refresh available voices", systemImage: "arrow.clockwise") { catalog.refresh() }
            } footer: { Text("Download additional voices in iPhone Settings → Accessibility → Read & Speak → Voices (Spoken Content on older iOS versions), then return here. The list refreshes automatically.") }
            Section("\(filtered.count) available voices") {
                ForEach(filtered, id: \.identifier) { voice in
                    HStack(spacing: 12) {
                        Button { select(voice.identifier) } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(voice.name).font(.body).foregroundStyle(.primary)
                                    Text("\(VoiceCatalog.languageName(voice.language)) · \(VoiceCatalog.qualityName(voice))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                if library.settings.voice == voice.identifier { Image(systemName: "checkmark").foregroundStyle(.brown) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.borderless)
                        Button { preview.preview(voice, narrator: narrator) } label: {
                            Image(systemName: preview.identifier == voice.identifier ? "stop.circle.fill" : "speaker.wave.2").frame(width: 44, height: 44)
                        }.buttonStyle(.borderless).accessibilityLabel(preview.identifier == voice.identifier ? "Stop voice preview" : "Preview \(voice.name), \(VoiceCatalog.qualityName(voice))")
                    }
                }
                if filtered.isEmpty { Text("No voices match. Try another language or clear your search.").foregroundStyle(.secondary) }
            }
            Section("Siri Voice 3") {
                NavigationLink("Open Apple Accessibility Reader") { AccessibilityReadingView() }
                Text("Apple makes Siri voices available to its accessibility reader, but does not expose them to apps such as Follow. Installing or selecting Siri Voice 3 in Settings will not add it to this list.")
                Text("To hear Siri Voice 3, use Apple’s Speak Screen with your preferred accessibility voice. Follow’s own playback and synchronized highlighting use the available voices listed above.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Choose a Voice").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Name, language, or quality")
            .onAppear { catalog.refresh() }
            .onChange(of: phase) { _, phase in if phase == .active { catalog.refresh() } else { preview.stop() } }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification).receive(on: RunLoop.main)) { _ in catalog.refresh() }
            .onDisappear { preview.stop() }
            .alert("Preview unavailable", isPresented: Binding(get: { preview.error != nil }, set: { if !$0 { preview.error = nil } })) { Button("OK") { preview.error = nil } } message: { Text(preview.error ?? "") }
    }
    private func select(_ id: String) {
        preview.stop(); library.settings.voice = id; narrator.settingsChanged()
    }
    private func choice(_ title: String, detail: String, id: String) -> some View {
        Button { select(id) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text(title).foregroundStyle(.primary); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer(); if library.settings.voice == id { Image(systemName: "checkmark") }
            }
        }.buttonStyle(.borderless)
    }
}

struct AccessibilityReadingView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.colorScheme) var colorScheme
    @State private var text = ""
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use your iPhone’s preferred accessibility voice").font(.headline)
                Text("With Speak Screen enabled in Settings → Accessibility → Read & Speak, swipe down from the top of the screen with two fingers. Choose Siri Voice 3 there to hear it in this view.").font(.footnote)
                Text("Starts from your current reading position. Apple controls playback; Follow’s highlights and saved position do not track this mode.").font(.caption).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            let palette = ReaderPalette(settings: library.settings, systemDark: colorScheme == .dark)
            AccessibilityBookText(text: text, settings: library.settings, paper: palette.paper, ink: palette.ink)
        }.navigationTitle("Apple Accessibility Reader").navigationBarTitleDisplayMode(.inline)
            .task {
                narrator.pause()
                if let book = narrator.book { text = Self.remainingText(book: book, location: narrator.location) }
            }
    }
    static func remainingText(book: Book, location: Location) -> String {
        guard book.chapters.indices.contains(location.chapter) else { return "" }
        let chapter = book.chapters[location.chapter]
        let ns = chapter.text as NSString
        var offset = min(max(0, location.offset), ns.length)
        if offset < ns.length { offset = ns.rangeOfComposedCharacterSequence(at: offset).location }
        return ([ns.substring(from: offset)] + book.chapters.dropFirst(location.chapter + 1).map(\.text)).joined(separator: "\n\n").replacingOccurrences(of: "\u{FFFC}", with: "Illustration")
    }
}
struct AccessibilityBookText: UIViewRepresentable {
    let text: String
    let settings: ReaderSettings
    let paper: UIColor
    let ink: UIColor
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 32, right: 20)
        view.adjustsFontForContentSizeCategory = true
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        view.backgroundColor = paper
        guard view.text != text || view.textColor != ink else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = settings.spacing; paragraph.paragraphSpacing = settings.paragraphSpacing
        let font = UIFont(name: settings.font, size: settings.size) ?? .systemFont(ofSize: settings.size)
        view.attributedText = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
        view.textColor = ink
    }
}
