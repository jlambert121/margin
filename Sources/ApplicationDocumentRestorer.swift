import Cocoa

/// Reconstructs documents from recovery drafts and persisted window entries.
enum ApplicationDocumentRestorer {
    static func recoverDocuments(controller: DocumentController, recoveryStore: RecoveryStore, display: Bool) throws -> [Error] {
        let result = try recoveryStore.readAll()
        var failures = result.failures
        for draft in result.drafts {
            do {
                if let existing = controller.documents.compactMap({ $0 as? MarkdownDocument }).first(where: {
                    $0.recoveryID == draft.id || ($0.fileURL?.path == draft.originalPath && $0.text == draft.text)
                }) {
                    if existing.isDocumentEdited {
                        existing.recoveryStore = recoveryStore
                        // Write the replacement before removing the old copy.
                        try recoveryStore.write(RecoveryDraft(id: existing.recoveryID, text: existing.text, originalPath: (existing.fileURL ?? existing.recoveredOriginalURL)?.path, name: existing.editorName))
                    }
                    if !existing.isDocumentEdited || existing.recoveryID != draft.id {
                        try recoveryStore.remove(draft.id)
                    }
                    continue
                }
                guard let doc = try controller.makeUntitledDocument(ofType: markdownType) as? MarkdownDocument else {
                    throw CocoaError(.fileReadUnknown)
                }
                doc.recoveryStore = recoveryStore; doc.recoveryID = draft.id
                doc.recoveredOriginalURL = draft.originalPath.map { URL(fileURLWithPath: $0) }
                doc.text = draft.text
                doc.recoveredName = draft.name.hasPrefix("Recovered ") ? draft.name : "Recovered " + draft.name
                doc.displayName = doc.recoveredName
                doc.updateChangeCount(.changeDone)
                controller.addDocument(doc)
                if display {
                    doc.makeWindowControllers(); doc.showWindows()
                }
            } catch { failures.append(error) }
        }
        return failures
    }

    static func restoreDocument(_ entry: [String: Any], controller: DocumentController, completion: @escaping (MarkdownDocument?) -> Void) {
        func finish(_ document: NSDocument?) {
            guard let doc = document as? MarkdownDocument else { completion(nil); return }
            if let id = (entry["recoveryID"] as? String).flatMap(UUID.init(uuidString:)) {
                doc.recoveryID = id
            }
            if let name = entry["recoveredName"] as? String {
                doc.recoveredName = name; doc.displayName = name
            }
            if let original = entry["recoveredOriginalPath"] as? String {
                doc.recoveredOriginalURL = URL(fileURLWithPath: original)
            }
            completion(doc)
        }
        if let path = entry["path"] as? String {
            controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: false) { document, _, _ in finish(document) }
        } else if let autosaved = entry["autosaved"] as? String {
            controller.reopenDocument(for: nil, withContentsOf: URL(fileURLWithPath: autosaved), display: false) { document, _, _ in finish(document) }
        } else {
            // A clean untitled document; a welcome comes back with its text.
            guard let doc = try? controller.makeUntitledDocument(ofType: markdownType) as? MarkdownDocument else { completion(nil); return }
            if entry["welcome"] as? Bool == true, let welcome = MarkdownDocument.welcomeText() {
                doc.text = welcome; doc.isWelcome = true
            }
            controller.addDocument(doc)
            finish(doc)
        }
    }
}
