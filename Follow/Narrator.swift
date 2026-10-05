import SwiftUI
import AVFoundation
import MediaPlayer

@MainActor final class Narrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var book: Book?
    @Published var location = Location()
    @Published var highlight: NSRange?
    @Published var wordHighlight: NSRange?
    @Published var playing = false
    @Published var error: String?
    let synthesizer = AVSpeechSynthesizer()
    private var artwork: MPMediaItemArtwork?
    private var utterance: AVSpeechUtterance?
    private var utteranceStart = 0
    private var utteranceEnd = 0
    private var library: Library?
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { $0.play() }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.playing ? $0.pause() : $0.play() }
        bind(center.previousTrackCommand) { $0.skip(-1) }
        bind(center.nextTrackCommand) { $0.skip(1) }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, value == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.pause() }
        })
    }
    private func bind(_ command: MPRemoteCommand, action: @escaping (Narrator) -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor in if let self, self.book != nil { action(self) } }
            return .success
        }
        remoteTargets.append((command, target))
    }
    func open(_ book: Book, library: Library) {
        if self.book?.id == book.id { return }
        pause()
        invalidate()
        self.library = library
        self.book = book
        artwork = nil
        if let data = book.cover, let image = UIImage(data: data) { artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        location = book.location
        highlight = nil; wordHighlight = nil
        nowPlaying()
    }
    func refreshMetadata(_ updated: Book) {
        guard book?.id == updated.id else { return }
        book = updated
        artwork = nil
        if let data = updated.cover, let image = UIImage(data: data) {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        nowPlaying()
    }
    func seek(_ newLocation: Location) {
        guard let book else { return }
        let wasPlaying = playing
        invalidate()
        let chapter = min(max(0, newLocation.chapter), book.chapters.count - 1)
        location = Location(chapter: chapter, offset: min(max(0, newLocation.offset), book.chapters[chapter].length))
        highlight = nil; wordHighlight = nil
        persist()
        if wasPlaying { play() }
    }
    func play() {
        guard book != nil, !playing else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch { self.error = "Audio could not start: \(error.localizedDescription)"; return }
        playing = true
        if synthesizer.isPaused, utterance != nil { _ = synthesizer.continueSpeaking() }
        else { speakNext() }
        nowPlaying()
    }
    func pause() {
        if synthesizer.isSpeaking { _ = synthesizer.pauseSpeaking(at: .immediate) }
        playing = false
        persist()
        nowPlaying()
    }
    private func invalidate() {
        utterance = nil // Ignore any callback from the cancelled utterance.
        synthesizer.stopSpeaking(at: .immediate)
        playing = false
    }
    func settingsChanged() {
        let resume = playing
        invalidate()
        library?.save()
        if resume { play() }
    }
    func skip(_ direction: Int) {
        guard let book else { return }
        let chapter = book.chapters[location.chapter]
        if direction > 0 {
            let end = NSMaxRange(chapter.sentence(at: location.offset))
            if end < chapter.length { seek(Location(chapter: location.chapter, offset: end)) }
            else if location.chapter + 1 < book.chapters.count { seek(Location(chapter: location.chapter + 1)) }
            else { seek(Location(chapter: location.chapter, offset: chapter.length)) }
        } else {
            let start = chapter.sentence(at: location.offset).location
            if start > 0 { seek(Location(chapter: location.chapter, offset: chapter.sentence(at: start - 1).location)) }
            else if location.chapter > 0 {
                let previous = book.chapters[location.chapter - 1]
                seek(Location(chapter: location.chapter - 1, offset: previous.sentence(at: previous.length - 1).location))
            } else { seek(Location()) }
        }
    }
    var progress: Double {
        guard var current = book else { return 0 }
        current.location = location
        return current.progress
    }
    private func speakNext() {
        guard let book, playing else { return }
        location.offset = book.chapters[location.chapter].nextSpokenOffset(location.offset)
        while location.offset >= book.chapters[location.chapter].length {
            guard location.chapter + 1 < book.chapters.count else {
                playing = false; highlight = nil; wordHighlight = nil; utterance = nil; persist(); nowPlaying(); return
            }
            location = Location(chapter: location.chapter + 1, offset: book.chapters[location.chapter + 1].nextSpokenOffset(0))
        }
        let chapter = book.chapters[location.chapter]
        let sentence = chapter.sentence(at: location.offset)
        utteranceStart = location.offset
        utteranceEnd = min(chapter.length, NSMaxRange(sentence))
        let text = (chapter.text as NSString).substring(with: NSRange(location: utteranceStart, length: utteranceEnd - utteranceStart)).replacingOccurrences(of: "\u{FFFC}", with: " ").replacingOccurrences(of: "\u{00AD}", with: " ")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            location.offset = utteranceEnd; speakNext(); return
        }
        let next = AVSpeechUtterance(string: text)
        let settings = library?.settings ?? ReaderSettings()
        if settings.voice == "system" {
            next.voice = nil // Apple applies the device preference and any required Siri fallback.
        } else if settings.voice.isEmpty {
            next.voice = AVSpeechSynthesisVoice(language: book.language)
        } else {
            guard let voice = AVSpeechSynthesisVoice(identifier: settings.voice) else {
                playing = false; highlight = nil; wordHighlight = nil
                error = "The selected voice is no longer available. Open Themes & Settings → Voice and choose another voice."
                persist(); nowPlaying(); return
            }
            next.voice = voice
        }
        // Apple's rate is bounded and nonlinear; multipliers are approximate.
        next.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate + Float(log2(settings.speed)) * 0.12))
        utterance = next
        highlight = sentence
        wordHighlight = nil
        synthesizer.speak(next)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.utterance else { return }
            self.wordHighlight = NSRange(location: self.utteranceStart + characterRange.location, length: characterRange.length)
            self.location.offset = self.utteranceStart + characterRange.location
            self.persist()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, utterance === self.utterance else { return }
            self.utterance = nil
            self.location.offset = self.utteranceEnd
            self.persist()
            self.speakNext()
        }
    }
    private func persist() {
        guard let book else { return }
        library?.update(book.id, location: location)
        nowPlaying()
    }
    private func nowPlaying() {
        guard let book else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: book.title, MPMediaItemPropertyArtist: book.author, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
