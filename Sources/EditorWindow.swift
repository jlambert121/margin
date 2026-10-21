import Cocoa

// Reports divider drags, which NSSplitViewController's own delegate role hides.
final class EditorSplitViewController: NSSplitViewController {
    var onResize: () -> Void = {}
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize()
    }
}

// A window and its open documents, in the order the sidebar's Open Files lists them.
// It shows one document's editor at a time and keeps the others loaded.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) var documents: [MarkdownDocument] = []
    private(set) var current: MarkdownDocument?
    var currentEditor: DocumentEditor? { current?.editor }
    let sidebar = SidebarViewController()
    let splitController = EditorSplitViewController()
    let sidebarItem: NSSplitViewItem
    private let content = NSView()
    private var collapseObservation: NSKeyValueObservation?
    private var sidebarStateObserver: NSObjectProtocol?
    private var applyingSidebarState = false
    private var closingAll = false
    private var pendingClose: ((Bool) -> Void)?
    // The folder this window's sidebar lists, and its Markdown files as of the last scan.
    var workspace: URL? {
        didSet {
            guard workspace != oldValue else { return }
            workspaceTree = nil; workspaceScan += 1
            sidebar.setFolder(nil)
            refreshFolder()
            window?.invalidateRestorableState()
        }
    }
    private(set) var workspaceTree: FolderEntry?
    private var workspaceScan = 0
    private var app: AppDelegate? { (NSDocumentController.shared as? DocumentController)?.app }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 480)
        window.titlebarAppearsTransparent = true
        // The toolbar shows the document's name.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("MarkdownEditor")
        window.tabbingMode = .disallowed
        window.isRestorable = true
        window.restorationClass = EditorWindowRestoration.self
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180; sidebarItem.maximumThickness = 420
        let contentController = NSViewController()
        contentController.view = content
        splitController.splitViewItems = [sidebarItem, NSSplitViewItem(viewController: contentController)]
        splitController.view.frame = NSRect(x: 0, y: 0, width: 1180, height: 820)
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: 1180, height: 820))
        window.center()
        super.init(window: window)
        window.delegate = self
        // Set on the controller, after init: adopting the window replaces the
        // window's own autosave name with the controller's, which defaults to empty.
        windowFrameAutosaveName = "MarginEditor"
        connectSidebar()
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged(_:)), name: .openFilesChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        NotificationCenter.default.removeObserver(self)
        if let sidebarStateObserver { NotificationCenter.default.removeObserver(sidebarStateObserver) }
    }

    // MARK: Documents

    // New documents go after the current one; a document in another window moves here.
    func add(_ doc: MarkdownDocument, at index: Int? = nil) {
        if let other = doc.editor?.host, other !== self { other.remove(doc) }
        let editor = doc.makeEditor()
        editor.host = self
        // Every editor stays in the window, hidden unless current: WebKit does not finish
        // loading a page that is not in a window, and saving reads the page's text.
        if editor.view.superview !== content {
            editor.view.removeFromSuperview()
            editor.view.isHidden = true
            editor.view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(editor.view)
            NSLayoutConstraint.activate([
                editor.view.topAnchor.constraint(equalTo: content.topAnchor), editor.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                editor.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), editor.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
        if !documents.contains(where: { $0 === doc }) {
            let position = index ?? current.flatMap { current in documents.firstIndex { $0 === current } }.map { $0 + 1 } ?? documents.count
            documents.insert(doc, at: min(position, documents.count))
        }
        if current == nil { select(doc) } else { refresh() }
    }
    func select(_ doc: MarkdownDocument) {
        guard documents.contains(where: { $0 === doc }), let editor = doc.editor else { return }
        if current !== doc {
            currentEditor?.view.isHidden = true
            current = doc
            editor.view.isHidden = false
            // Otherwise a window shown for the first time focuses the first field it finds, the sidebar's.
            window?.initialFirstResponder = editor.webView
            window?.makeFirstResponder(editor.webView)
            sidebar.setHeadings(editor.headings)
        }
        refresh()
    }
    // The neighbor below becomes current, or the one above for the last document.
    func remove(_ doc: MarkdownDocument) {
        guard let index = documents.firstIndex(where: { $0 === doc }) else { return }
        documents.remove(at: index)
        if doc.editor?.host === self { doc.editor?.host = nil }
        doc.editor?.view.removeFromSuperview()
        if current === doc {
            current = nil
            if !documents.isEmpty { select(documents[min(index, documents.count - 1)]) }
        }
        if documents.isEmpty, !closingAll { close() } else { refresh() }
    }
    func move(_ doc: MarkdownDocument, to index: Int) {
        guard let from = documents.firstIndex(where: { $0 === doc }) else { return }
        documents.remove(at: from)
        documents.insert(doc, at: min(max(index > from ? index - 1 : index, 0), documents.count))
        refresh()
    }
    // ⌘[ and ⌘] step through Open Files, wrapping at either end.
    func selectAdjacent(_ offset: Int) {
        guard let current, documents.count > 1, let index = documents.firstIndex(where: { $0 === current }) else { return }
        select(documents[(index + offset + documents.count) % documents.count])
    }
    func documentDidChange(_ doc: MarkdownDocument) { if documents.contains(where: { $0 === doc }) { refresh() } }
    @objc private func documentChanged(_ notification: Notification) {
        if let doc = notification.object as? MarkdownDocument { documentDidChange(doc) }
    }
    private func refresh() {
        sidebar.setOpenFiles(documents.map { doc in
            OpenFileEntry(id: doc.recoveryID.uuidString, name: doc.editorName, path: doc.fileURL?.path ?? "", modified: doc.isDocumentEdited, current: doc === current)
        })
        sidebar.currentPath = current?.fileURL?.path ?? ""
        window?.title = current?.displayName ?? "Margin"
        window?.representedURL = current?.fileURL
        window?.isDocumentEdited = documents.contains { $0.isDocumentEdited }
        window?.invalidateRestorableState()
    }
    private func document(id: String) -> MarkdownDocument? { documents.first { $0.recoveryID.uuidString == id } }

    // MARK: Closing

    // ⌘W closes the current document, asking about unsaved changes over it.
    @objc func closeDocument(_ sender: Any?) {
        guard let current else { window?.performClose(sender); return }
        close(current)
    }
    func close(_ doc: MarkdownDocument, then next: @escaping (Bool) -> Void = { _ in }) {
        pendingClose = next
        doc.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }
    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let next = pendingClose
        pendingClose = nil
        if shouldClose { document.close() }
        next?(shouldClose)
    }
    // The window's close button closes each document in turn, and stops if one is kept.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let first = documents.first else { return true }
        closingAll = true
        close(first) { [weak self] closed in
            guard let self else { return }
            self.closingAll = false
            if !closed { return }
            if self.documents.isEmpty { self.close() } else { self.window?.performClose(nil) }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) { app?.windowDidClose(self) }

    // MARK: Commands for the current document

    // Save, Revert, and similar document commands reach the current document.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let current, current.responds(to: action) { return current }
        if let editor = currentEditor, editor.responds(to: action) { return editor }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
    @objc func undoDocument(_ sender: Any?) { current?.undoManager?.undo() }
    @objc func redoDocument(_ sender: Any?) { current?.undoManager?.redo() }
    @objc func printDocument(_ sender: Any?) { currentEditor?.printDocument(sender) }

    // MARK: Sidebar

    private func connectSidebar() {
        sidebar.onSelectOpenFile = { [weak self] id in if let doc = self?.document(id: id) { self?.select(doc) } }
        sidebar.onCloseOpenFile = { [weak self] id in if let doc = self?.document(id: id) { self?.close(doc) } }
        sidebar.onMoveOpenFile = { [weak self] id, index in if let doc = self?.document(id: id) { self?.move(doc, to: index) } }
        sidebar.onOpenPath = { [weak self] path in self?.openWorkspaceFile(path) }
        sidebar.onNewFile = { [weak self] folder in
            guard let self, let window = self.window else { return }
            do { try self.app?.createWorkspaceFile(in: URL(fileURLWithPath: folder), in: self) }
            catch { self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
        sidebar.onRename = { [weak self] path, name in
            guard let self else { return }
            self.app?.renameWorkspaceFile(URL(fileURLWithPath: path), to: name, in: self) { [weak self] error in
                guard let self, let error, let window = self.window else { return }
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
        sidebar.onReveal = { [weak self] pos in
            guard let self, let editor = self.currentEditor else { return }
            self.window?.makeFirstResponder(editor.webView)
            editor.send("reveal", pos)
        }
        sidebar.onAction = { [weak self] action in
            switch action {
            case "new": self?.app?.newDocument(nil)
            case "open": NSDocumentController.shared.openDocument(nil)
            case "openFolder": self?.app?.openFolder(nil)
            case "refreshFolder": self?.refreshFolder()
            case "toggleSidebar": self?.toggleSidebar()
            default: break
            }
        }
        collapseObservation = sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            for doc in self.documents { doc.editor?.send("sidebar", ["open": !item.isCollapsed]) }
            if !self.applyingSidebarState { self.sidebar.state.collapsed = item.isCollapsed }
        }
        splitController.onResize = { [weak self] in
            guard let self, !self.applyingSidebarState, !self.sidebarItem.isCollapsed, self.sidebarWidth > 0 else { return }
            self.sidebar.state.width = self.sidebarWidth
        }
        sidebarStateObserver = NotificationCenter.default.addObserver(forName: .sidebarStateChanged, object: sidebar.state, queue: .main) { [weak self] _ in
            self?.applySidebarState(animated: self?.window?.isKeyWindow == true)
        }
        applySidebarState(animated: false)
    }
    private func applySidebarState(animated: Bool) {
        let state = sidebar.state
        applyingSidebarState = true
        defer { applyingSidebarState = false }
        if sidebarItem.isCollapsed != state.collapsed {
            if animated { sidebarItem.animator().isCollapsed = state.collapsed } else { sidebarItem.isCollapsed = state.collapsed }
        }
        if !state.collapsed, abs(sidebarWidth - state.width) > 0.5, splitController.splitView.arrangedSubviews.count > 1 {
            splitController.splitView.setPosition(state.width, ofDividerAt: 0)
        }
    }
    // The pane's width, which the divider position sets. The sidebar's own view
    // can sit inset within it.
    var sidebarWidth: CGFloat { splitController.splitView.arrangedSubviews.first?.frame.width ?? 0 }
    func toggleSidebar() { sidebar.state.collapsed.toggle() }
    func showOutline() { sidebar.state.collapsed = false; sidebar.state.mode = .outline }
    // Workspace clicks may name only Markdown files inside the open folder.
    func openWorkspaceFile(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard let app, isInWorkspace(url), markdownExtensions.contains(url.pathExtension.lowercased()) else { return }
        app.open([url], in: self)
    }
    func isInWorkspace(_ url: URL) -> Bool {
        guard let workspace else { return false }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path, root = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }
    // Scans off the main thread; only the newest scan's result is kept.
    func refreshFolder(completion: @escaping () -> Void = {}) {
        guard let workspace else { completion(); return }
        workspaceScan += 1
        let scan = workspaceScan
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = AppDelegate.scanFolder(workspace)
            DispatchQueue.main.async {
                defer { completion() }
                guard let self, scan == self.workspaceScan, tree != self.workspaceTree else { return }
                self.workspaceTree = tree
                self.sidebar.setFolder(tree)
            }
        }
    }

    // MARK: Restoration

    // Each document by its file, or by its autosaved copy when it was never saved, and the open folder.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let entries: [[String: Any]] = documents.compactMap { doc in
            var entry: [String: Any] = ["recoveryID": doc.recoveryID.uuidString, "welcome": doc.isWelcome]
            if let path = doc.fileURL?.path { entry["path"] = path }
            else if let autosaved = doc.autosavedContentsFileURL?.path { entry["autosaved"] = autosaved }
            else if !doc.isWelcome, doc.isDocumentEdited { return nil }
            if let name = doc.recoveredName { entry["recoveredName"] = name }
            if let original = doc.recoveredOriginalURL?.path { entry["recoveredOriginalPath"] = original }
            return entry
        }
        state.encode(entries, forKey: "Margin.documents")
        state.encode(current.flatMap { current in documents.firstIndex { $0 === current } } ?? 0, forKey: "Margin.current")
        if let workspace { state.encode(workspace.path as NSString, forKey: "Margin.workspace") }
    }
    func restore(from state: NSCoder, completion: @escaping () -> Void) {
        let allowed = [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self]
        let entries = state.decodeObject(of: allowed, forKey: "Margin.documents") as? [[String: Any]] ?? []
        let selected = state.decodeInteger(forKey: "Margin.current")
        var isFolder: ObjCBool = false
        if let path = state.decodeObject(of: NSString.self, forKey: "Margin.workspace") as String?,
           FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { workspace = URL(fileURLWithPath: path) }
        guard let app, !entries.isEmpty else { completion(); return }
        var restored = [MarkdownDocument?](repeating: nil, count: entries.count)
        var remaining = entries.count
        func finished(_ index: Int, _ doc: MarkdownDocument?) {
            restored[index] = doc
            remaining -= 1
            guard remaining == 0 else { return }
            for doc in restored.compactMap({ $0 }) { add(doc, at: documents.count) }
            if let doc = restored.indices.contains(selected) ? restored[selected] : nil { select(doc) }
            completion()
        }
        for (index, entry) in entries.enumerated() {
            app.restoreDocument(entry) { doc in finished(index, doc) }
        }
    }
}

final class EditorWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder, completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        guard let app = (NSDocumentController.shared as? DocumentController)?.app else { completionHandler(nil, CocoaError(.featureUnsupported)); return }
        let host = app.makeWindow()
        app.beginRestoring()
        host.restore(from: state) {
            app.endRestoring()
            if host.documents.isEmpty { host.close(); completionHandler(nil, CocoaError(.fileReadNoSuchFile)) }
            else { completionHandler(host.window, nil) }
        }
    }
}
