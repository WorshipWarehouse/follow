# Follow

A native SwiftUI iPhone EPUB reader with Apple's local read-aloud voices. iOS 17 or later. No account, server, analytics, cloud TTS, or book uploads.

## Personal iPhone testing

Select the **Follow iPhone** scheme. Its `FollowPersonal` target is configured for the Personal Team selected in Xcode and uses bundle ID `com.calebhines.Follow.personal`. Connect and unlock your iPhone, trust the Mac if prompted, and choose the phone as the run destination. This scheme supports Files import, reading, narration, and background audio without App Groups or a Share Sheet extension. It includes **Try a sample book** on first launch. The original **Follow** scheme retains the complete Share Sheet extension configuration.

Xcode must provision the connected phone before installing. Any Developer Mode or developer trust prompts on the iPhone must be completed by its owner.

## Open and run

1. Open `Follow.xcodeproj` in Xcode. Allow Swift Package Manager to resolve ZIPFoundation.
2. Select the **Follow** scheme and an iPhone simulator with an installed runtime, or a connected iPhone.
3. For a physical device, select your development team for **Follow** and **FollowShare** in Signing & Capabilities. Use unique bundle identifiers. Register an App Group and replace `group.com.local.Follow` in **both entitlements files** and the two Swift source references (`Models.swift` and `ShareViewController.swift`) with that group. App Groups require a team with the appropriate provisioning capability.
4. Build and run. Tap **Choose a Book**, select a DRM-free EPUB from Files, and tap Play.

The generated Xcode project is included; XcodeGen is only needed if changing `project.yml`. If regenerating, make signing and App Group changes in `project.yml` as well.

A sample original EPUB is at `FollowTests/Fixtures/Sample.epub`. Drag or copy it into Files on the simulator/device, then import it. The sample is generated original text with two long chapters and emoji for position tests.

## Implemented

- Local EPUB library with cover, title, author, reading progress, original archive retention, and atomic position persistence.
- EPUB 2 NCX and EPUB 3 navigation, package/spine order, fragment anchors, and rejection of unsupported encryption.
- UIKit TextKit pagination inside SwiftUI with Curl, Slide, Fade, and None page transitions. The curl renders a segmented sheet with explicit themed reverse faces. Measured glyphs are drawn by the same layout manager, keeping pages inside the viewport; chapter contents sheet.
- Seven fonts; font size, bold text, justification, character/word/paragraph spacing, margins, six reading presets, and System/Light/Sepia/Mist/Dusk/Dark appearances.
- Apple `AVSpeechSynthesizer` and available voices matching the book language; all requested approximate speed choices.
- Optional word or sentence narration highlighting, six colors and adjustable intensity; following speech across page boundaries and chapters.
- Unobtrusive bottom-right reading menu; playback, speed choices through 4×, contents, search, bookmarks, and display settings stay tucked away.
- Book-wide phrase search with whole-word and case-sensitive options, jumping directly to matching text.
- Persistent bookmarks and colored highlights; long-press a word and drag to select a passage, then Save Highlight. The menu also saves the current sentence. Browse, recolor, revisit, or delete saved passages in Bookmarks & Highlights.
- Optional draggable line guide with None, Low, Medium, and High text dimming; the paper and illustrations stay unchanged; follows the current spoken line during narration.
- Play from the canonical current offset, pause in place, manual seek with playback repositioning, and recovery from the saved word offset after relaunch.
- Playback audio session and audio background mode; Now Playing title/author/cover; Lock Screen and headphone play/pause and previous/next sentence commands.
- Pause on audio interruption or headphone disconnection; deliberate Play resumes after an interruption.
- Multiple-file Files/iCloud Drive/Downloads import, document Open In/AirDrop handling, and a native Share Sheet extension. Sharing saves an EPUB to an App Group inbox; opening Follow imports it. Direct Open In opens immediately.

## Position architecture

`EPUB spine resource + UTF-16 offset → sentence NSRange → utterance substring → speech delegate word NSRange + utterance start → canonical Location → containing TextKit page`

`Location(chapter, offset)` is the only reading cursor. `Narrator.seek` updates it for manual navigation; `willSpeakRangeOfSpeechString` updates it for speech. The UI derives the visible page from this cursor, so there is no independent page cursor to drift out of sync. Typography changes repaginate around the same offset. A cached layout avoids re-paginating on every speech callback.

The first utterance starts at the exact UTF-16 cursor, even in the middle of a sentence. Subsequent utterances follow sentence boundaries. Only one utterance is active at a time. Identity checks ignore stale callbacks after seeking or changing voices. An in-process pause retains the synthesizer's paused utterance; after termination, speech resumes at the last persisted word start, which may repeat that word. This is word-position restoration, not saved audio-sample restoration.

Original EPUBs and parsed chapters are stored in Application Support. Highlights and bookmarks are stored separately in annotations.json with canonical UTF-16 ranges. Compact reading positions are stored separately and atomically at speech callbacks, avoiding rewriting the full book at every word. Data stays local and can be included in the device's normal backup; cross-device iCloud synchronization is not implemented.

## Apple Books import

Apple Books does not expose its private library to this app. Import available DRM-free EPUB files from Files, iCloud Drive, or Downloads. Protected Apple Books purchases cannot be imported. The personal testing scheme supports Files and Open In; the Share extension requires the full scheme and App Groups.

## Validation status

- Version 1.3 (build 4) signed, installed, and launched on Caleb’s iPhone.
- macOS core tests: **12 passed**, including the supplied Pray First EPUB, hidden-content exclusion, paragraph boundaries, Unicode positions, cursor migration, literal/whole-word search, old preference compatibility, persistent annotations, and styling migration that preserves narration settings.
- Physical iPhone XCTest suite: **13 passed**, including continuous pagination, page bounds at font sizes 21 and 30, chapter transitions, position restoration, text-selection gesture availability, live highlight reset on seeking, glyph-only dimming across palettes, themed curl faces, forward/backward completion of all transition styles, and typography pagination.
- The supplied book is imported on the phone. Screen inspection confirms readable text within the page viewport.
- Voice quality, prolonged locked-screen playback, Bluetooth controls, and Share extension provisioning still require hands-on device checks.

Run the portable core tests with:

```sh
swift test --build-system native --scratch-path ../../work/FollowCoreTests
```

The native SwiftPM build system works around a test bundle signing problem encountered with this Mac's default Swift build engine. To execute the iOS suite, select the Follow iPhone scheme and connected phone, then use Product → Test.

## MVP scope and remaining device checks

The native renderer is optimized for reflowable prose. It preserves paragraph breaks, anchors, bold/italic text, headings, alignment, indents, and inline illustrations. Hidden navigation, page markers, and standalone distributor links are excluded from narration. Publisher CSS is interpreted selectively; complex tables, mathematical notation, and arbitrary publisher layouts are not fully reproduced. Fixed-layout and textless/image-only EPUBs are rejected. ZIPFoundation handles archive access; this is a custom EPUB importer, not a full EPUB conformance engine. Test diverse real-world books before distribution.

Apple's speech-rate values are nonlinear. The speed menu uses a monotonic logarithmic mapping around Apple's default rate, so every option has a distinct rate, but labels such as 2× are approximate and should be calibrated by voice on device. Previous/Next skip sentences, including on the Lock Screen; they do not represent 15-second audio skips. System voices returned by Apple's API may still need their resources managed in iOS Settings.

Before calling the full acceptance test passed:

1. Import a downloaded real-world DRM-free EPUB and navigate midway through a chapter.
2. Play; verify the first spoken word matches the current page position.
3. Change rate and voice; verify highlighting and page following remain synchronized.
4. Cross a page and chapter boundary while listening.
5. Pause, navigate manually, and Play; verify the new page is narrated.
6. Lock the physical iPhone for several minutes and switch apps; verify continued narration.
7. Pause/resume and skip with Lock Screen and Bluetooth controls.
8. Terminate/reopen; verify restoration to the saved word.
9. Share an EPUB from another app, open Follow, and verify its import.
10. Repeat with airplane mode enabled and a downloaded system voice.

## Dependencies

[ZIPFoundation](https://github.com/weichsel/ZIPFoundation) provides ZIP reading (MIT license). Speech uses [Apple AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer). There is no runtime server dependency. The resolved Swift package versions are included.

## Reading menu reference

The bottom reading menu and grouping of search, bookmarks/highlights, themes, and line-guide controls were informed by [Apple’s Books reading guide](https://support.apple.com/guide/iphone/read-books-iphc1af7c57/ios).

Starting narration closes the reading menu. A labeled Pause button remains beside the bottom-right menu; it becomes Resume when paused. Both directions of all page transitions use the chosen palette. Reduce Motion disables the animations.

## Voice picker update (1.4)

Themes & Settings → Voice now browses every voice exposed by Apple’s app speech API, with language/name search, Standard/Enhanced/Premium labels, previews, and automatic refresh after downloads. Device spoken voice leaves selection to Apple’s device preference. Siri voices such as Voice 3 are excluded from AVSpeechSynthesizer; Apple supplies a fallback if Siri is the device preference. To hear the actual Siri voice, use Apple’s accessibility reading features in the new continuous-text Apple Accessibility Reader view, accessible from the reading menu or voice picker. It starts at the Follow cursor and supplies the remaining book text to a native UITextView. Those do not provide Follow’s synchronized playback cursor.

If a saved voice becomes unavailable, Follow reports it instead of silently choosing another voice. The 1.4 build and device tests must be confirmed before treating this update as installed.

## Book details (1.4)

Long-press a book in the library and choose Edit Book, or choose Edit Book from the reading menu. Correct title and author, choose a cover from Photos or Files, or remove it. Save writes only Follow’s library metadata; the original EPUB, reading position, bookmarks, and highlights are preserved. Reimporting the original file still finds the edited book.

The signed 1.4 app builds successfully and the iPhone test target compiles. Installation and physical-device testing are pending because the connected iPhone is unavailable to Xcode.

## Paste import (1.5)

Copy an EPUB file in Files, open Follow, and choose + → Paste. The native system paste control accepts EPUB file representations and file URLs, stages transient provider files before importing, and leaves the clipboard alone until the user pastes. Non-EPUB files and inaccessible file URLs report an import error. EPUB imported-type declarations improve Open In discovery. The personal iPhone build still excludes the App Group based Share extension; Open In and paste are its import routes.

Version 1.5 was signed, installed, and launched on Caleb’s iPhone. All 18 device tests passed, including EPUB paste staging and rejection of non-EPUB file URLs. Share-row visibility across source apps has not been verified.

## Import picker repair (1.5 build 7)

Restored the direct + button and moved Paste beside it. Files accepts generic items so provider EPUBs classified as ZIP/data remain selectable; the importer checks the .epub extension and parser validates contents. Import coordinates and stages a local file-provider snapshot before parsing and archive retention. Twelve core checks passed (one additional check skipped), eighteen existing device checks passed, and the added physical-device import/persistence check passed.

## Apple Books package repair (1.5 build 9)

The ten user-supplied Apple Books .epub URLs were unpacked directories, explaining ZIPFoundation error 13. EPUBArchive now creates a temporary standards-compliant ZIP with mimetype first and uncompressed before importing or pasting a directory package. The source remains untouched; retained originals are normalized ZIPs so reopening and parser migrations work. Symlinks and oversized packages are rejected. All ten supplied books passed local import, 14 core tests passed (one unrelated local-fixture test skipped), and all 22 iPhone tests passed, including directory import/retention and clipboard-data paste. The normal build was signed for installation.

The optional Follow iPhone Sharing scheme includes a personal-team Share extension that copies the selected EPUB to the clipboard on an explicit Copy Book for Follow tap. Open Follow and Paste to complete import. This avoids App Group requirements, but its new bundle identifier still needs an Apple Account signing profile; it is not included in the installed build until signing is restored.

## Sharing build (1.5 build 10)

Removed Paste from the library and empty state. The Follow iPhone Sharing scheme now signs successfully and embeds FollowPersonalShare. Its Save Book for Follow action exports the normalized EPUB through the system Files picker. Save in On My iPhone → Follow and open Follow for inbox import, or save elsewhere and use +. The sharing app uses the same bundle identifier and preserves existing library data. The signed app and embedded extension passed codesign verification. Share-sheet visibility and the Files export interaction still need a manual check on the phone.
