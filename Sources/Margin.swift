import Cocoa
import WebKit
import UniformTypeIdentifiers
import OSLog

let markdownType = "net.daringfireball.markdown"
let plainTextType = "public.plain-text"
let markdownExtensions = Set(["md", "markdown", "mdown", "mkd", "txt"])

extension Notification.Name {
    // Posted when a document's name, path, or unsaved state, or a window's tabs, change.
    static let openFilesChanged = Notification.Name("Margin.openFilesChanged")
}

// A version of the file that another application wrote while the document had unsaved edits.
struct DiskVersion: Equatable {
    let text: String
    let date: Date
}

// Info.plist uses this Objective-C name. An unqualified Swift class name does
// not resolve through NSClassFromString, so AppKit otherwise disables Open.
@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var text = ""
    // Created when the document first joins a window; kept while it is open.
    private(set) var editor: DocumentEditor?
    var recoveryStore = RecoveryStore.shared
    var recoveryID = UUID()
    var recoveredName: String?
    var recoveredOriginalURL: URL?
    var isWelcome = false
    var onRecoveryError: ((Error) -> Void)?
    var onDiskError: ((Error) -> Void)?
    private(set) var diskConflict: DiskVersion?
    private var unreadableDiskDate: Date?
    private var diskCheck: DispatchWorkItem?
    private var reverting = false
    private var revertNotice: String?
    private var checkpoint: DispatchWorkItem?
    private var uncountedEdit = false
    private var savesWaitingForEdit: [() -> Void] = []
    private var recoveryErrorReported = false
    var editorName: String { fileURL?.lastPathComponent ?? recoveredName ?? "Untitled.md" }
    override class var autosavesInPlace: Bool { true }
    override var fileURL: URL? { didSet { NotificationCenter.default.post(name: .openFilesChanged, object: self) } }
    // Every edit updates the change count; the open files only show whether it is unsaved.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        let wasEdited = isDocumentEdited
        super.updateChangeCount(change)
        if change == .changeDone, uncountedEdit { uncountedEdit = false; runSavesWaitingForEdit() }
        if isDocumentEdited != wasEdited { NotificationCenter.default.post(name: .openFilesChanged, object: self) }
    }
    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        let wasEdited = isDocumentEdited
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        if isDocumentEdited != wasEdited { NotificationCenter.default.post(name: .openFilesChanged, object: self) }
    }

    // Documents have no window controllers of their own: a window holds several and
    // shows one at a time. AppKit asks for windows when it opens or creates a document,
    // which then joins the frontmost window.
    override func makeWindowControllers() {
        guard editor?.host == nil else { return }
        (NSDocumentController.shared as? DocumentController)?.app?.windowForNewDocuments().add(self)
    }
    func makeEditor() -> DocumentEditor {
        if let editor { return editor }
        let editor = DocumentEditor(document: self)
        self.editor = editor
        return editor
    }
    override func showWindows() {
        if editor?.host == nil { makeWindowControllers() }
        editor?.host?.select(self)
        editor?.host?.showWindow(nil)
    }
    override var windowForSheet: NSWindow? { editor?.host?.window ?? super.windowForSheet }
    // Save prompts appear over the document they ask about.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        editor?.host?.select(self)
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
    override func data(ofType typeName: String) throws -> Data { Data(text.utf8) }
    // Markdown is a flat UTF-8 file; avoid NSFileWrapper's dependency on
    // LaunchServices file-kind lookups when reading and writing its bytes.
    override func read(from url: URL, ofType typeName: String) throws {
        try read(from: Data(contentsOf: url), ofType: typeName)
    }
    override func write(to url: URL, ofType typeName: String) throws {
        try data(ofType: typeName).write(to: url, options: .atomic)
    }
    override func read(from data: Data, ofType typeName: String) throws {
        text = try Self.decode(data)
        if !reverting { editor?.loadDocument() }
    }
    static func decode(_ data: Data) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "This file is not UTF-8 text. Convert it to UTF-8 before opening it."])
        }
        return decoded
    }
    // NSDocument clears the edited state only after reading, so the editor
    // loads the reverted text once that state is final.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        let conflict = diskConflict
        diskConflict = nil
        reverting = true
        defer { reverting = false }
        do { try super.revert(toContentsOf: url, ofType: typeName) }
        catch { diskConflict = conflict; editor?.loadDocument(); throw error }
        clearRecovery()
        editor?.loadDocument(notice: revertNotice)
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let savedText = text
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation {
            if text == savedText { clearRecovery() }
            else { flushRecovery() }
            clearDiskConflict()
            // macOS does not report another application's write that lands
            // within about half a second of this one, so look once it has passed.
            scheduleDiskCheck(after: 1.5)
            editor?.loadMetadata()
        }
    }
    static func welcomeText() -> String? {
        Bundle.main.url(forResource: "Welcome", withExtension: "md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
    func edited(_ next: String) {
        guard next != text else { return }
        isWelcome = false
        let previous = text
        let manager = undoManager
        manager?.registerUndo(withTarget: self) { doc in doc.restore(previous) }
        manager?.setActionName("Typing")
        text = next
        // NSDocument tracks undo groups itself. Explicitly incrementing as
        // well counts every edit twice and prevents Undo from clearing dirty.
        if manager == nil { updateChangeCount(.changeDone) } else { uncountedEdit = true }
        scheduleRecovery()
    }
    private func restore(_ next: String) {
        let previous = text
        undoManager?.registerUndo(withTarget: self) { doc in doc.restore(previous) }
        text = next
        scheduleRecovery()
        editor?.loadDocument()
    }
    private func scheduleRecovery() {
        // Throttle rather than debounce: continuous typing still gets a draft.
        guard checkpoint == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushRecovery() }
        checkpoint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }
    func flushRecovery() {
        checkpoint?.cancel(); checkpoint = nil
        // A just-received edit can still be inside the event's undo group;
        // NSDocument marks it dirty when that group closes on the run loop.
        guard isDocumentEdited || (undoManager?.groupingLevel ?? 0) > 0 else { clearRecovery(); return }
        let draft = RecoveryDraft(id: recoveryID, text: text, originalPath: (fileURL ?? recoveredOriginalURL)?.path, name: editorName)
        recoveryStore.writeAsync(draft) { [weak self] error in
            guard let self else { return }
            if let error { self.reportRecoveryError(error) }
            else { self.recoveryErrorReported = false }
        }
    }
    private func reportRecoveryError(_ error: Error) {
        guard !recoveryErrorReported else { return }
        recoveryErrorReported = true
        let failure = NSError(domain: "Margin.Recovery", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The recovery copy could not be updated.",
            NSLocalizedRecoverySuggestionErrorKey: "Your edits are still in memory. Save the document to protect them before quitting.",
            NSUnderlyingErrorKey: error
        ])
        if let onRecoveryError { onRecoveryError(failure) }
        else { presentError(failure) }
    }
    private func clearRecovery() {
        checkpoint?.cancel(); checkpoint = nil
        do { try recoveryStore.remove(recoveryID) }
        catch { reportRecoveryError(error) }
    }
    override func close() {
        // Normal document closing has already handled Save / Don't Save. A
        // process crash never reaches here, so its recovery copy remains.
        clearRecovery()
        diskCheck?.cancel(); diskCheck = nil
        editor?.host?.remove(self)
        editor?.tearDown()
        editor = nil
        super.close()
    }
    // A periodic autosave would raise AppKit's conflict alert over the editor's
    // own choice. Closing and quitting still autosave and ask through AppKit.
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        if autosavingIsImplicitlyCancellable, diskConflict != nil { completionHandler(CocoaError(.userCancelled)); return }
        // An untitled document's first autosave gives it the copy its window reopens it from.
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable) { [weak self] error in
            self?.editor?.host?.window?.invalidateRestorableState()
            completionHandler(error)
        }
    }
    // NSDocument hears when another application changes the file, but only
    // refuses the next save. A clean document reloads; an edited one keeps its
    // text while the editor offers the version on disk.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.scheduleDiskCheck() }
    }
    // Formatters and checkouts can write a file several times in a row.
    private func scheduleDiskCheck(after delay: TimeInterval = 0.2) {
        diskCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkDisk() }
        diskCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func checkDisk(completion: @escaping () -> Void = {}) {
        diskCheck = nil
        // Waits for saves and AppKit's own sheets about this file.
        performActivity(withSynchronousWaiting: false) { [weak self] activityCompletion in
            let finish = { activityCompletion(); completion() }
            guard let self else { finish(); return }
            // Edits still on their way from the editor decide whether reloading is safe.
            guard let editor = self.editor, editor.canSynchronize else { self.applyDiskChange(); finish(); return }
            editor.synchronize { synchronized in
                if synchronized { self.applyDiskChange() }
                finish()
            }
        }
    }
    private func applyDiskChange() {
        // A new URL, because URL caches resource values.
        guard let url = fileURL, fileType != nil,
              let date = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              date != fileModificationDate, date != diskConflict?.date, date != unreadableDiskDate else { return }
        let diskText: String
        do { diskText = try readDiskText(url) }
        catch {
            unreadableDiskDate = date
            reportDiskError(NSError(domain: "Margin.Disk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "“\(editorName)” changed on disk, but the new version could not be read.",
                NSLocalizedRecoverySuggestionErrorKey: "The editor still shows the earlier text. \(error.localizedDescription)",
                NSUnderlyingErrorKey: error
            ]))
            return
        }
        if diskText == text {
            fileModificationDate = date
            clearDiskConflict()
        } else if !isDocumentEdited {
            reloadFromDisk()
        } else {
            diskConflict = DiskVersion(text: diskText, date: date)
            editor?.send("diskChanged", diskText)
        }
    }
    private func readDiskText(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordinationError { throw coordinationError }
        return try Self.decode(result.get())
    }
    private func reportDiskError(_ error: Error) {
        if let onDiskError { onDiskError(error) }
        else if let window = windowForSheet { presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        else { presentError(error) }
    }
    func reloadFromDisk() {
        guard let url = fileURL, let fileType else { return }
        revertNotice = "Reloaded from disk"
        defer { revertNotice = nil }
        do { try revert(toContentsOf: url, ofType: fileType) }
        catch { reportDiskError(error) }
    }
    func confirmReloadFromDisk() {
        guard diskConflict != nil else { return }
        performActivity(withSynchronousWaiting: false) { [weak self] activityCompletion in
            guard let self, let window = self.windowForSheet else { activityCompletion(); return }
            let alert = NSAlert()
            alert.messageText = "Reload “\(self.editorName)” from disk?"
            alert.informativeText = "Your unsaved changes will be discarded and replaced by the version on disk."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { self.reloadFromDisk() }
                activityCompletion()
            }
        }
    }
    // Saving over the disk version is the choice the user just made, so
    // AppKit's check for a newer file must not ask again. A newer change still does.
    func keepMine() {
        guard diskConflict != nil else { return }
        let save = { [weak self] in
            guard let self, let conflict = self.diskConflict else { return }
            self.fileModificationDate = conflict.date
            self.save(withDelegate: self, didSave: #selector(self.document(_:didKeepMine:contextInfo:)), contextInfo: nil)
        }
        guard let editor, editor.canSynchronize else { save(); return }
        editor.synchronize { [weak self] synchronized in
            if synchronized { save() } else { self?.resendDiskConflict() }
        }
    }
    @objc private func document(_ document: NSDocument, didKeepMine didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if !didSave { resendDiskConflict() }
    }
    private func resendDiskConflict() {
        if let diskConflict { editor?.send("diskChanged", diskConflict.text) }
    }
    private func clearDiskConflict() {
        guard diskConflict != nil else { return }
        diskConflict = nil
        editor?.send("diskChanged", nil)
    }
    // NSDocument counts an undo-registered edit with updateChangeCount(.changeDone)
    // when the edit's undo group closes, possibly later still while it checks
    // autosaving safety. A save that starts before then takes its change-count
    // token too early and the late count re-dirties the saved document, so a
    // save waits until that count has been reported here.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        guard uncountedEdit else { super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler); return }
        savesWaitingForEdit.append { [weak self] in
            guard let self else { completionHandler(CocoaError(.userCancelled)); return }
            self.saveWithoutWaiting(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        }
        // Undo registration can be disabled, so the count may never come.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.savesWaitingForEdit.isEmpty else { return }
            self.uncountedEdit = false; self.runSavesWaitingForEdit()
        }
    }
    private func saveWithoutWaiting(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }
    private func runSavesWaitingForEdit() {
        let saves = savesWaitingForEdit
        savesWaitingForEdit.removeAll()
        // Leave NSDocument's change-count update before starting a save.
        if !saves.isEmpty { DispatchQueue.main.async { saves.forEach { $0() } } }
    }
    override func save(_ sender: Any?) {
        synchronizeBeforeSaving { [weak self] in self?.saveSynchronized(sender) }
    }
    private func saveSynchronized(_ sender: Any?) { super.save(sender) }
    override func saveAs(_ sender: Any?) {
        synchronizeBeforeSaving { [weak self] in self?.saveAsSynchronized(sender) }
    }
    private func saveAsSynchronized(_ sender: Any?) { super.saveAs(sender) }
    private func synchronizeBeforeSaving(_ action: @escaping () -> Void) {
        guard let editor, editor.canSynchronize else { action(); return }
        editor.synchronize { success in if success { action() } }
    }
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        savePanel.allowsOtherFileTypes = true
        if fileURL == nil { savePanel.nameFieldStringValue = editorName }
        return true
    }
}

// Local image requests are confined to the document's folder. Markdown never
// receives unrestricted file:// access or the ability to run native commands.
final class AssetHandler: NSObject, WKURLSchemeHandler {
    var root: URL?
    private let imageMIMEs = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "avif": "image/avif", "heic": "image/heic", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "ico": "image/x-icon"]
    func readAsset(_ requestURL: URL) throws -> (Data, String) {
        guard let root, requestURL.host == "local" else { throw URLError(.fileDoesNotExist) }
        let candidate = root.appendingPathComponent(String(requestURL.path.dropFirst())).standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/"),
              let mime = imageMIMEs[candidate.pathExtension.lowercased()],
              let data = try? Data(contentsOf: candidate) else {
            throw URLError(.noPermissionsToReadFile)
        }
        return (data, mime)
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard let url = task.request.url else { throw URLError(.badURL) }
            let (data, mime) = try readAsset(url)
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class MessageBridge: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// The editor fills the window under the title bar, and the web view does not
// move the window, so this strip over the title bar's height does.
final class TitlebarDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else { window.performDrag(with: event); return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

// Markdown files dropped on the editor open as tabs; anything else, such as
// images, still goes to WebKit for the editor's own drop handling.
final class EditorWebView: WKWebView {
    var onOpenFiles: (([URL]) -> Void)?
    // The document's commands, added to WebKit's menu when the page reports that the
    // right-click was in the document rather than in a field such as Find.
    var documentMenuItems: () -> [NSMenuItem] = { [] }
    var documentMenuRequested = false
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard documentMenuRequested else { return }
        documentMenuRequested = false
        let paste = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierPaste" }
        var index = paste.map { $0 + 1 } ?? 0
        let items = documentMenuItems()
        if paste != nil { menu.insertItem(.separator(), at: index); index += 1 }
        for item in items { menu.insertItem(item, at: index); index += 1 }
        if paste == nil, index < menu.items.count { menu.insertItem(.separator(), at: index) }
    }
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        documentMenuRequested = false
    }
    // WebKit registers its own editing undo on the responder chain's undo
    // manager, which is otherwise the document's. The document's undo works
    // on whole Markdown snapshots, so WebKit's steps must stay out of it.
    private let editingUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1
        return manager
    }()
    override var undoManager: UndoManager? { editingUndoManager }
    private var handlingFileDrop = false
    static func markdownFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && urls.allSatisfy { markdownExtensions.contains($0.pathExtension.lowercased()) } ? urls : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlingFileDrop = !Self.markdownFiles(on: sender.draggingPasteboard).isEmpty
        return handlingFileDrop ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        handlingFileDrop ? .copy : super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        if handlingFileDrop { handlingFileDrop = false } else { super.draggingExited(sender) }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handlingFileDrop || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard handlingFileDrop else { return super.performDragOperation(sender) }
        handlingFileDrop = false
        let urls = Self.markdownFiles(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onOpenFiles?(urls)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if !handlingFileDrop { super.concludeDragOperation(sender) }
    }
}

// The editor's column, which reports when the title bar and tab bar over its
// top change height: the tab bar appearing or hiding, or full screen.
final class EditorContainerView: NSView {
    var onTopInsetChange: (CGFloat) -> Void = { _ in }
    private var reportedInset: CGFloat = -1
    override func layout() {
        super.layout()
        guard safeAreaInsets.top != reportedInset else { return }
        reportedInset = safeAreaInsets.top
        onTopInsetChange(reportedInset)
    }
}

// One document's editor: its web view and the bridge to it. A window shows one
// document's editor at a time and keeps the others loaded in the background.
final class DocumentEditor: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: EditorWebView
    let assets = AssetHandler()
    let view = EditorContainerView()
    let titlebarDragView = TitlebarDragView()
    private(set) weak var document: MarkdownDocument?
    weak var host: EditorWindowController?
    var ready = false
    private(set) var session = EditorSession()
    private(set) var hasEditorFailure = false
    // The latest outline from the page, shown in the sidebar while this document is current.
    private(set) var headings: [HeadingEntry] = []
    private var loadTimeout: DispatchWorkItem?
    private var lastReportedError: String?
    private var failureText: NSTextView?
    private var failureView: NSView?
    private var sentTitlebarInset: CGFloat?
    private let logger = Logger(subsystem: "com.infiniteviewtech.margin", category: "Editor")
    var isShowingFailure: Bool { failureView != nil }
    var doc: MarkdownDocument { document! }
    var window: NSWindow? { host?.window }
    private var app: AppDelegate? { (NSDocumentController.shared as? DocumentController)?.app }

    init(document: MarkdownDocument) {
        self.document = document
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assets, forURLScheme: "markdown-asset")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = EditorWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.translatesAutoresizingMaskIntoConstraints = false
        titlebarDragView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView); view.addSubview(titlebarDragView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor), webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titlebarDragView.topAnchor.constraint(equalTo: view.topAnchor),
            titlebarDragView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            titlebarDragView.leadingAnchor.constraint(equalTo: view.leadingAnchor), titlebarDragView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        view.onTopInsetChange = { [weak self] _ in self?.sendTitlebar() }
        webView.onOpenFiles = { [weak self] urls in
            guard let self, let host = self.host else { return }
            self.app?.open(urls, in: host)
        }
        webView.documentMenuItems = { [weak self] in self?.documentMenuItems() ?? [] }
        webView.navigationDelegate = self
        configuration.userContentController.add(MessageBridge(target: self), name: "native")
        startEditor()
    }
    deinit { loadTimeout?.cancel() }
    // The document closed; its page must not reach the app any more.
    func tearDown() {
        loadTimeout?.cancel(); loadTimeout = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
        webView.stopLoading()
        view.removeFromSuperview()
    }
    var canSynchronize: Bool { ready && session.isLoaded && !hasEditorFailure }

    private func startEditor() {
        guard document != nil else { return }
        ready = false; hasEditorFailure = false; lastReportedError = nil
        _ = session.beginLoad()
        failureText = nil
        webView.isHidden = true
        failureView?.removeFromSuperview(); failureView = nil
        armLoadTimeout()
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web") else {
            showEditorFailure("The editor files are missing from the application bundle.")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }
    private func armLoadTimeout() {
        loadTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.showEditorFailure("The editor did not finish loading within 15 seconds.") }
        loadTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
    }
    func evaluate(_ script: String) {
        let token = session.token
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, token == self.session.token, let error else { return }
            if self.session.isLoaded { self.reportEditorError("An editor command failed: \(error.localizedDescription)") }
            else { self.showEditorFailure("The document could not be displayed: \(error.localizedDescription)") }
        }
    }
    func synchronize(_ completion: @escaping (Bool) -> Void) {
        let token = session.token
        webView.evaluateJavaScript("window.app.snapshot()") { [weak self] result, error in
            guard let self else { completion(false); return }
            guard token == self.session.token, error == nil, let snapshot = result as? [String: Any],
                  let text = snapshot["text"] as? String, let revision = snapshot["revision"] as? Int,
                  snapshot["token"] as? String == token, self.session.accepts(token) else {
                self.reportEditorError("The latest editor text could not be read. Saving was cancelled; your last received edits are still in memory.")
                completion(false)
                return
            }
            if self.session.acceptChange(token: token, revision: revision) { self.doc.edited(text) }
            completion(true)
        }
    }
    private func reportEditorError(_ message: String) {
        logger.error("\(message, privacy: .private)")
        guard message != lastReportedError, !hasEditorFailure else { return }
        lastReportedError = message
        let alert = NSAlert()
        alert.messageText = "An editor error occurred"
        alert.informativeText = message + "\n\nThe document has not been reloaded. Your last received edits are still held by the app."
        guard let window, window.attachedSheet == nil else { return }
        alert.beginSheetModal(for: window)
    }
    private func showEditorFailure(_ message: String) {
        guard !hasEditorFailure, document != nil else { return }
        logger.error("\(message, privacy: .private)")
        hasEditorFailure = true; ready = false
        loadTimeout?.cancel(); loadTimeout = nil
        if doc.isDocumentEdited { doc.flushRecovery() }
        let view = NSView()
        let title = NSTextField(labelWithString: "The editor is unavailable")
        title.font = .boldSystemFont(ofSize: 20)
        let detail = NSTextField(wrappingLabelWithString: message + "\n\nThe text below is the last version received by the app. You can copy it or save it before retrying.")
        let retry = NSButton(title: "Retry Editor", target: self, action: #selector(retryEditor(_:)))
        let save = NSButton(title: "Save As…", target: self, action: #selector(saveProtectedText(_:)))
        let buttons = NSStackView(views: [retry, save])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, detail, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = doc.text
        failureText = text; scroll.documentView = text
        view.addSubview(stack); view.addSubview(scroll)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Shown in place of the editor, below the title bar strip so the window still drags.
        self.view.addSubview(view, positioned: .below, relativeTo: titlebarDragView)
        failureView = view
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor), view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor), view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36)
        ])
        webView.isHidden = true
        // NSTextView's initial frame must follow the laid-out scroll viewport.
        view.layoutSubtreeIfNeeded()
        text.setFrameSize(scroll.contentSize)
    }
    @objc private func retryEditor(_ sender: Any?) { startEditor() }
    @objc private func saveProtectedText(_ sender: Any?) {
        doc.saveAs(sender)
    }
    func send(_ name: String, _ value: Any? = nil) {
        guard canSynchronize else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: [name, value ?? NSNull()], options: [.fragmentsAllowed])
            let arguments = String(decoding: data, as: UTF8.self)
            evaluate("window.app.command(...\(arguments))")
        } catch { reportEditorError("An editor command could not be prepared: \(error.localizedDescription)") }
    }
    func loadDocument(notice: String? = nil) {
        guard ready else { return }
        // Only the first load waits hidden. Later loads, such as undo and
        // reloading from disk, change the text in place.
        if !session.isLoaded { webView.isHidden = true }
        let token = session.beginLoad()
        armLoadTimeout()
        assets.root = (doc.fileURL ?? doc.recoveredOriginalURL)?.deletingLastPathComponent()
        var payload: [String: Any] = ["text": doc.text, "token": token, "name": doc.editorName, "path": doc.fileURL?.path ?? "", "modified": doc.isDocumentEdited]
        if let zoom = app?.settings.textZoom { payload["textZoom"] = zoom }
        payload["titlebar"] = ["inset": view.safeAreaInsets.top]
        sentTitlebarInset = view.safeAreaInsets.top
        if let host { payload["sidebarOpen"] = !host.sidebarItem.isCollapsed }
        if let notice { payload["notice"] = notice }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            evaluate("window.app.load(\(String(decoding: data, as: UTF8.self)))")
        } catch { showEditorFailure("The document could not be sent to the editor: \(error.localizedDescription)") }
    }
    func loadMetadata() {
        guard ready, document != nil else { return }
        // Saving can give an untitled document its first path and image base.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.assets.root = (self.doc.fileURL ?? self.doc.recoveredOriginalURL)?.deletingLastPathComponent()
            let name = self.doc.editorName
            self.host?.documentDidChange(self.doc)
            self.send("metadata", ["name": name, "path": self.doc.fileURL?.path ?? "", "modified": self.doc.isDocumentEdited])
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // A tab closed while its editor was still loading can deliver messages after its document is gone.
        guard document != nil, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            guard !hasEditorFailure else { return }
            ready = true; loadDocument()
        case "loaded":
            guard !hasEditorFailure, let token = body["token"] as? String else { return }
            session.acknowledge(token)
            if session.isLoaded {
                loadTimeout?.cancel(); loadTimeout = nil; webView.isHidden = false
                // Commands sent while the load was pending were dropped.
                send("diskChanged", doc.diskConflict?.text)
            }
        case "changed":
            if let token = body["token"] as? String, let text = body["text"] as? String,
               let revision = body["revision"] as? Int, session.acceptChange(token: token, revision: revision) {
                doc.edited(text)
                failureText?.string = doc.text
            }
        case "editorError":
            let message = body["message"] as? String ?? "An editor operation failed."
            if session.isLoaded { reportEditorError(message) }
            else { showEditorFailure(message) }
        case "undo": doc.undoManager?.undo()
        case "redo": doc.undoManager?.redo()
        case "new": app?.newDocument(nil)
        case "open": NSDocumentController.shared.openDocument(nil)
        case "openFolder": app?.openFolder(nil)
        case "save": doc.save(nil)
        case "diskReload": doc.confirmReloadFromDisk()
        case "diskKeepMine": doc.keepMine()
        case "saveAs": doc.saveAs(nil)
        case "print": printDocument(nil)
        case "exportHTML": if let html = body["html"] as? String { exportHTML(html) }
        case "toggleSidebar": host?.toggleSidebar()
        case "previousFile": host?.selectAdjacent(-1)
        case "nextFile": host?.selectAdjacent(1)
        case "contextMenu": webView.documentMenuRequested = true
        case "outline":
            let headings: [HeadingEntry] = (body["headings"] as? [[String: Any]] ?? []).compactMap { item -> HeadingEntry? in
                guard let level = item["level"] as? Int, let text = item["text"] as? String, let pos = item["pos"] as? Int else { return nil }
                return HeadingEntry(level: level, text: text, pos: pos)
            }
            self.headings = headings
            if host?.current === document { host?.sidebar.setHeadings(headings) }
        case "openExternal":
            if let string = body["url"] as? String, let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    private func sendTitlebar() {
        let inset = view.safeAreaInsets.top
        guard canSynchronize, inset != sentTitlebarInset else { return }
        sentTitlebarInset = inset
        send("titlebar", ["inset": inset])
    }
    // Insert items first, then the Paragraph and Format menus' commands.
    func documentMenuItems() -> [NSMenuItem] {
        func format(_ title: String, _ kind: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(formatFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem?]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            for item in items { menu.addItem(item ?? .separator()) }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); parent.submenu = menu
            return parent
        }
        let headings = (1...6).map { format("Heading \($0)", "h\($0)") }
        return [
            format("Insert Table", "table"), format("Insert Link…", "link"), format("Insert Image…", "image"), format("Insert Code Block", "codeBlock"),
            submenu("Paragraph", [format("Body", "paragraph")] + headings + [nil, format("Bullet List", "bulletList"), format("Numbered List", "orderedList"), format("Task List", "taskList"), format("Quote", "blockquote")]),
            submenu("Format", [format("Bold", "bold"), format("Italic", "italic"), format("Strikethrough", "strike"), format("Inline Code", "code")])
        ]
    }
    @objc func formatFromMenu(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        send("format", kind)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else if let url = navigationAction.request.url, url.isFileURL && url.lastPathComponent == "index.html" {
            decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showEditorFailure("The editor could not be loaded: \(error.localizedDescription)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showEditorFailure("The editor process stopped unexpectedly.")
    }
    func exportHTML(_ html: String) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".html"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try html.write(to: url, atomically: true, encoding: .utf8) }
            catch { NSApp.presentError(error) }
        }
    }
    @objc func printDocument(_ sender: Any?) {
        // The page prints a rendered copy of the Markdown rather than the editor.
        guard canSynchronize else { reportEditorError("Printing is unavailable until the editor has loaded."); return }
        webView.evaluateJavaScript("window.app.preparePrint()") { [weak self] _, error in
            guard let self, let window = self.window else { return }
            if let error { self.reportEditorError("The document could not be prepared for printing: \(error.localizedDescription)"); return }
            let info = self.doc.printInfo
            info.topMargin = 45; info.bottomMargin = 45; info.leftMargin = 45; info.rightMargin = 45
            let operation = self.webView.printOperation(with: info)
            operation.showsPrintPanel = true
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}

class DocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? {
        [markdownType, plainTextType].contains(typeName) ? MarkdownDocument.self : nil
    }
    override var defaultType: String? { markdownType }
    weak var app: AppDelegate?
    private var queuedOpens: [(url: URL, display: Bool, completion: (NSDocument?, Bool, Error?) -> Void)] = []
    private var opening = false
    var isOpening: Bool { opening || !queuedOpens.isEmpty }
    // Every open, including Finder's launch-time ones (requested before
    // didFinishLaunching), comes through here. They run one at a time:
    // concurrent reads finish in any order, and each window becomes a tab as
    // it is shown, so tabs would not follow the order requested.
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
            if self.queuedOpens.isEmpty { self.app?.documentOpensFinished() } else { self.openNextQueuedDocument() }
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    // Only windows still open count; AppKit can keep listing one after it closes.
    var currentWindow: EditorWindowController? {
        let front = (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? EditorWindowController
        return front.flatMap { host in windows.contains { $0 === host } ? host : nil }
    }
    var currentEditor: DocumentEditor? { currentWindow?.currentEditor }

    init(controller: DocumentController? = nil, recoveryStore: RecoveryStore = .shared, settings: Settings = Settings()) {
        self.controller = controller
        self.recoveryStore = recoveryStore
        self.settings = settings
        super.init()
        controller?.app = self
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if controller == nil { controller = DocumentController() }
        controller.app = self
        // A window switches between its documents, so macOS's window tabs are not used.
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidFinishRestoringWindows(_:)), name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        buildMenu()
        applySettings()
    }
    // Files added in other applications show up when Margin comes back to the front.
    func applicationDidBecomeActive(_ notification: Notification) { refreshFolders() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        if #available(macOS 14, *) { NSApp?.activate() } else { NSApp?.activate(ignoringOtherApps: true) }
        finishStartupIfReady()
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    @objc func applicationDidFinishRestoringWindows(_ notification: Notification) {
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
                    NSUnderlyingErrorKey: first
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
    // Recovery always creates untitled copies. A draft must never silently
    // replace a file that another application may have changed after a crash.
    func recoverDocuments(display: Bool = true) throws -> [Error] {
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
                    if !existing.isDocumentEdited || existing.recoveryID != draft.id { try recoveryStore.remove(draft.id) }
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
                if display { doc.makeWindowControllers(); doc.showWindows() }
            } catch { failures.append(error) }
        }
        return failures
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func documentOpensFinished() { finishStartupIfReady() }
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
    func windowDidClose(_ host: EditorWindowController) { windows.removeAll { $0 === host } }
    private var frontWindow: EditorWindowController? {
        let front = NSApp.orderedWindows.lazy.compactMap { $0.windowController as? EditorWindowController }.first { host in self.windows.contains { $0 === host } }
        return currentWindow ?? front ?? windows.last
    }
    // Finder, Dock, File › Open, and new documents join the frontmost window.
    func windowForNewDocuments() -> EditorWindowController { frontWindow ?? makeWindow() }
    @objc func newWindow(_ sender: Any?) { makeWindowWithUntitledDocument() }
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
    // Drops, workspace clicks, and Quick Open name their window. A document already
    // open elsewhere is shown where it is.
    func open(_ urls: [URL], in host: EditorWindowController, opened: @escaping (NSDocument) -> Void = { _ in }) {
        for url in urls {
            controller.openDocument(withContentsOf: url, display: false) { [weak self] document, alreadyOpen, error in
                if let error { self?.controller.presentError(error); return }
                guard let document = document as? MarkdownDocument else { return }
                if !(alreadyOpen && document.editor?.host != nil) { host.add(document) }
                document.showWindows()
                opened(document)
            }
        }
    }
    @objc func previousFile(_ sender: Any?) { currentWindow?.selectAdjacent(-1) }
    @objc func nextFile(_ sender: Any?) { currentWindow?.selectAdjacent(1) }
    // Restoration reopens each window's documents before deciding whether a welcome is needed.
    func beginRestoring() { restoringWindows += 1 }
    func endRestoring() { restoringWindows -= 1; finishStartupIfReady() }
    func restoreDocument(_ entry: [String: Any], completion: @escaping (MarkdownDocument?) -> Void) {
        func finish(_ document: NSDocument?) {
            guard let doc = document as? MarkdownDocument else { completion(nil); return }
            if let id = (entry["recoveryID"] as? String).flatMap(UUID.init(uuidString:)) { doc.recoveryID = id }
            if let name = entry["recoveredName"] as? String { doc.recoveredName = name; doc.displayName = name }
            if let original = entry["recoveredOriginalPath"] as? String { doc.recoveredOriginalURL = URL(fileURLWithPath: original) }
            completion(doc)
        }
        if let path = entry["path"] as? String {
            controller.openDocument(withContentsOf: URL(fileURLWithPath: path), display: false) { document, _, _ in finish(document) }
        } else if let autosaved = entry["autosaved"] as? String {
            controller.reopenDocument(for: nil, withContentsOf: URL(fileURLWithPath: autosaved), display: false) { document, _, _ in finish(document) }
        } else {
            // A clean untitled document; a welcome comes back with its text.
            guard let doc = try? controller.makeUntitledDocument(ofType: markdownType) as? MarkdownDocument else { completion(nil); return }
            if entry["welcome"] as? Bool == true, let welcome = MarkdownDocument.welcomeText() { doc.text = welcome; doc.isWelcome = true }
            controller.addDocument(doc)
            finish(doc)
        }
    }
    // An empty Markdown file with an unused name, opened as a tab and ready to rename.
    func createWorkspaceFile(in folder: URL, in host: EditorWindowController) throws {
        guard host.isInWorkspace(folder) else { throw CocoaError(.fileWriteNoPermission) }
        var url = folder.appendingPathComponent("Untitled.md"), number = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("Untitled \(number).md"); number += 1 }
        try Data().write(to: url, options: .withoutOverwriting)
        host.refreshFolder { [weak self] in
            self?.open([url], in: host) { document in (document as? MarkdownDocument)?.editor?.host?.sidebar.beginRename(path: url.path) }
        }
    }
    // Keeps a Markdown extension, adding the file's own when the name has none. A file
    // open in a tab moves with its document, which keeps the tab and any unsaved edits.
    func renameWorkspaceFile(_ url: URL, to name: String, in host: EditorWindowController, completion: @escaping (Error?) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        func refused(_ reason: String) { completion(NSError(domain: "Margin.Rename", code: 1, userInfo: [NSLocalizedDescriptionKey: "“\(trimmed)” can’t be used as a file name.", NSLocalizedRecoverySuggestionErrorKey: reason])) }
        guard host.isInWorkspace(url) else { completion(CocoaError(.fileWriteNoPermission)); return }
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else { refused("Use a name without “/” or “:” that doesn’t start with a period."); return }
        let fileName = markdownExtensions.contains((trimmed as NSString).pathExtension.lowercased()) ? trimmed : trimmed + "." + (url.pathExtension.isEmpty ? "md" : url.pathExtension)
        let destination = url.deletingLastPathComponent().appendingPathComponent(fileName)
        guard destination.lastPathComponent != url.lastPathComponent else { completion(nil); return }
        // A change only in letter case names the same file on a case-insensitive disk.
        let sameFile = { (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject) == (try? destination.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject) }
        if FileManager.default.fileExists(atPath: destination.path), !sameFile() { refused("A file named “\(fileName)” already exists in this folder."); return }
        let finish = { [weak self] (error: Error?) in
            self?.refreshFolders()
            completion(error)
        }
        if let doc = controller.documents.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) as? MarkdownDocument {
            doc.move(to: destination) { error in
                if error == nil { doc.editor?.loadMetadata() }
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
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard startupCompleted else { return true }
        if !flag {
            if controller.documents.isEmpty { newDocument(nil) }
            else { controller.documents.forEach { $0.showWindows() } }
        }
        return true
    }
    @objc func newDocument(_ sender: Any?) {
        do { try controller.openUntitledDocumentAndDisplay(true) }
        catch { controller.presentError(error) }
    }
    // The folder replaces the one in the window it was chosen from, or opens in a new
    // window when none is open. Other windows keep their folders.
    @objc func openFolder(_ sender: Any?) {
        let target = frontWindow
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"; panel.message = "Choose a folder of Markdown files."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let host = target.flatMap { target in self.windows.contains { $0 === target } ? target : nil } ?? self.makeWindowWithUntitledDocument()
            host?.workspace = url
        }
    }
    // Breadth first, so a large subfolder can't use up the budget before shallower files are listed.
    static func scanFolder(_ workspace: URL) -> FolderEntry {
        var budget = 5000
        var listings: [String: (folders: [URL], files: [URL])] = [:]
        var level = [workspace]
        for _ in 0..<12 where budget > 0 && !level.isEmpty {
            var next: [URL] = []
            for url in level {
                guard budget > 0 else { break }
                guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var listing: (folders: [URL], files: [URL]) = ([], [])
                for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    guard budget > 0 else { break }
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                    budget -= 1
                    if values.isDirectory == true {
                        if ["node_modules", "vendor", "build", "dist", "DerivedData"].contains(child.lastPathComponent) { continue }
                        listing.folders.append(child)
                    } else if markdownExtensions.contains(child.pathExtension.lowercased()) { listing.files.append(child) }
                }
                listings[url.path] = listing
                next += listing.folders
            }
            level = next
        }
        func entries(_ url: URL) -> [FolderEntry] {
            guard let listing = listings[url.path] else { return [] }
            let folders = listing.folders.compactMap { folder -> FolderEntry? in
                let nested = entries(folder)
                return nested.isEmpty ? nil : FolderEntry(name: folder.lastPathComponent, path: folder.path, children: nested)
            }
            return folders + listing.files.map { FolderEntry(name: $0.lastPathComponent, path: $0.path, children: nil) }
        }
        return FolderEntry(name: workspace.lastPathComponent, path: workspace.path, children: entries(workspace))
    }
    func refreshFolders(completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        for host in windows { group.enter(); host.refreshFolder { group.leave() } }
        group.notify(queue: .main, execute: completion)
    }
    @objc func webCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        currentEditor?.send(parts[0], parts.count > 1 ? parts[1] : nil)
    }
    @objc func exportHTML(_ sender: Any?) { currentEditor?.send("exportHTML") }
    @objc func toggleSidebar(_ sender: Any?) { currentWindow?.toggleSidebar() }
    @objc func showQuickOpen(_ sender: Any?) { if let currentWindow { showQuickOpen(for: currentWindow) } }
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
        picker.onClose = { [weak self, weak picker] in if self?.quickOpen === picker { self?.quickOpen = nil } }
        quickOpen = picker
        picker.show(over: window)
    }
    // This window's documents, then other open documents, recent files, and the files in this window's folder.
    func quickOpenItems(for host: EditorWindowController) -> [QuickOpenItem] {
        var items: [QuickOpenItem] = [], seen = Set<String>()
        func folder(of url: URL) -> String {
            let directory = url.deletingLastPathComponent().path
            if let workspace = host.workspace, directory == workspace.path || directory.hasPrefix(workspace.path + "/") {
                return workspace.lastPathComponent + directory.dropFirst(workspace.path.count)
            }
            return (directory as NSString).abbreviatingWithTildeInPath
        }
        func add(_ name: String, _ url: URL?, _ target: QuickOpenItem.Target) {
            if let path = url?.standardizedFileURL.path { guard seen.insert(path).inserted else { return } }
            items.append(QuickOpenItem(name: name, detail: url.map(folder(of:)) ?? "Open, not saved", target: target))
        }
        let here = host.documents
        let others = controller.documents.compactMap { $0 as? MarkdownDocument }.filter { doc in !here.contains { $0 === doc } }
        for doc in here + others { add(doc.editorName, doc.fileURL, .document(doc)) }
        for url in controller.recentDocumentURLs where FileManager.default.fileExists(atPath: url.path) { add(url.lastPathComponent, url, .file(url)) }
        func files(_ entries: [FolderEntry]) {
            for entry in entries {
                if let children = entry.children { files(children) }
                else { let url = URL(fileURLWithPath: entry.path); add(entry.name, url, .file(url)) }
            }
        }
        files(host.workspaceTree?.children ?? [])
        return items
    }
    @objc func pasteAndMatchStyle(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        currentEditor?.send("pastePlain", text)
    }
    @objc func showOutline(_ sender: Any?) { currentWindow?.showOutline() }
    @objc func zoomIn(_ sender: Any?) { setTextZoom(settings.zoomedIn()) }
    @objc func zoomOut(_ sender: Any?) { setTextZoom(settings.zoomedOut()) }
    @objc func actualSize(_ sender: Any?) { setTextZoom(1) }
    func setTextZoom(_ zoom: Double) {
        settings.textZoom = zoom
        for doc in controller.documents { (doc as? MarkdownDocument)?.editor?.send("textZoom", zoom) }
        currentEditor?.send("toast", "Text size \(Int((zoom * 100).rounded()))%")
    }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(settings: settings) { [weak self] in self?.applySettings() } }
        settingsWindow?.refresh()
        settingsWindow?.showWindow(sender)
    }
    func applySettings() {
        NSApp?.appearance = settings.appearance.appearance
        NSApp?.applicationIconImage = settings.appIcon.dockImage
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in controller.recentDocumentURLs {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = url; menu.addItem(entry)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = controller; menu.addItem(clear)
    }
    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        controller.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
    func buildMenu() {
        NSApp.mainMenu = makeMenu()
    }
    func makeMenu() -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); let menu = NSMenu(title: title); item.submenu = menu; bar.addItem(item); return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        func command(_ menu: NSMenu, _ title: String, _ action: String, _ key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) {
            let entry = NSMenuItem(title: title, action: #selector(webCommand(_:)), keyEquivalent: key); entry.keyEquivalentModifierMask = modifiers; entry.target = self; entry.representedObject = action; menu.addItem(entry)
        }
        let app = menu("Margin")
        item(app, "About Margin", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "Settings…", #selector(showSettings(_:)), ",", target: self)
        app.addItem(.separator())
        item(app, "Hide Margin", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); item(app, "Quit Margin", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New", #selector(newDocument(_:)), "n", target: self)
        item(file, "New Window", #selector(newWindow(_:)), "n", modifiers: [.command, .shift], target: self)
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: controller)
        item(file, "Open Folder…", #selector(openFolder(_:)), "o", modifiers: [.command, .shift], target: self)
        item(file, "Quick Open…", #selector(showQuickOpen(_:)), "p", modifiers: [.command, .option], target: self)
        let recent = NSMenu(title: "Open Recent"); let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem)
        recent.delegate = self
        file.addItem(.separator()); item(file, "Close", #selector(EditorWindowController.closeDocument(_:)), "w")
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator()); item(file, "Export HTML…", #selector(exportHTML(_:)), target: self)
        item(file, "Print / Save as PDF…", #selector(EditorWindowController.printDocument(_:)), "p")
        let edit = menu("Edit")
        item(edit, "Undo", #selector(EditorWindowController.undoDocument(_:)), "z")
        item(edit, "Redo", #selector(EditorWindowController.redoDocument(_:)), "z", modifiers: [.command, .shift])
        edit.addItem(.separator()); item(edit, "Cut", #selector(NSText.cut(_:)), "x"); item(edit, "Copy", #selector(NSText.copy(_:)), "c"); item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Paste and Match Style", #selector(pasteAndMatchStyle(_:)), "v", modifiers: [.command, .option, .shift], target: self); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator()); command(edit, "Find…", "find", "f"); command(edit, "Find and Replace…", "replace", "f", modifiers: [.command, .option]); command(edit, "Go to Line…", "goToLine", "l")
        let paragraph = menu("Paragraph")
        command(paragraph, "Body", "format:paragraph", "0", modifiers: [.command, .option])
        for level in 1...6 { command(paragraph, "Heading \(level)", "format:h\(level)", "\(level)") }
        paragraph.addItem(.separator()); command(paragraph, "Bullet List", "format:bulletList"); command(paragraph, "Numbered List", "format:orderedList"); command(paragraph, "Task List", "format:taskList"); command(paragraph, "Quote", "format:blockquote"); command(paragraph, "Code Block", "format:codeBlock"); command(paragraph, "Table", "format:table")
        let format = menu("Format")
        command(format, "Bold", "format:bold", "b"); command(format, "Italic", "format:italic", "i"); command(format, "Strikethrough", "format:strike"); command(format, "Inline Code", "format:code"); format.addItem(.separator()); command(format, "Link…", "format:link", "k"); command(format, "Image…", "format:image")
        let view = menu("View")
        item(view, "Toggle Sidebar", #selector(toggleSidebar(_:)), "l", modifiers: [.command, .shift], target: self); item(view, "Document Outline", #selector(showOutline(_:)), target: self); command(view, "Source Mode", "source", "/"); view.addItem(.separator())
        item(view, "Actual Size", #selector(actualSize(_:)), "0", target: self); item(view, "Zoom In", #selector(zoomIn(_:)), "+", target: self); item(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        // ⌘= also zooms in, as in browsers, without a second visible item.
        item(view, "Zoom In", #selector(zoomIn(_:)), "=", target: self); view.items.last?.isHidden = true; view.items.last?.allowsKeyEquivalentWhenHidden = true
        view.addItem(.separator()); command(view, "Typewriter Mode", "typewriter"); view.addItem(.separator()); item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        // ⌘⇧[ and ⌘⇧] switch files, as they switch tabs elsewhere in macOS. AppKit matches
        // the Shift-[ key as "{".
        let window = menu("Window"); item(window, "Previous File", #selector(previousFile(_:)), "{", target: self); item(window, "Next File", #selector(nextFile(_:)), "}", target: self)
        window.addItem(.separator()); item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); item(window, "Zoom", #selector(NSWindow.performZoom(_:))); window.addItem(.separator()); item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))); NSApp?.windowsMenu = window
        return bar
    }
}

#if !TESTING
@main struct MarginApplication {
    static func main() {
        // The first controller becomes AppKit's shared controller. Create our
        // subclass before NSApplication can instantiate the default one.
        let controller = DocumentController()
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate(controller: controller)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
