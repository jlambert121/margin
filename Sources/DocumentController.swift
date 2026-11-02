import Cocoa
import OSLog
import UniformTypeIdentifiers
import WebKit

class DocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? {
        [markdownType, plainTextType].contains(typeName) ? MarkdownDocument.self : nil
    }

    override var defaultType: String? {
        markdownType
    }

    weak var app: AppDelegate?
    private var queuedOpens: [(url: URL, display: Bool, completion: (NSDocument?, Bool, Error?) -> Void)] = []
    private var opening = false
    var isOpening: Bool {
        opening || !queuedOpens.isEmpty
    }

    /// Every open, including Finder's launch-time ones (requested before
    /// didFinishLaunching), comes through here. They run one at a time:
    /// concurrent reads finish in any order, and each window becomes a tab as
    /// it is shown, so tabs would not follow the order requested.
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        queuedOpens.append((url, displayDocument, completionHandler))
        openNextQueuedDocument()
    }

    private func openNextQueuedDocument() {
        guard !opening, !queuedOpens.isEmpty else { return }
        opening = true
        let next = queuedOpens.removeFirst()
        performOpen(next.url, display: next.display) { [weak self] document, alreadyOpen, error in
            next.completion(document, alreadyOpen, error)
            guard let self else { return }
            self.opening = false
            if self.queuedOpens.isEmpty {
                self.app?.documentOpensFinished()
            } else {
                self.openNextQueuedDocument()
            }
        }
    }

    func performOpen(_ url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        NotificationCenter.default.post(name: .openFilesChanged, object: document)
    }

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        NotificationCenter.default.post(name: .openFilesChanged, object: document)
    }

    override func typeForContents(of url: URL) throws -> String {
        guard url.isFileURL, markdownExtensions.contains(url.pathExtension.lowercased()) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a Markdown or plain text file.", NSURLErrorKey: url])
        }
        return url.pathExtension.lowercased() == "txt" ? plainTextType : markdownType
    }
}
