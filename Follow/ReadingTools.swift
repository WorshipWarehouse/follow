import SwiftUI
import AVFoundation

private struct CloseReadingMenuKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var closeReadingMenu: () -> Void {
        get { self[CloseReadingMenuKey.self] }
        set { self[CloseReadingMenuKey.self] = newValue }
    }
}
struct ReadingMenuView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.dismiss) var dismiss
    let pageStart: Location
    let closeBook: () -> Void
    @State private var saved = false
    private var book: Book? { narrator.book }
    private var bookmarked: Bool { book.map { book in library.marks(for: book.id).contains { $0.bookmark && $0.location == pageStart } } ?? false }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book?.title ?? "Reading").font(.headline).lineLimit(2)
                                Text("\(Int(narrator.progress * 100))% read").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { if let book { library.toggleBookmark(book: book, location: pageStart) } } label: {
                                Image(systemName: bookmarked ? "bookmark.fill" : "bookmark").font(.title3).frame(width: 44, height: 44)
                            }.buttonStyle(.borderless).accessibilityLabel(bookmarked ? "Remove bookmark" : "Bookmark this page")
                        }
                        ProgressView(value: narrator.progress).tint(.brown)
                        HStack(spacing: 20) {
                            Button("Previous sentence", systemImage: "backward.end.fill") { narrator.skip(-1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                            Button { if narrator.playing { narrator.pause() } else { narrator.play(); if narrator.playing { dismiss() } } } label: {
                                Image(systemName: narrator.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 62, height: 48).background(.brown.opacity(0.12), in: Capsule())
                            }.accessibilityLabel(narrator.playing ? "Pause" : "Read aloud")
                            Button("Next sentence", systemImage: "forward.end.fill") { narrator.skip(1) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                            Spacer(minLength: 0)
                            Menu {
                                ForEach(ReaderSettings.speeds, id: \.self) { speed in
                                    Button { library.settings.speed = speed; narrator.settingsChanged() } label: {
                                        if library.settings.speed == speed { Label("\(speed.formatted())×", systemImage: "checkmark") }
                                        else { Text("\(speed.formatted())×") }
                                    }
                                }
                            } label: { Text("\(library.settings.speed.formatted())×").font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Narration speed")
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
                Section {
                    NavigationLink { BookContentsView() } label: { Label("Contents", systemImage: "list.bullet") }
                    NavigationLink { BookSearchView() } label: { Label("Search Book", systemImage: "magnifyingglass") }
                    NavigationLink { AnnotationsView() } label: { Label("Bookmarks & Highlights", systemImage: "bookmark.square") }
                    NavigationLink { SettingsView() } label: { Label("Themes & Settings", systemImage: "textformat.size") }
                }
                Section {
                    Button {
                        guard let book else { return }
                        let range = book.chapters[narrator.location.chapter].sentence(at: narrator.location.offset)
                        library.addHighlight(book: book, location: narrator.location, range: range, color: library.settings.savedHighlightColor)
                        saved = true
                    } label: { Label(saved ? "Sentence saved" : "Save Current Sentence", systemImage: saved ? "checkmark" : "highlighter") }
                    Toggle(isOn: $library.settings.lineGuide) { Label("Line Guide", systemImage: "line.3.horizontal") }
                    Button { dismiss(); closeBook() } label: { Label("Back to Library", systemImage: "books.vertical") }
                } footer: { Text("Touch and hold a word, then drag across a passage to select and save a highlight.") }
            }.navigationTitle("Reading Menu").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.environment(\.closeReadingMenu, { dismiss() }).onChange(of: library.settings) { _, _ in library.save() }
    }
}
struct BookContentsView: View {
    @Environment(\.closeReadingMenu) var closeMenu
    @EnvironmentObject var narrator: Narrator
    @Environment(\.dismiss) var dismiss
    var body: some View {
        List(narrator.book?.contents ?? []) { item in
            Button { narrator.seek(item.location); closeMenu() } label: {
                HStack { Text(item.title); Spacer(); if item.location.chapter == narrator.location.chapter { Image(systemName: "book.pages") } }
            }
        }.navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
    }
}
struct BookSearchView: View {
    @Environment(\.closeReadingMenu) var closeMenu
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var results: [BookSearchResult] = []
    @State private var searching = false
    @State private var completedQuery = ""
    private var searchKey: String { "\(query)|\(library.settings.searchWholeWords)|\(library.settings.searchCaseSensitive)" }
    var body: some View {
        List {
            Section {
                Toggle("Whole words only", isOn: $library.settings.searchWholeWords)
                Toggle("Match case", isOn: $library.settings.searchCaseSensitive)
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView("Search this book", systemImage: "magnifyingglass", description: Text("Find a word or phrase anywhere in the book."))
            } else if searching {
                HStack { Spacer(); ProgressView("Searching…"); Spacer() }
            } else if results.isEmpty {
                ContentUnavailableView.search(text: completedQuery)
            } else {
                Section("\(results.count) results\(results.count > 500 ? " · first 500 shown" : "")") {
                    ForEach(Array(results.prefix(500))) { result in
                        Button {
                            narrator.seek(result.location)
                            closeMenu()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(result.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(result.excerpt).font(.body).foregroundStyle(.primary).lineLimit(4)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.navigationTitle("Search Book").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Word or phrase")
            .task(id: searchKey) {
                guard let book = narrator.book else { return }
                let value = query
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; searching = false; return }
                searching = true
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let whole = library.settings.searchWholeWords, sensitive = library.settings.searchCaseSensitive
                let found = await Task.detached(priority: .userInitiated) { BookSearch.find(in: book, query: value, wholeWords: whole, caseSensitive: sensitive) }.value
                guard !Task.isCancelled else { return }
                results = found; completedQuery = value; searching = false
            }.onChange(of: library.settings) { _, _ in library.save() }
    }
}
struct AnnotationsView: View {
    @Environment(\.closeReadingMenu) var closeMenu
    @EnvironmentObject var library: Library
    @EnvironmentObject var narrator: Narrator
    @Environment(\.dismiss) var dismiss
    @State private var bookmarks = false
    private var marks: [BookAnnotation] { narrator.book.map { library.marks(for: $0.id).filter { $0.bookmark == bookmarks } } ?? [] }
    var body: some View {
        List {
            Picker("Saved passages", selection: $bookmarks) { Text("Highlights").tag(false); Text("Bookmarks").tag(true) }.pickerStyle(.segmented)
            if marks.isEmpty {
                ContentUnavailableView(bookmarks ? "No bookmarks yet" : "No highlights yet", systemImage: bookmarks ? "bookmark" : "highlighter", description: Text(bookmarks ? "Use the bookmark button in the reading menu to save a page." : "Select text in the book or save the current sentence from the reading menu."))
            }
            ForEach(marks) { mark in
                Button { narrator.seek(mark.location); closeMenu() } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: mark.bookmark ? "bookmark.fill" : "circle.fill").foregroundStyle(Color(mark.color.uiColor)).font(.caption).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(narrator.book?.chapters[mark.location.chapter].title ?? "Saved passage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(mark.excerpt).font(.system(.body, design: .serif)).foregroundStyle(.primary).lineLimit(6)
                        }
                    }.padding(.vertical, 6)
                }.contextMenu {
                    if !mark.bookmark {
                        ForEach(HighlightColor.allCases) { color in Button(color.rawValue) { library.recolorAnnotation(mark.id, color: color) } }
                    }
                    Button("Delete", role: .destructive) { library.removeAnnotation(mark.id) }
                }
            }.onDelete { indexes in let ids = indexes.map { marks[$0].id }; for id in ids { library.removeAnnotation(id) } }
        }.navigationTitle("Bookmarks & Highlights").navigationBarTitleDisplayMode(.inline)
    }
}
