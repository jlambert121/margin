import Cocoa

/// Reports divider drags, which NSSplitViewController's own delegate role hides.
final class EditorSplitViewController: NSSplitViewController {
    var onResize: () -> Void = {}
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        onResize()
    }
}

/// A window and its open documents, in the order the sidebar's Open Files lists them.
/// It shows one document's editor at a time and keeps the others loaded.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) var documents: [MarkdownDocument] = []
    private(set) var current: MarkdownDocument?
    var currentEditor: DocumentEditor? {
        current?.editor
    }

    let sidebar = SidebarViewController()
    let splitController = EditorSplitViewController()
    let sidebarItem: NSSplitViewItem
    private let content = NSView()
    private lazy var sidebarCoordinator = WindowSidebarCoordinator(host: self)
    private var closingAll = false
    private var pendingClose: ((Bool) -> Void)?
    var workspace: URL? {
        get { sidebarCoordinator.workspace }
        set { sidebarCoordinator.workspace = newValue }
    }

    var workspaceTree: FolderEntry? {
        sidebarCoordinator.workspaceTree
    }

    private var app: AppDelegate? {
        (NSDocumentController.shared as? DocumentController)?.app
    }

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
        sidebarCoordinator.connect()
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged(_:)), name: .openFilesChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Documents

    /// New documents go after the current one; a document in another window moves here.
    func add(_ doc: MarkdownDocument, at index: Int? = nil) {
        if let other = doc.editor?.host, other !== self {
            other.remove(doc)
        }
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
                editor.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), editor.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        if !documents.contains(where: { $0 === doc }) {
            let position = index ?? current.flatMap { current in documents.firstIndex { $0 === current } }.map { $0 + 1 } ?? documents.count
            documents.insert(doc, at: min(position, documents.count))
        }
        if current == nil {
            select(doc)
        } else {
            refresh()
        }
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

    /// The neighbor below becomes current, or the one above for the last document.
    func remove(_ doc: MarkdownDocument) {
        guard let index = documents.firstIndex(where: { $0 === doc }) else { return }
        documents.remove(at: index)
        if doc.editor?.host === self {
            doc.editor?.host = nil
        }
        doc.editor?.view.removeFromSuperview()
        if current === doc {
            current = nil
            if !documents.isEmpty {
                select(documents[min(index, documents.count - 1)])
            }
        }
        if documents.isEmpty, !closingAll {
            close()
        } else {
            refresh()
        }
    }

    func move(_ doc: MarkdownDocument, to index: Int) {
        guard let from = documents.firstIndex(where: { $0 === doc }) else { return }
        documents.remove(at: from)
        documents.insert(doc, at: min(max(index > from ? index - 1 : index, 0), documents.count))
        refresh()
    }

    /// ⌘[ and ⌘] step through Open Files, wrapping at either end.
    func selectAdjacent(_ offset: Int) {
        guard let current, documents.count > 1, let index = documents.firstIndex(where: { $0 === current }) else { return }
        select(documents[(index + offset + documents.count) % documents.count])
    }

    func documentDidChange(_ doc: MarkdownDocument) {
        if documents.contains(where: { $0 === doc }) {
            refresh()
        }
    }

    @objc private func documentChanged(_ notification: Notification) {
        if let doc = notification.object as? MarkdownDocument {
            documentDidChange(doc)
        }
    }

    private func refresh() {
        let details = Self.openFileDetails(documents.map(\.fileURL), workspace: workspace)
        sidebar.setOpenFiles(zip(documents, details).map { doc, detail in
            OpenFileEntry(id: doc.recoveryID.uuidString, name: doc.editorName, path: doc.fileURL?.path ?? "", detail: detail, modified: doc.isDocumentEdited, current: doc === current)
        })
        sidebar.currentPath = current?.fileURL?.path ?? ""
        window?.title = current?.displayName ?? "Margin"
        window?.representedURL = current?.fileURL
        window?.isDocumentEdited = documents.contains { $0.isDocumentEdited }
        window?.invalidateRestorableState()
    }

    /// Files that share a name get the fewest trailing folders that tell them apart. Folders in the
    /// workspace start from its name, so a file at its root shows the workspace's name.
    static func openFileDetails(_ urls: [URL?], workspace: URL?) -> [String] {
        let root = workspace?.standardizedFileURL.resolvingSymlinksInPath().path
        func folders(_ url: URL) -> [String] {
            let directory = url.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
            if let root, directory == root || directory.hasPrefix(root + "/") {
                return [(root as NSString).lastPathComponent] + directory.dropFirst(root.count).split(separator: "/").map(String.init)
            }
            return (directory as NSString).abbreviatingWithTildeInPath.split(separator: "/").map(String.init)
        }
        var details = Array(repeating: "", count: urls.count)
        let named = Dictionary(grouping: urls.indices.filter { urls[$0] != nil }) { urls[$0]!.lastPathComponent }
        for indices in named.values where indices.count > 1 {
            let paths = indices.map { folders(urls[$0]!) }
            let longest = max(paths.map(\.count).max() ?? 0, 1)
            let count = (1 ... longest).first { count in Set(paths.map { $0.suffix(count).joined(separator: "/") }).count == paths.count } ?? longest
            for (index, path) in zip(indices, paths) {
                details[index] = path.suffix(count).joined(separator: "/")
            }
        }
        return details
    }

    func document(id: String) -> MarkdownDocument? {
        documents.first { $0.recoveryID.uuidString == id }
    }

    // MARK: Closing

    /// ⌘W closes the current document, asking about unsaved changes over it.
    @objc func closeDocument(_ sender: Any?) {
        guard let current else { window?.performClose(sender); return }
        close(current)
    }

    func close(_ doc: MarkdownDocument, then next: @escaping (Bool) -> Void = { _ in }) {
        pendingClose = next
        doc.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo _: UnsafeMutableRawPointer?) {
        let next = pendingClose
        pendingClose = nil
        if shouldClose {
            document.close()
        }
        next?(shouldClose)
    }

    /// The window's close button closes each document in turn, and stops if one is kept.
    func windowShouldClose(_: NSWindow) -> Bool {
        guard let first = documents.first else { return true }
        closingAll = true
        close(first) { [weak self] closed in
            guard let self else { return }
            self.closingAll = false
            if !closed {
                return
            }
            if self.documents.isEmpty {
                self.close()
            } else {
                self.window?.performClose(nil)
            }
        }
        return false
    }

    func windowWillClose(_: Notification) {
        app?.windowDidClose(self)
    }

    // MARK: Commands for the current document

    /// Save, Revert, and similar document commands reach the current document.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let current, current.responds(to: action) {
            return current
        }
        if let editor = currentEditor, editor.responds(to: action) {
            return editor
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    @objc func undoDocument(_: Any?) {
        current?.undoManager?.undo()
    }

    @objc func redoDocument(_: Any?) {
        current?.undoManager?.redo()
    }

    @objc func printDocument(_ sender: Any?) {
        currentEditor?.printDocument(sender)
    }

    // MARK: Sidebar

    func workspaceDidChange() {
        refresh()
        window?.invalidateRestorableState()
    }

    /// The pane's width, which the divider position sets. The sidebar's own view
    /// can sit inset within it.
    var sidebarWidth: CGFloat {
        splitController.splitView.arrangedSubviews.first?.frame.width ?? 0
    }

    func toggleSidebar() {
        sidebar.state.collapsed.toggle()
    }

    func showOutline() {
        sidebar.state.collapsed = false; sidebar.state.mode = .outline
    }

    /// Workspace clicks may name only Markdown files inside the open folder.
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

    func refreshFolder(completion: @escaping () -> Void = {}) {
        sidebarCoordinator.refreshFolder(completion: completion)
    }

    // MARK: Restoration

    func window(_: NSWindow, willEncodeRestorableState state: NSCoder) {
        WindowRestoration.encode(WindowRestoration.snapshot(self), to: state)
    }

    func restore(from state: NSCoder, completion: @escaping () -> Void) {
        WindowRestoration.restore(self, from: state, completion: completion)
    }
}
