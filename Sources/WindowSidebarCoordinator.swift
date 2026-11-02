import Cocoa

/// Owns one window's workspace scans and its sidebar observations.
final class WindowSidebarCoordinator {
    private weak var host: EditorWindowController?
    private var collapseObservation: NSKeyValueObservation?
    private var sidebarStateObserver: NSObjectProtocol?
    private var applyingSidebarState = false
    private var workspaceScan = 0
    private(set) var workspaceTree: FolderEntry?
    var workspace: URL? {
        didSet {
            guard workspace != oldValue else { return }
            workspaceTree = nil; workspaceScan += 1
            host?.sidebar.setFolder(nil)
            refreshFolder()
            host?.workspaceDidChange()
        }
    }

    private var app: AppDelegate? {
        (NSDocumentController.shared as? DocumentController)?.app
    }

    init(host: EditorWindowController) {
        self.host = host
    }

    deinit {
        if let sidebarStateObserver {
            NotificationCenter.default.removeObserver(sidebarStateObserver)
        }
    }

    func connect() {
        guard let host else { return }
        let sidebar = host.sidebar
        sidebar.onSelectOpenFile = { [weak host] id in
            if let doc = host?.document(id: id) {
                host?.select(doc)
            }
        }
        sidebar.onCloseOpenFile = { [weak host] id in
            if let doc = host?.document(id: id) {
                host?.close(doc)
            }
        }
        sidebar.onMoveOpenFile = { [weak host] id, index in
            if let doc = host?.document(id: id) {
                host?.move(doc, to: index)
            }
        }
        sidebar.onOpenPath = { [weak host] path in host?.openWorkspaceFile(path) }
        sidebar.onNewFile = { [weak self, weak host] folder in
            guard let host, let window = host.window else { return }
            do { try self?.app?.createWorkspaceFile(in: URL(fileURLWithPath: folder), in: host) }
            catch { host.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
        sidebar.onRename = { [weak self, weak host] path, name in
            guard let host else { return }
            self?.app?.renameWorkspaceFile(URL(fileURLWithPath: path), to: name, in: host) { [weak host] error in
                guard let host, let error, let window = host.window else { return }
                host.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
        sidebar.onReveal = { [weak host] pos in
            guard let host, let editor = host.currentEditor else { return }
            host.window?.makeFirstResponder(editor.webView)
            editor.send("reveal", pos)
        }
        sidebar.onAction = { [weak self, weak host] action in
            switch action {
            case "new": self?.app?.newDocument(nil)
            case "open": NSDocumentController.shared.openDocument(nil)
            case "openFolder": self?.app?.openFolder(nil)
            case "refreshFolder": self?.refreshFolder()
            case "toggleSidebar": host?.toggleSidebar()
            default: break
            }
        }
        collapseObservation = host.sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self, weak host] item, _ in
            guard let self, let host else { return }
            for doc in host.documents {
                doc.editor?.send("sidebar", ["open": !item.isCollapsed])
            }
            if !self.applyingSidebarState {
                host.sidebar.state.collapsed = item.isCollapsed
            }
        }
        host.splitController.onResize = { [weak self, weak host] in
            guard let self, let host, !self.applyingSidebarState, !host.sidebarItem.isCollapsed, host.sidebarWidth > 0 else { return }
            host.sidebar.state.width = host.sidebarWidth
        }
        sidebarStateObserver = NotificationCenter.default.addObserver(forName: .sidebarStateChanged, object: sidebar.state, queue: .main) { [weak self, weak host] _ in
            self?.applySidebarState(animated: host?.window?.isKeyWindow == true)
        }
        applySidebarState(animated: false)
    }

    private func applySidebarState(animated: Bool) {
        guard let host else { return }
        let state = host.sidebar.state
        applyingSidebarState = true
        defer { applyingSidebarState = false }
        if host.sidebarItem.isCollapsed != state.collapsed {
            if animated {
                host.sidebarItem.animator().isCollapsed = state.collapsed
            } else {
                host.sidebarItem.isCollapsed = state.collapsed
            }
        }
        if !state.collapsed, abs(host.sidebarWidth - state.width) > 0.5, host.splitController.splitView.arrangedSubviews.count > 1 {
            host.splitController.splitView.setPosition(state.width, ofDividerAt: 0)
        }
    }

    /// Only the newest scan may apply; changing or clearing the workspace invalidates pending scans.
    func refreshFolder(completion: @escaping () -> Void = {}) {
        guard let workspace else { completion(); return }
        workspaceScan += 1
        let scan = workspaceScan
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tree = WorkspaceScanner.scan(workspace)
            DispatchQueue.main.async {
                defer { completion() }
                guard let self, scan == self.workspaceScan, tree != self.workspaceTree else { return }
                self.workspaceTree = tree
                self.host?.sidebar.setFolder(tree)
            }
        }
    }
}
