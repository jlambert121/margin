import Cocoa

final class SidebarFileActions: NSObject {
    private weak var host: SidebarViewController?
    private(set) var renamingPath: String?
    private var renameCancelled = false
    init(host: SidebarViewController) {
        self.host = host
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let host else { return }
        let filesView = host.filesView
        let folder = host.folder
        guard filesView.clickedRow >= 0, let node = filesView.item(atRow: filesView.clickedRow) as? SidebarNode else { return }
        func add(_ title: String, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = run; menu.addItem(item)
        }
        switch node.kind {
        case let .header(_, workspace) where workspace:
            if let folder {
                add("New File") { [weak self] in self?.host?.onNewFile(folder.path) }
            }
        case let .folder(entry, _):
            add("New File") { [weak self] in self?.host?.onNewFile(entry.path) }
            menu.addItem(.separator())
            add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        case let .file(entry):
            add("New File") { [weak self] in self?.host?.onNewFile((entry.path as NSString).deletingLastPathComponent) }
            add("Rename") { [weak self] in self?.beginRename(path: entry.path) }
            menu.addItem(.separator())
            add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        default: break
        }
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    /// Edits the file's name in its row, with the name before the extension selected.
    func beginRename(path: String) {
        guard renamingPath == nil else { return }
        guard let host, let field = host.prepareRename(path: path) else { return }
        renamingPath = path; renameCancelled = false
        field.isEditable = true; field.delegate = host
        host.view.window?.makeFirstResponder(field)
        let name = field.stringValue as NSString
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: name.deletingPathExtension.count)
    }

    func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renamingPath != nil, control !== host?.filterField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        renameCancelled = true
        host?.view.window?.makeFirstResponder(host?.filesView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let path = renamingPath, let field = notification.object as? NSTextField, field !== host?.filterField else { return }
        finishRename(path: path, name: field.stringValue, cancelled: renameCancelled)
    }

    /// The row goes back to a label either way; a successful rename then refreshes the tree.
    func finishRename(path: String, name: String, cancelled: Bool = false) {
        renamingPath = nil
        host?.renameDidEnd(path: path, name: name, cancelled: cancelled)
    }
}
