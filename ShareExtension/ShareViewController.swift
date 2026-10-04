import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let status = UILabel()
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
        let stack = UIStackView(arrangedSubviews: [status, done])
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
            if let url { self?.store(url) }
            else {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, error in
                    guard let url = item as? URL else { self?.show(error?.localizedDescription ?? "This file could not be opened."); return }
                    self?.store(url)
                }
            }
        }
    }
    private func store(_ url: URL) {
        guard url.pathExtension.lowercased() == "epub" else { show("Follow opens DRM-free EPUB files."); return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.local.Follow") else { throw CocoaError(.fileWriteNoPermission) }
            let inbox = group.appendingPathComponent("Inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let destination = inbox.appendingPathComponent(UUID().uuidString + ".epub")
            let staging = inbox.appendingPathComponent(UUID().uuidString + ".pending")
            try FileManager.default.copyItem(at: url, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            show("Saved to Follow.\nOpen the app to start reading.")
        } catch { show("The book could not be saved: \(error.localizedDescription)") }
    }
    private func show(_ message: String) { DispatchQueue.main.async { [weak self] in self?.status.text = message } }
    @objc private func finish() { extensionContext?.completeRequest(returningItems: nil) }
}
