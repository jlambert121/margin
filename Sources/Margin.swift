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
    weak var editorController: EditorWindowController?
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
    // Set when AppKit restores this document's window at launch, which places
    // the window in its tabs without calling showWindow.
    private(set) var wasRestored = false
    var editorName: String { fileURL?.lastPathComponent ?? recoveredName ?? "Untitled.md" }
    override class var autosavesInPlace: Bool { true }
    override var fileURL: URL? { didSet { NotificationCenter.default.post(name: .openFilesChanged, object: self) } }
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if change == .changeDone, uncountedEdit { uncountedEdit = false; runSavesWaitingForEdit() }
        NotificationCenter.default.post(name: .openFilesChanged, object: self)
    }
    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        NotificationCenter.default.post(name: .openFilesChanged, object: self)
    }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        editorController = controller
        addWindowController(controller)
    }
    override func data(ofType typeName: String) throws -> Data { Data(text.utf8) }
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(recoveryID.uuidString, forKey: "Margin.recoveryID")
        coder.encode(recoveredName, forKey: "Margin.recoveredName")
        coder.encode(recoveredOriginalURL?.path, forKey: "Margin.recoveredOriginalPath")
        coder.encode(isWelcome, forKey: "Margin.isWelcome")
    }
    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        wasRestored = true
        if coder.containsValue(forKey: "Margin.recoveryID"),
           let value = coder.decodeObject(of: NSString.self, forKey: "Margin.recoveryID") as String?,
           let id = UUID(uuidString: value) { recoveryID = id }
        if coder.containsValue(forKey: "Margin.recoveredName") {
            recoveredName = coder.decodeObject(of: NSString.self, forKey: "Margin.recoveredName") as String?
        }
        if coder.containsValue(forKey: "Margin.recoveredOriginalPath"),
           let path = coder.decodeObject(of: NSString.self, forKey: "Margin.recoveredOriginalPath") as String? {
            recoveredOriginalURL = URL(fileURLWithPath: path)
        }
        // A clean welcome has no autosaved contents, so restoration recreates it empty.
        if coder.decodeBool(forKey: "Margin.isWelcome"), text.isEmpty, !isDocumentEdited, let welcome = Self.welcomeText() {
            isWelcome = true; text = welcome
        }
        editorController?.loadDocument()
    }
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
        if !reverting { editorController?.loadDocument() }
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
        catch { diskConflict = conflict; editorController?.loadDocument(); throw error }
        clearRecovery()
        editorController?.loadDocument(notice: revertNotice)
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
            editorController?.loadMetadata()
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
        editorController?.loadDocument()
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
        super.close()
    }
    // A periodic autosave would raise AppKit's conflict alert over the editor's
    // own choice. Closing and quitting still autosave and ask through AppKit.
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        if autosavingIsImplicitlyCancellable, diskConflict != nil { completionHandler(CocoaError(.userCancelled)); return }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
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
            guard let editorController = self.editorController, editorController.canSynchronize else { self.applyDiskChange(); finish(); return }
            editorController.synchronize { synchronized in
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
            editorController?.send("diskChanged", diskText)
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
        guard let editorController, editorController.canSynchronize else { save(); return }
        editorController.synchronize { [weak self] synchronized in
            if synchronized { save() } else { self?.resendDiskConflict() }
        }
    }
    @objc private func document(_ document: NSDocument, didKeepMine didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if !didSave { resendDiskConflict() }
    }
    private func resendDiskConflict() {
        if let diskConflict { editorController?.send("diskChanged", diskConflict.text) }
    }
    private func clearDiskConflict() {
        guard diskConflict != nil else { return }
        diskConflict = nil
        editorController?.send("diskChanged", nil)
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
        guard let editorController, editorController.canSynchronize else { action(); return }
        editorController.synchronize { success in if success { action() } }
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

// Markdown files dropped on the editor open as tabs; anything else, such as
// images, still goes to WebKit for the editor's own drop handling.
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

final class EditorWebView: WKWebView {
    var onOpenFiles: (([URL]) -> Void)?
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

final class EditorWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: EditorWebView
    let assets = AssetHandler()
    var ready = false
    private(set) var session = EditorSession()
    private(set) var hasEditorFailure = false
    private var loadTimeout: DispatchWorkItem?
    private var lastReportedError: String?
    private var failureText: NSTextView?
    private let logger = Logger(subsystem: "com.infiniteviewtech.margin", category: "Editor")
    private var tabObservation: NSKeyValueObservation?
    private weak var observedTabGroup: NSWindowTabGroup?
    private var hasBeenShown = false
    private let editorContainer = NSView()
    let titlebarDragView = TitlebarDragView()
    private var titlebarObservation: NSKeyValueObservation?
    var doc: MarkdownDocument { document as! MarkdownDocument }
    private var app: AppDelegate? { (NSDocumentController.shared as? DocumentController)?.app }

    init(document: MarkdownDocument) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assets, forURLScheme: "markdown-asset")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = EditorWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 480)
        window.titlebarAppearsTransparent = true
        // The tab shows the name, and the toolbar shows it when there is no tab bar.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("MarkdownEditor")
        window.isRestorable = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        titlebarDragView.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(webView); editorContainer.addSubview(titlebarDragView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: editorContainer.topAnchor), webView.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor), webView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            titlebarDragView.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            titlebarDragView.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor), titlebarDragView.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor)
        ])
        window.contentView = editorContainer
        window.center()
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MarginEditor"
        super.init(window: window)
        // Set on the controller, after init: adopting the window replaces the
        // window's own autosave name with the controller's, which defaults to empty.
        windowFrameAutosaveName = "MarginEditor"
        let dragHeight = titlebarDragView.heightAnchor.constraint(equalToConstant: 0)
        dragHeight.isActive = true
        // Changes when the tab bar appears or hides and when entering or leaving full screen.
        titlebarObservation = window.observe(\.contentLayoutRect, options: [.initial]) { [weak self] _, _ in
            guard let self else { return }
            dragHeight.constant = self.titlebarPayload()["inset"] as? CGFloat ?? 0
            self.send("titlebar", self.titlebarPayload())
        }
        webView.onOpenFiles = { [weak self] urls in
            guard let self, let window = self.window else { return }
            self.app?.open(urls, asTabsIn: window)
        }
        // NSDocument.addWindowController must attach us. Setting document here
        // makes AppKit treat that later call as redundant, so the document's
        // windowControllers stays empty and showWindows has nothing to show.
        webView.navigationDelegate = self
        configuration.userContentController.add(MessageBridge(target: self), name: "native")
        // Let NSDocument attach the controller before any loading error needs
        // the native document or its window.
        DispatchQueue.main.async { [weak self] in self?.startEditor() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { loadTimeout?.cancel() }
    var canSynchronize: Bool { ready && session.isLoaded && !hasEditorFailure }

    private func startEditor() {
        guard document != nil else { return }
        ready = false; hasEditorFailure = false; lastReportedError = nil
        _ = session.beginLoad()
        failureText = nil
        webView.isHidden = true
        window?.contentView = editorContainer
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
        guard !hasEditorFailure, document != nil, let window else { return }
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
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            scroll.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -36),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36)
        ])
        window.contentView = view
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
        if let folder = app?.folderPayload() { payload["folder"] = folder }
        if let zoom = app?.settings.textZoom { payload["textZoom"] = zoom }
        payload["titlebar"] = titlebarPayload()
        if let notice { payload["notice"] = notice }
        payload["openFiles"] = openFilesPayload()
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            evaluate("window.app.load(\(String(decoding: data, as: UTF8.self)))")
        } catch { showEditorFailure("The document could not be sent to the editor: \(error.localizedDescription)") }
    }
    func loadMetadata() {
        guard ready else { return }
        // Saving can give an untitled document its first path and image base.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.assets.root = (self.doc.fileURL ?? self.doc.recoveredOriginalURL)?.deletingLastPathComponent()
            let name = self.doc.editorName
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
        case "undo": undoDocument(nil)
        case "redo": redoDocument(nil)
        case "new": app?.newDocument(nil)
        case "open": NSDocumentController.shared.openDocument(nil)
        case "openFolder": app?.openFolder(nil)
        case "refreshFolder": app?.refreshFolders()
        case "save": doc.save(nil)
        case "diskReload": doc.confirmReloadFromDisk()
        case "diskKeepMine": doc.keepMine()
        case "saveAs": doc.saveAs(nil)
        case "print": printDocument(nil)
        case "exportHTML": if let html = body["html"] as? String { exportHTML(html) }
        case "openPath":
            if let path = body["path"] as? String, let folder = app?.workspace {
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                let root = folder.standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/"), markdownExtensions.contains(url.pathExtension.lowercased()), let window else { return }
                app?.open([url], asTabsIn: window)
            }
        case "selectOpenFile": selectTab(id: body["id"] as? String)
        case "closeOpenFile": closeTab(id: body["id"] as? String)
        case "openExternal":
            if let string = body["url"] as? String, let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    // NSWindowTabGroup documents `windows` as KVO compliant and in visual tab
    // order. NSWindow.tabGroup has no such promise, so re-attach whenever this
    // window has moved to another group. Reading tabGroup before the window is
    // shown gives it a group of its own and stops it joining the current tabs.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        markShown()
    }
    // Restored windows are already in their tab group when restoration finishes.
    func markShown() {
        hasBeenShown = true
        observeTabGroup()
        NotificationCenter.default.post(name: .openFilesChanged, object: self)
    }
    private func observeTabGroup() {
        guard hasBeenShown, let group = window?.tabGroup, group !== observedTabGroup else { return }
        observedTabGroup = group
        tabObservation = group.observe(\.windows) { [weak self] _, _ in
            NotificationCenter.default.post(name: .openFilesChanged, object: self)
        }
    }
    var tabDocuments: [MarkdownDocument] {
        guard let window else { return [] }
        guard hasBeenShown else { return [doc] }
        let open = NSDocumentController.shared.documents
        // tabbedWindows is nil whenever the tab bar is hidden; the group is not.
        return (window.tabGroup?.windows ?? [window]).compactMap { $0.windowController?.document as? MarkdownDocument }.filter { doc in open.contains { $0 === doc } }
    }
    private func tab(for id: String?) -> NSWindow? {
        tabDocuments.first { $0.recoveryID.uuidString == id }?.editorController?.window
    }
    func selectTab(id: String?) { tab(for: id)?.makeKeyAndOrderFront(nil) }
    // performClose keeps the standard unsaved-changes prompt, shown on its own tab.
    func closeTab(id: String?) {
        guard let tab = tab(for: id) else { return }
        if (tab.windowController?.document as? NSDocument)?.isDocumentEdited == true { tab.makeKeyAndOrderFront(nil) }
        tab.performClose(nil)
    }
    // The height the title bar and tab bar cover at the top of the editor, and
    // whether the tab bar is showing the document's name.
    func titlebarPayload() -> [String: Any] {
        guard let window else { return ["inset": CGFloat(0), "tabBar": false] }
        let inset = max(0, window.frame.height - window.contentLayoutRect.maxY)
        // Reading tabGroup before the window is shown would give it a group of its own.
        return ["inset": inset, "tabBar": hasBeenShown && window.tabGroup?.isTabBarVisible == true]
    }
    private func openFilesPayload() -> [[String: Any]] {
        tabDocuments.map { tab in
            ["id": tab.recoveryID.uuidString, "name": tab.editorName, "path": tab.fileURL?.path ?? "", "modified": tab.isDocumentEdited, "current": tab === document]
        }
    }
    func sendOpenFiles() {
        observeTabGroup()
        send("openFiles", openFilesPayload())
        send("titlebar", titlebarPayload())
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
    @objc func undoDocument(_ sender: Any?) { doc.undoManager?.undo() }
    @objc func redoDocument(_ sender: Any?) { doc.undoManager?.redo() }
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
    var workspace: URL?
    var controller: DocumentController!
    let recoveryStore: RecoveryStore
    let settings: Settings
    private var settingsWindow: SettingsWindowController?
    private var openFilesRefreshScheduled = false
    private var launchFinished = false
    private var restorationFinished = false
    private var startupCompleted = false
    var currentEditor: EditorWindowController? { NSApp.keyWindow?.windowController as? EditorWindowController }

    init(controller: DocumentController? = nil, recoveryStore: RecoveryStore = .shared, settings: Settings = Settings()) {
        self.controller = controller
        self.recoveryStore = recoveryStore
        self.settings = settings
        super.init()
        controller?.app = self
        NotificationCenter.default.addObserver(self, selector: #selector(openFilesChanged(_:)), name: .openFilesChanged, object: nil)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if controller == nil { controller = DocumentController() }
        controller.app = self
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidFinishRestoringWindows(_:)), name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        buildMenu()
        applySettings()
        if let path = UserDefaults.standard.string(forKey: "workspace"), FileManager.default.fileExists(atPath: path) { workspace = URL(fileURLWithPath: path) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        if #available(macOS 14, *) { NSApp?.activate() } else { NSApp?.activate(ignoringOtherApps: true) }
        finishStartupIfReady()
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func showRestoredEditors() {
        for case let doc as MarkdownDocument in controller.documents where doc.wasRestored { doc.editorController?.markShown() }
    }
    @objc func applicationDidFinishRestoringWindows(_ notification: Notification) {
        showRestoredEditors()
        restorationFinished = true
        finishStartupIfReady()
    }
    private func finishStartupIfReady() {
        // Restoration can finish after didFinishLaunching. Wait for both it
        // and launch-time file opens before deciding whether a welcome is needed.
        guard launchFinished, restorationFinished, !controller.isOpening, !startupCompleted else { return }
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
    // Finder, Dock, and File > Open go straight to the document controller, and
    // editor windows prefer tabs, so those join the frontmost window. Drops and
    // workspace clicks name their window, which may not be frontmost.
    func open(_ urls: [URL], asTabsIn window: NSWindow) {
        for url in urls {
            controller.openDocument(withContentsOf: url, display: false) { [weak self] document, alreadyOpen, error in
                if let error { self?.controller.presentError(error); return }
                guard let document else { return }
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                if !alreadyOpen, let tab = document.windowControllers.first?.window, tab !== window {
                    window.tabGroup?.addWindow(tab)
                }
                document.showWindows()
            }
        }
    }
    @objc private func openFilesChanged(_ notification: Notification) { scheduleOpenFilesRefresh() }
    func scheduleOpenFilesRefresh() {
        guard !openFilesRefreshScheduled else { return }
        openFilesRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openFilesRefreshScheduled = false
            for doc in self.controller.documents { (doc as? MarkdownDocument)?.editorController?.sendOpenFiles() }
        }
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
    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"; panel.message = "Choose a folder of Markdown files."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.workspace = url; UserDefaults.standard.set(url.path, forKey: "workspace")
            if self.controller.documents.isEmpty { self.newDocument(nil) }
            self.refreshFolders()
        }
    }
    func folderPayload() -> [String: Any]? {
        guard let workspace else { return nil }
        var budget = 5000
        func entries(_ url: URL, depth: Int) -> [[String: Any]] {
            guard depth < 12, budget > 0,
                  let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            var result = [[String: Any]]()
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard budget > 0 else { break }
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                budget -= 1
                if values.isDirectory == true {
                    if ["node_modules", "vendor", "build", "dist", "DerivedData"].contains(child.lastPathComponent) { continue }
                    let nested = entries(child, depth: depth + 1)
                    if !nested.isEmpty { result.append(["name": child.lastPathComponent, "children": nested]) }
                } else if markdownExtensions.contains(child.pathExtension.lowercased()) { result.append(["name": child.lastPathComponent, "path": child.path]) }
            }
            return result.sorted { ($0["children"] != nil ? 0 : 1) < ($1["children"] != nil ? 0 : 1) }
        }
        return ["name": workspace.lastPathComponent, "path": workspace.path, "children": entries(workspace, depth: 0)]
    }
    func refreshFolders() {
        guard let payload = folderPayload() else { return }
        for doc in controller.documents { (doc as? MarkdownDocument)?.editorController?.send("folder", payload) }
    }
    @objc func webCommand(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        currentEditor?.send(parts[0], parts.count > 1 ? parts[1] : nil)
    }
    @objc func exportHTML(_ sender: Any?) { currentEditor?.send("exportHTML") }
    @objc func zoomIn(_ sender: Any?) { setTextZoom(settings.zoomedIn()) }
    @objc func zoomOut(_ sender: Any?) { setTextZoom(settings.zoomedOut()) }
    @objc func actualSize(_ sender: Any?) { setTextZoom(1) }
    func setTextZoom(_ zoom: Double) {
        settings.textZoom = zoom
        for doc in controller.documents { (doc as? MarkdownDocument)?.editorController?.send("textZoom", zoom) }
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
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: controller)
        item(file, "Open Folder…", #selector(openFolder(_:)), "o", modifiers: [.command, .shift], target: self)
        let recent = NSMenu(title: "Open Recent"); let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem)
        recent.delegate = self
        file.addItem(.separator()); item(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator()); item(file, "Export HTML…", #selector(exportHTML(_:)), target: self)
        item(file, "Print / Save as PDF…", #selector(EditorWindowController.printDocument(_:)), "p")
        let edit = menu("Edit")
        item(edit, "Undo", #selector(EditorWindowController.undoDocument(_:)), "z")
        item(edit, "Redo", #selector(EditorWindowController.redoDocument(_:)), "z", modifiers: [.command, .shift])
        edit.addItem(.separator()); item(edit, "Cut", #selector(NSText.cut(_:)), "x"); item(edit, "Copy", #selector(NSText.copy(_:)), "c"); item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator()); command(edit, "Find…", "find", "f"); command(edit, "Find and Replace…", "replace", "f", modifiers: [.command, .option]); command(edit, "Go to Line…", "goToLine", "l")
        let paragraph = menu("Paragraph")
        command(paragraph, "Body", "format:paragraph", "0", modifiers: [.command, .option])
        for level in 1...6 { command(paragraph, "Heading \(level)", "format:h\(level)", "\(level)") }
        paragraph.addItem(.separator()); command(paragraph, "Bullet List", "format:bulletList"); command(paragraph, "Numbered List", "format:orderedList"); command(paragraph, "Task List", "format:taskList"); command(paragraph, "Quote", "format:blockquote"); command(paragraph, "Code Block", "format:codeBlock"); command(paragraph, "Table", "format:table")
        let format = menu("Format")
        command(format, "Bold", "format:bold", "b"); command(format, "Italic", "format:italic", "i"); command(format, "Strikethrough", "format:strike"); command(format, "Inline Code", "format:code"); format.addItem(.separator()); command(format, "Link…", "format:link", "k"); command(format, "Image…", "format:image")
        let view = menu("View")
        command(view, "Toggle Sidebar", "sidebar", "l", modifiers: [.command, .shift]); command(view, "Document Outline", "outline"); command(view, "Source Mode", "source", "/"); view.addItem(.separator())
        item(view, "Actual Size", #selector(actualSize(_:)), "0", target: self); item(view, "Zoom In", #selector(zoomIn(_:)), "+", target: self); item(view, "Zoom Out", #selector(zoomOut(_:)), "-", target: self)
        // ⌘= also zooms in, as in browsers, without a second visible item.
        item(view, "Zoom In", #selector(zoomIn(_:)), "=", target: self); view.items.last?.isHidden = true; view.items.last?.allowsKeyEquivalentWhenHidden = true
        view.addItem(.separator()); command(view, "Typewriter Mode", "typewriter"); view.addItem(.separator()); item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        let window = menu("Window"); item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); item(window, "Zoom", #selector(NSWindow.performZoom(_:))); window.addItem(.separator()); item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))); NSApp?.windowsMenu = window
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
