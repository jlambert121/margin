import Cocoa

struct WindowRestorationSnapshot {
    let entries: [[String: Any]]
    let selected: Int
    let workspace: URL?
}

enum WindowRestoration {
    static func snapshot(_ host: EditorWindowController) -> WindowRestorationSnapshot {
        let entries: [[String: Any]] = host.documents.compactMap { doc in
            var entry: [String: Any] = ["recoveryID": doc.recoveryID.uuidString, "welcome": doc.isWelcome]
            if let path = doc.fileURL?.path {
                entry["path"] = path
            } else if let autosaved = doc.autosavedContentsFileURL?.path {
                entry["autosaved"] = autosaved
            } else if !doc.isWelcome, doc.isDocumentEdited {
                return nil
            }
            if let name = doc.recoveredName {
                entry["recoveredName"] = name
            }
            if let original = doc.recoveredOriginalURL?.path {
                entry["recoveredOriginalPath"] = original
            }
            return entry
        }
        return WindowRestorationSnapshot(entries: entries, selected: host.current.flatMap { current in host.documents.firstIndex { $0 === current } } ?? 0, workspace: host.workspace)
    }

    static func encode(_ snapshot: WindowRestorationSnapshot, to state: NSCoder) {
        state.encode(snapshot.entries, forKey: "Margin.documents")
        state.encode(snapshot.selected, forKey: "Margin.current")
        if let workspace = snapshot.workspace {
            state.encode(workspace.path as NSString, forKey: "Margin.workspace")
        }
    }

    static func restore(_ host: EditorWindowController, from state: NSCoder, completion: @escaping () -> Void) {
        let allowed = [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self]
        let entries = state.decodeObject(of: allowed, forKey: "Margin.documents") as? [[String: Any]] ?? []
        let selected = state.decodeInteger(forKey: "Margin.current")
        var isFolder: ObjCBool = false
        if let path = state.decodeObject(of: NSString.self, forKey: "Margin.workspace") as String?,
           FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue
        {
            host.workspace = URL(fileURLWithPath: path)
        }
        guard let app = (NSDocumentController.shared as? DocumentController)?.app, !entries.isEmpty else { completion(); return }
        var restored = [MarkdownDocument?](repeating: nil, count: entries.count)
        var remaining = entries.count
        func finished(_ index: Int, _ doc: MarkdownDocument?) {
            restored[index] = doc
            remaining -= 1
            guard remaining == 0 else { return }
            for doc in restored.compactMap({ $0 }) {
                host.add(doc, at: host.documents.count)
            }
            if let doc = restored.indices.contains(selected) ? restored[selected] : nil {
                host.select(doc)
            }
            completion()
        }
        for (index, entry) in entries.enumerated() {
            app.restoreDocument(entry) { doc in finished(index, doc) }
        }
    }
}

final class EditorWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(withIdentifier _: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        guard let app = (NSDocumentController.shared as? DocumentController)?.app else { completionHandler(nil, CocoaError(.featureUnsupported)); return }
        let host = app.makeWindow()
        app.beginRestoring()
        host.restore(from: state) {
            app.endRestoring()
            if host.documents.isEmpty {
                host.close(); completionHandler(nil, CocoaError(.fileReadNoSuchFile))
            } else {
                completionHandler(host.window, nil)
            }
        }
    }
}
