import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

@main struct FollowApp: App {
    @StateObject private var library = Library()
    @StateObject private var narrator = Narrator()
    var body: some Scene {
        WindowGroup { LibraryView().environmentObject(library).environmentObject(narrator).tint(.brown) }
    }
}
struct CoverView: View {
    let book: Book
    var body: some View {
        Group {
            if let data = book.cover, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
            else {
                ZStack {
                    LinearGradient(colors: [.brown, .orange.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 18) {
                        Image(systemName: "book.closed").font(.largeTitle)
                        Text(book.title).font(.system(.title3, design: .serif)).multilineTextAlignment(.center)
                    }.foregroundStyle(.white).padding()
                }.aspectRatio(0.67, contentMode: .fit)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 8)).shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}
struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.scenePhase) var phase
    @State private var drainingInbox = false
    @State private var importHelp = false
    @State private var picker = false
    @State private var path: [UUID] = []
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if library.books.isEmpty {
                    VStack(spacing: 24) {
                        Image(systemName: "book.fill").symbolRenderingMode(.hierarchical).font(.system(size: 64)).foregroundStyle(.brown)
                        Text("Read and listen\nat the same time.").font(.system(size: 34, weight: .medium, design: .serif)).multilineTextAlignment(.center)
                        Text("Import an EPUB, press Play, and your iPhone reads while the book follows along.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Choose a Book", systemImage: "plus") { picker = true }.buttonStyle(.borderedProminent).controlSize(.large)
                        if let sample = Bundle.main.url(forResource: "Sample", withExtension: "epub") {
                            Button("Try a sample book") { Task { await importAndOpen(sample) } }.buttonStyle(.bordered).controlSize(.large)
                        }
                        Text("Your books stay on your device. No account needed.").font(.footnote).foregroundStyle(.secondary)
                    }.padding(32)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 28) {
                            ForEach(library.books) { book in
                                Button { narrator.open(book, library: library); path.append(book.id) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        CoverView(book: book).frame(height: 215).frame(maxWidth: .infinity)
                                        Text(book.title).font(.headline).lineLimit(2)
                                        Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        ProgressView(value: book.progress)
                                        Text("\(Int(book.progress * 100))% read").font(.caption2).foregroundStyle(.secondary)
                                    }.foregroundStyle(.primary)
                                }.buttonStyle(.plain)
                            }
                        }.padding(24)
                    }
                }
            }.navigationTitle("Library")
                 .toolbar { ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import help", systemImage: "questionmark.circle") { importHelp = true }
                    Button("Import book", systemImage: "plus") { picker = true }
                } }
                .navigationDestination(for: UUID.self) { id in
                    if let book = library.books.first(where: { $0.id == id }) { ReaderView().onAppear { narrator.open(book, library: library) } }
                }
                .overlay { if library.importing { ProgressView("Opening your book…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { for url in urls { await importAndOpen(url) } }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $importHelp) {
            NavigationStack {
                List {
                    Section("Add an EPUB") {
                        Text("Tap + and choose one or more EPUB files from Files, iCloud Drive, or Downloads.")
                        Text("You can also AirDrop an EPUB or use Open In → Follow when another app shares the actual file.")
                    }
                    Section("Apple Books") {
                        Text("Apple Books keeps its library private. Follow cannot automatically list or copy that library. A Share action may send only a store link, rather than an EPUB file.")
                        Text("For books you imported yourself, choose the original DRM-free EPUB in Files. Protected Apple Books purchases cannot be imported.")
                    }
                }.navigationTitle("Importing books").toolbar { Button("Done") { importHelp = false } }
            }
        }
        .onOpenURL { url in Task { await importAndOpen(url) } }
        .task { await drainInbox() }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await drainInbox() } } }
        .alert("Unable to open book", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("OK") { library.error = nil } } message: { Text(library.error ?? "") }
    }
    private func drainInbox() async {
        guard !drainingInbox else { return }
        drainingInbox = true
        defer { drainingInbox = false }
        for url in library.pendingSharedBooks() {
            if await importAndOpen(url) { library.consumeSharedBook(url) }
        }
    }
    @discardableResult private func importAndOpen(_ url: URL) async -> Bool {
        guard let id = await library.importBook(url), let book = library.books.first(where: { $0.id == id }) else { return false }
        narrator.open(book, library: library)
        path = [id]
        return true
    }
}
struct ReaderView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.colorScheme) var scheme
    @Environment(\.scenePhase) var phase
    @Environment(\.dismiss) var dismiss
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var menu = false
    @State private var bookmarkLocation = Location()
    @StateObject private var pageCache = PageCache()
    private var palette: ReaderPalette { ReaderPalette(settings: library.settings, systemDark: scheme == .dark) }
    private var dark: Bool { palette.dark }
    private var background: Color { Color(palette.paper) }
    private var highlight: NSRange? { library.settings.narrationHighlight ? (library.settings.highlightMode == .word ? narrator.wordHighlight : narrator.highlight) : nil }
    var body: some View {
        VStack(spacing: 0) {
            if let book = narrator.book {
                GeometryReader { geometry in
                    let document = pageCache.getDocument(book: book, size: geometry.size, settings: library.settings, color: palette.ink, paper: palette.paper)
                    TurningReader(document: document, location: narrator.location, highlight: highlight, settings: library.settings, marks: library.marks(for: book.id), saveHighlight: { location, range, color in
                        library.addHighlight(book: book, location: location, range: range, color: color)
                    }, readFrom: { narrator.seek($0); narrator.play() }, navigate: { narrator.seek($0) })
                        .id("\(library.settings.pageTurn)|\(palette.paper.description)|\(reduceMotion)")
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .accessibilityAction(named: "Next page") { if let next = document.adjacent(document.address(narrator.location), direction: 1) { narrator.seek(document.location(next)) } }
                        .accessibilityAction(named: "Previous page") { if let previous = document.adjacent(document.address(narrator.location), direction: -1) { narrator.seek(document.location(previous)) } }
                }
            }
            HStack(spacing: 10) {
                if library.settings.lineGuide {
                    Menu {
                        ForEach(GuideDimming.allCases) { level in Button(level.rawValue) { library.settings.guideDimming = level } }
                        Button("Turn Off Line Guide") { library.settings.lineGuide = false }
                    } label: { Image(systemName: "line.3.horizontal").frame(width: 44, height: 44) }.accessibilityLabel("Line guide dimming")
                }
                Spacer()
                if narrator.playing || narrator.highlight != nil {
                    Button(narrator.playing ? "Pause" : "Resume", systemImage: narrator.playing ? "pause.fill" : "play.fill") {
                        narrator.playing ? narrator.pause() : narrator.play()
                    }.font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(height: 44).background(.regularMaterial, in: Capsule())
                }
                Button {
                    bookmarkLocation = pageCache.pageStart(narrator.location)
                    menu = true
                } label: { Image(systemName: "list.bullet").font(.system(size: 18, weight: .medium)).frame(width: 48, height: 44).background(.regularMaterial, in: Capsule()) }
                    .accessibilityLabel("Reading menu")
            }.buttonStyle(.plain).padding(.horizontal, 20).padding(.bottom, 4)
        }.background(background).preferredColorScheme(dark ? .dark : .light)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $menu) {
                ReadingMenuView(pageStart: bookmarkLocation, closeBook: { dismiss() }).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .onChange(of: phase) { _, _ in library.save() }
            .onChange(of: library.settings) { _, _ in library.save() }
            .alert("Playback unavailable", isPresented: Binding(get: { narrator.error != nil }, set: { if !$0 { narrator.error = nil } })) { Button("OK") { narrator.error = nil } } message: { Text(narrator.error ?? "") }
    }
}
struct SettingsView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.dismiss) var dismiss
    private var voices: [AVSpeechSynthesisVoice] {
        let language = narrator.book?.language.components(separatedBy: "-").first ?? "en"
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }.sorted { $0.name < $1.name }
    }
    var body: some View {
        Form {
                Section("Reading styles") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(ReadingPreset.allCases) { preset in
                            Button { preset.apply(to: &library.settings) } label: {
                                let preview = preset.preview
                                VStack(spacing: 8) {
                                    Text("Aa").font(.custom(preview.font, size: 25)).fontWeight(preview.boldText ? .bold : .regular)
                                    Text(preset.rawValue).font(.caption.weight(.medium))
                                }.frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .foregroundStyle(Color(ReaderPalette(settings: preview, systemDark: false).ink))
                                    .background(Color(ReaderPalette(settings: preview, systemDark: false).paper), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.brown.opacity(0.2)))
                            }.buttonStyle(.plain).accessibilityLabel("Apply \(preset.rawValue) reading style")
                        }
                    }.padding(.vertical, 4)
                }
                Section("Page turning") {
                    Picker("Animation", selection: $library.settings.pageTurn) { ForEach(PageTurnStyle.allCases) { Text($0.rawValue).tag($0) } }
                    Text("Both sides of a curled page use your selected paper color. Animations respect Reduce Motion.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Page") {
                    Picker("Font", selection: $library.settings.font) { ForEach(["Georgia", "Palatino", "TimesNewRomanPSMT", "AvenirNext-Regular", "Baskerville", "Charter", "HelveticaNeue"], id: \.self) { Text(["TimesNewRomanPSMT": "Times New Roman", "AvenirNext-Regular": "Avenir", "HelveticaNeue": "Helvetica"][$0] ?? $0).tag($0) } }
                    VStack(alignment: .leading) { Text("Font size · \(Int(library.settings.size))"); Slider(value: $library.settings.size, in: 16...34, step: 1) }
                    VStack(alignment: .leading) { Text("Line spacing"); Slider(value: $library.settings.spacing, in: 2...16, step: 1) }
                    VStack(alignment: .leading) { Text("Margins"); Slider(value: $library.settings.margin, in: 16...44, step: 2) }
                    Picker("Appearance", selection: $library.settings.theme) { ForEach(["System", "Light", "Sepia", "Mist", "Dusk", "Dark"], id: \.self) { Text($0).tag($0) } }
                    Toggle("Bold text", isOn: $library.settings.boldText)
                    Toggle("Justify paragraphs", isOn: $library.settings.justified)
                    VStack(alignment: .leading) { Text("Character spacing"); Slider(value: $library.settings.characterSpacing, in: 0...2, step: 0.1) }
                    VStack(alignment: .leading) { Text("Word spacing"); Slider(value: $library.settings.wordSpacing, in: 0...6, step: 0.5) }
                    VStack(alignment: .leading) { Text("Paragraph spacing"); Slider(value: $library.settings.paragraphSpacing, in: 4...28, step: 1) }
                    Button("Reset page styling") { ReadingPreset.classic.apply(to: &library.settings) }
                }
                Section("Narration highlighting") {
                    Toggle("Highlight spoken text", isOn: $library.settings.narrationHighlight)
                    if library.settings.narrationHighlight {
                        Picker("Follow", selection: $library.settings.highlightMode) { ForEach(HighlightMode.allCases) { Text($0.rawValue).tag($0) } }
                        Picker("Color", selection: $library.settings.highlightColor) { ForEach(HighlightColor.allCases) { color in Label(color.rawValue, systemImage: "circle.fill").foregroundStyle(Color(color.uiColor)).tag(color) } }
                        VStack(alignment: .leading) { Text("Highlight intensity"); Slider(value: $library.settings.highlightOpacity, in: 0.15...0.6, step: 0.05) }
                    }
                }
                Section("Saved highlights") {
                    Toggle("Show saved highlights on pages", isOn: $library.settings.showSavedHighlights)
                    Picker("Default color", selection: $library.settings.savedHighlightColor) { ForEach(HighlightColor.allCases) { Text($0.rawValue).tag($0) } }
                }
                Section("Line Guide") {
                    Toggle("Line Guide", isOn: $library.settings.lineGuide)
                    if library.settings.lineGuide {
                        Picker("Text dimming", selection: $library.settings.guideDimming) { ForEach(GuideDimming.allCases) { Text($0.rawValue).tag($0) } }
                    }
                    Text("Only text outside the active line fades; your paper color stays unchanged. Drag vertically to move the guide, or let it follow narration.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Search Book") {
                    Toggle("Whole words only", isOn: $library.settings.searchWholeWords)
                    Toggle("Match case", isOn: $library.settings.searchCaseSensitive)
                    NavigationLink("Search this book") { BookSearchView() }
                }
                Section("Apple voice") {
                    Picker("Speed", selection: $library.settings.speed) { ForEach(ReaderSettings.speeds, id: \.self) { Text("\($0.formatted())×").tag($0) } }
                    Picker("Voice", selection: $library.settings.voice) {
                        Text("Automatic · book language").tag("")
                        ForEach(voices, id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) }
                    }
                    Text("Uses voices available on your iPhone. Manage downloaded voices in Settings → Accessibility → Spoken Content. Speed labels are approximate.").font(.footnote).foregroundStyle(.secondary)
                }
        }.navigationTitle("Themes & Settings").navigationBarTitleDisplayMode(.inline)
            .onChange(of: library.settings) { old, new in
            library.save()
            if old.voice != new.voice || old.speed != new.speed { narrator.settingsChanged() }
        }
    }
}

extension ReadingPreset {
    var preview: ReaderSettings { var settings = ReaderSettings(); apply(to: &settings); return settings }
}
