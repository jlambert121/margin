import Cocoa
import OSLog
import UniformTypeIdentifiers
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var workspaceActions = WorkspaceActions(app: self)
    private(set) var quickOpen: QuickOpenController?
    var controller: DocumentController!
    let recoveryStore: RecoveryStore
    let settings: Settings
    private var settingsWindow: SettingsWindowController?
    private var launchFinished = false
    private var restorationFinished = false
    private var startupCompleted = false
    private var restoringWindows = 0
    private(set) var windows: [EditorWindowController] = []
    /// Only windows still open count; AppKit can keep listing one after it closes.
    var currentWindow: EditorWindowController? {
        let front = (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? EditorWindowController
        return front.flatMap { host in windows.contains { $0 === host } ? host : nil }
    }

    var currentEditor: DocumentEditor? {
        currentWindow?.currentEditor
    }

    init(controller: DocumentController? = nil, recoveryStore: RecoveryStore = .shared, settings: Settings = Settings()) {
        self.controller = controller
        self.recoveryStore = recoveryStore
        self.settings = settings
        super.init()
        controller?.app = self
    }

    func applicationWillFinishLaunching(_: Notification) {
        if controller == nil {
            controller = DocumentController()
        }
        controller.app = self
        // A window switches between its documents, so macOS's window tabs are not used.
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidFinishRestoringWindows(_:)), name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        buildMenu()
        applySettings()
    }

    /// Files added in other applications show up when Margin comes back to the front.
    func applicationDidBecomeActive(_: Notification) {
        refreshFolders()
    }

    func applicationDidFinishLaunching(_: Notification) {
        launchFinished = true
        if #available(macOS 14, *) {
            NSApp?.activate()
        } else {
            NSApp?.activate(ignoringOtherApps: true)
        }
        finishStartupIfReady()
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    @objc func applicationDidFinishRestoringWindows(_: Notification) {
        restorationFinished = true
        finishStartupIfReady()
    }

    private func finishStartupIfReady() {
        // Restoration can finish after didFinishLaunching. Wait for both it
        // and launch-time file opens before deciding whether a welcome is needed.
        guard launchFinished, restorationFinished, restoringWindows == 0, !controller.isOpening, !startupCompleted else { return }
        startupCompleted = true
        do {
            let failures = try recoverDocuments()
            if let first = failures.first {
                controller.presentError(NSError(domain: "Margin.Recovery", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Some recovery copies could not be opened.",
                    NSLocalizedRecoverySuggestionErrorKey: "The copies have been kept in \(recoveryStore.directory.path).",
                    NSUnderlyingErrorKey: first,
                ]))
            }
        } catch { controller.presentError(error) }
        if controller.documents.isEmpty {
            do {
                let doc = try controller.makeUntitledDocument(ofType: markdownType)
                if let markdown = doc as? MarkdownDocument, let welcome = MarkdownDocument.welcomeText() {
                    markdown.text = welcome; markdown.isWelcome = true
                }
                controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            } catch { controller.presentError(error) }
        }
    }

    /// Recovery always creates untitled copies. A draft must never silently
    /// replace a file that another application may have changed after a crash.
    func recoverDocuments(display: Bool = true) throws -> [Error] {
        try ApplicationDocumentRestorer.recoverDocuments(controller: controller, recoveryStore: recoveryStore, display: display)
    }

    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func documentOpensFinished() {
        finishStartupIfReady()
    }

    // MARK: Windows

    func makeWindow() -> EditorWindowController {
        let host = EditorWindowController()
        if let front = currentWindow?.window ?? windows.last?.window, let window = host.window {
            window.setFrame(front.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        }
        windows.append(host)
        return host
    }

    func windowDidClose(_ host: EditorWindowController) {
        windows.removeAll { $0 === host }
    }

    private var frontWindow: EditorWindowController? {
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? EditorWindowController }.first { host in self.windows.contains { $0 === host } }
        return currentWindow ?? front ?? windows.last
    }

    /// Finder, Dock, File › Open, and new documents join the frontmost window.
    func windowForNewDocuments() -> EditorWindowController {
        frontWindow ?? makeWindow()
    }

    @objc func newWindow(_: Any?) {
        makeWindowWithUntitledDocument()
    }

    @discardableResult private func makeWindowWithUntitledDocument() -> EditorWindowController? {
        do {
            let doc = try controller.makeUntitledDocument(ofType: markdownType)
            controller.addDocument(doc)
            guard let markdown = doc as? MarkdownDocument else { return nil }
            let host = makeWindow()
            host.add(markdown)
            markdown.showWindows()
            return host
        } catch { controller.presentError(error); return nil }
    }

    /// Drops, workspace clicks, and Quick Open name their window. A document already
    /// open elsewhere is shown where it is.
    func open(_ urls: [URL], in host: EditorWindowController, opened: @escaping (NSDocument) -> Void = { _ in }) {
        for url in urls {
            controller.openDocument(withContentsOf: url, display: false) { [weak self] document, alreadyOpen, error in
                if let error {
                    self?.controller.presentError(error); return
                }
                guard let document = document as? MarkdownDocument else { return }
                if !(alreadyOpen && document.editor?.host != nil) {
                    host.add(document)
                }
                document.showWindows()
                opened(document)
            }
        }
    }

    @objc func previousFile(_: Any?) {
        currentWindow?.selectAdjacent(-1)
    }

    @objc func nextFile(_: Any?) {
        currentWindow?.selectAdjacent(1)
    }

    /// Restoration reopens each window's documents before deciding whether a welcome is needed.
    func beginRestoring() {
        restoringWindows += 1
    }

    func endRestoring() {
        restoringWindows -= 1; finishStartupIfReady()
    }

    func restoreDocument(_ entry: [String: Any], completion: @escaping (MarkdownDocument?) -> Void) {
        ApplicationDocumentRestorer.restoreDocument(entry, controller: controller, completion: completion)
    }

    /// An empty Markdown file with an unused name, opened as a tab and ready to rename.
    func createWorkspaceFile(in folder: URL, in host: EditorWindowController) throws {
        try workspaceActions.createWorkspaceFile(in: folder, in: host)
    }

    /// Keeps a Markdown extension, adding the file's own when the name has none. A file
    /// open in a tab moves with its document, which keeps the tab and any unsaved edits.
    func renameWorkspaceFile(_ url: URL, to name: String, in host: EditorWindowController, completion: @escaping (Error?) -> Void) {
        workspaceActions.renameWorkspaceFile(url, to: name, in: host, completion: completion)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard startupCompleted else { return true }
        if !flag {
            if controller.documents.isEmpty {
                newDocument(nil)
            } else {
                controller.documents.forEach { $0.showWindows() }
            }
        }
        return true
    }

    @objc func newDocument(_: Any?) {
        do { try controller.openUntitledDocumentAndDisplay(true) }
        catch { controller.presentError(error) }
    }

    /// The folder replaces the one in the window it was chosen from, or opens in a new
    /// window when none is open. Other windows keep their folders.
    @objc func openFolder(_: Any?) {
        let target = frontWindow
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"; panel.message = "Choose a folder of Markdown files."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let host = target.flatMap { target in self.windows.contains { $0 === target } ? target : nil } ?? self.makeWindowWithUntitledDocument()
            host?.workspace = url
        }
    }

    func refreshFolders(completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        for host in windows {
            group.enter(); host.refreshFolder { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    @objc func webCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        currentEditor?.send(parts[0], parts.count > 1 ? parts[1] : nil)
    }

    @objc func exportHTML(_: Any?) {
        currentEditor?.send("exportHTML")
    }

    @objc func toggleSidebar(_: Any?) {
        currentWindow?.toggleSidebar()
    }

    @objc func showQuickOpen(_: Any?) {
        if let currentWindow {
            showQuickOpen(for: currentWindow)
        }
    }

    func showQuickOpen(for host: EditorWindowController) {
        guard let window = host.window else { return }
        quickOpen?.close()
        let picker = QuickOpenController(items: quickOpenItems(for: host)) { [weak self, weak host] item in
            guard let host else { return }
            switch item.target {
            case let .document(doc): doc.showWindows()
            case let .file(url): self?.open([url], in: host)
            }
        }
        picker.onClose = {
            [weak self, weak picker] in if self?.quickOpen === picker {
                self?.quickOpen = nil
            }
        }
        quickOpen = picker
        picker.show(over: window)
    }

    /// This window's documents, then other open documents, recent files, and the files in this window's folder.
    func quickOpenItems(for host: EditorWindowController) -> [QuickOpenItem] {
        workspaceActions.quickOpenItems(for: host)
    }

    @objc func pasteAndMatchStyle(_: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        currentEditor?.send("pastePlain", text)
    }

    @objc func showOutline(_: Any?) {
        currentWindow?.showOutline()
    }

    @objc func zoomIn(_: Any?) {
        setTextZoom(settings.zoomedIn())
    }

    @objc func zoomOut(_: Any?) {
        setTextZoom(settings.zoomedOut())
    }

    @objc func actualSize(_: Any?) {
        setTextZoom(1)
    }

    func setTextZoom(_ zoom: Double) {
        settings.textZoom = zoom
        for doc in controller.documents {
            (doc as? MarkdownDocument)?.editor?.send("textZoom", zoom)
        }
        currentEditor?.send("toast", "Text size \(Int((zoom * 100).rounded()))%")
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in self?.applySettings() }
        }
        settingsWindow?.refresh()
        settingsWindow?.showWindow(sender)
    }

    @objc func makeDefaultMarkdownEditor(_: Any?) {
        guard let markdown = UTType(markdownType) else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: markdown) { error in
            DispatchQueue.main.async {
                let alert = NSAlert()
                if let error {
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn’t make Margin the default Markdown editor"
                    alert.informativeText = error.localizedDescription
                } else {
                    alert.messageText = "Margin is now the default Markdown editor"
                }
                alert.runModal()
            }
        }
    }

    func applySettings() {
        NSApp?.appearance = settings.appearance.appearance
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in controller.recentDocumentURLs {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = url; menu.addItem(entry)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = controller; menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        controller.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }

    func buildMenu() {
        NSApp.mainMenu = makeMenu()
    }

    func makeMenu() -> NSMenu {
        AppMenuBuilder.makeMenu(owner: self)
    }
}
