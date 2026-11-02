import Cocoa

final class WorkspaceActions {
    private weak var app: AppDelegate?
    init(app: AppDelegate) {
        self.app = app
    }

    func createWorkspaceFile(in folder: URL, in host: EditorWindowController) throws {
        guard app != nil else { throw CocoaError(.userCancelled) }
        guard host.isInWorkspace(folder) else { throw CocoaError(.fileWriteNoPermission) }
        var url = folder.appendingPathComponent("Untitled.md"), number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("Untitled \(number).md"); number += 1
        }
        try Data().write(to: url, options: .withoutOverwriting)
        host.refreshFolder { [weak self] in
            self?.app?.open([url], in: host) { document in (document as? MarkdownDocument)?.editor?.host?.sidebar.beginRename(path: url.path) }
        }
    }

    func renameWorkspaceFile(_ url: URL, to name: String, in host: EditorWindowController, completion: @escaping (Error?) -> Void) {
        guard let app else { completion(CocoaError(.userCancelled)); return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func refused(_ reason: String) {
            completion(NSError(domain: "Margin.Rename", code: 1, userInfo: [NSLocalizedDescriptionKey: "“\(trimmed)” can’t be used as a file name.", NSLocalizedRecoverySuggestionErrorKey: reason]))
        }
        guard host.isInWorkspace(url) else { completion(CocoaError(.fileWriteNoPermission)); return }
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else { refused("Use a name without “/” or “:” that doesn’t start with a period."); return }
        let fileName = markdownExtensions.contains((trimmed as NSString).pathExtension.lowercased()) ? trimmed : trimmed + "." + (url.pathExtension.isEmpty ? "md" : url.pathExtension)
        let destination = url.deletingLastPathComponent().appendingPathComponent(fileName)
        guard destination.lastPathComponent != url.lastPathComponent else { completion(nil); return }
        // A change only in letter case names the same file on a case-insensitive disk.
        let sameFile = { (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject) == (try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject) }
        if FileManager.default.fileExists(atPath: destination.path), !sameFile() {
            refused("A file named “\(fileName)” already exists in this folder."); return
        }
        let finish = { [weak self] (error: Error?) in
            self?.app?.refreshFolders()
            completion(error)
        }
        if let doc = app.controller.documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) as? MarkdownDocument {
            doc.move(to: destination) { error in
                if error == nil {
                    doc.editor?.loadMetadata()
                }
                finish(error)
            }
            return
        }
        var coordinationError: NSError?, moveError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &coordinationError) { from, to in
            do { try FileManager.default.moveItem(at: from, to: to); coordinator.item(at: from, didMoveTo: to) }
            catch { moveError = error }
        }
        finish(coordinationError ?? moveError)
    }

    func quickOpenItems(for host: EditorWindowController) -> [QuickOpenItem] {
        guard let app else { return [] }
        var items: [QuickOpenItem] = [], seen = Set<String>()
        func folder(of url: URL) -> String {
            let directory = url.deletingLastPathComponent().path
            if let workspace = host.workspace, directory == workspace.path || directory.hasPrefix(workspace.path + "/") {
                return workspace.lastPathComponent + directory.dropFirst(workspace.path.count)
            }
            return (directory as NSString).abbreviatingWithTildeInPath
        }
        func add(_ name: String, _ url: URL?, _ target: QuickOpenItem.Target) {
            if let path = url?.standardizedFileURL.path {
                guard seen.insert(path).inserted else { return }
            }
            items.append(QuickOpenItem(name: name, detail: url.map(folder(of:)) ?? "Open, not saved", target: target))
        }
        let here = host.documents
        let others = app.controller.documents.compactMap { $0 as? MarkdownDocument }.filter { doc in !here.contains { $0 === doc } }
        for doc in here + others {
            add(doc.editorName, doc.fileURL, .document(doc))
        }
        for url in app.controller.recentDocumentURLs where FileManager.default.fileExists(atPath: url.path) {
            add(url.lastPathComponent, url, .file(url))
        }
        func files(_ entries: [FolderEntry]) {
            for entry in entries {
                if let children = entry.children {
                    files(children)
                } else {
                    let url = URL(fileURLWithPath: entry.path); add(entry.name, url, .file(url))
                }
            }
        }
        files(host.workspaceTree?.children ?? [])
        return items
    }
}
