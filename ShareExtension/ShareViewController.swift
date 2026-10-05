import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController, UIDocumentPickerDelegate {
    private let status = UILabel()
    private var pendingBook: URL?
    private let saveButton = UIButton(type: .system)
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.text = "Saving your book…"
        status.font = .preferredFont(forTextStyle: .title2)
        status.textAlignment = .center
        status.numberOfLines = 0
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        saveButton.setTitle("Save Book for Follow", for: .normal)
        saveButton.addTarget(self, action: #selector(saveBook), for: .touchUpInside)
        saveButton.isHidden = true
        let stack = UIStackView(arrangedSubviews: [status, saveButton, done])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            done.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let epub = UTType(filenameExtension: "epub")?.identifier ?? "org.idpf.epub-container"
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(epub) || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            status.text = "Share a DRM-free EPUB file to read it in Follow."
            return
        }
        let type = provider.hasItemConformingToTypeIdentifier(epub) ? epub : UTType.fileURL.identifier
        provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
            if let url { self?.store(url, knownEPUB: type == epub) }
            else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                    guard let url = item as? URL else { self?.show(error?.localizedDescription ?? "This file could not be opened."); return }
                    self?.store(url)
                }
            }
        }
    }
    private func store(_ url: URL, knownEPUB: Bool = false) {
        guard knownEPUB || url.pathExtension.lowercased() == "epub" else { show("Follow opens DRM-free EPUB files."); return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            #if PERSONAL_SHARE
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let normalized = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".epub")
            try EPUBArchive.copy(from: url, to: normalized)
            let data = try Data(contentsOf: normalized)
            guard data.starts(with: [0x50, 0x4b]) else { throw CocoaError(.fileReadCorruptFile) }
            DispatchQueue.main.async { [weak self] in
                self?.pendingBook = normalized
                self?.status.text = "Save to On My iPhone → Follow, then open Follow. Or save elsewhere and add it with +."
                self?.saveButton.isHidden = false
            }
            #else
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.local.Follow") else { throw CocoaError(.fileWriteNoPermission) }
            let inbox = group.appendingPathComponent("Inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let destination = inbox.appendingPathComponent(UUID().uuidString + ".epub")
            let staging = inbox.appendingPathComponent(UUID().uuidString + ".pending")
            try FileManager.default.copyItem(at: url, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            show("Saved to Follow.\nOpen the app to start reading.")
            #endif
        } catch { show("The book could not be saved: \(error.localizedDescription)") }
    }
    private func show(_ message: String) { DispatchQueue.main.async { [weak self] in self?.status.text = message } }
    @objc private func saveBook() {
        guard let pendingBook else { return }
        let picker = UIDocumentPickerViewController(forExporting: [pendingBook], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        status.text = "Book saved. Open Follow. If you saved outside its folder, tap + and choose the book."
        saveButton.isHidden = true
    }
    @objc private func finish() {
        if let pendingBook { try? FileManager.default.removeItem(at: pendingBook.deletingLastPathComponent()) }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
