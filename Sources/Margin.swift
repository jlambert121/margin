import Cocoa
import WebKit
import UniformTypeIdentifiers
import OSLog

let markdownType = "net.daringfireball.markdown"
let plainTextType = "public.plain-text"
let markdownExtensions = Set(["md", "markdown", "mdown", "mkd", "txt"])

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
    var hasUnserializedEditorChanges = false
    var onRecoveryError: ((Error) -> Void)?
    private var checkpoint: DispatchWorkItem?
    private var recoveryErrorReported = false
    var editorName: String { fileURL?.lastPathComponent ?? recoveredName ?? "Untitled.md" }
    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        editorController = controller
        addWindowController(controller)
    }
    override func data(ofType typeName: String) throws -> Data {
        guard !hasUnserializedEditorChanges else {
            throw NSError(domain: "Margin.Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Some editor changes could not be read. Saving was cancelled to avoid writing an older version of your text."])
        }
        return Data(text.utf8)
    }
    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(recoveryID.uuidString, forKey: "Margin.recoveryID")
        coder.encode(recoveredName, forKey: "Margin.recoveredName")
        coder.encode(recoveredOriginalURL?.path, forKey: "Margin.recoveredOriginalPath")
    }
    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
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
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "This file is not UTF-8 text. Convert it to UTF-8 before opening it."])
        }
        text = decoded
        hasUnserializedEditorChanges = false
        editorController?.loadDocument()
    }
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        clearRecovery()
    }
    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let savedText = text
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        if saveOperation != .saveToOperation && saveOperation != .autosaveElsewhereOperation {
            if text == savedText { clearRecovery() }
            else { flushRecovery() }
            editorController?.loadMetadata()
        }
    }
    func edited(_ next: String) {
        hasUnserializedEditorChanges = false
        guard next != text else { return }
        let previous = text
        let manager = undoManager
        manager?.registerUndo(withTarget: self) { doc in doc.restore(previous) }
        manager?.setActionName("Typing")
        text = next
        // NSDocument tracks undo groups itself. Explicitly incrementing as
        // well counts every edit twice and prevents Undo from clearing dirty.
        if manager == nil { updateChangeCount(.changeDone) }
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
        super.close()
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

final class EditorWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let assets = AssetHandler()
    var ready = false
    private(set) var session = EditorSession()
    private(set) var hasEditorFailure = false
    private var loadTimeout: DispatchWorkItem?
    private var lastReportedError: String?
    private var failureText: NSTextView?
    private let logger = Logger(subsystem: "com.infiniteviewtech.margin", category: "Editor")
    var pendingPath: URL?
    var doc: MarkdownDocument { document as! MarkdownDocument }
    var appDelegate: AppDelegate { NSApp.delegate as! AppDelegate }

    init(document: MarkdownDocument) {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(assets, forURLScheme: "markdown-asset")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 700, height: 480)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("MarkdownEditor")
        window.isRestorable = true
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("MarginEditor")
        super.init(window: window)
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
        window?.contentView = webView
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
            self.doc.hasUnserializedEditorChanges = false
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
        // The fallback explicitly offers the displayed, last-received text.
        doc.hasUnserializedEditorChanges = false
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
    func loadDocument() {
        guard ready else { return }
        webView.isHidden = true
        let token = session.beginLoad()
        armLoadTimeout()
        assets.root = (doc.fileURL ?? doc.recoveredOriginalURL)?.deletingLastPathComponent()
        var payload: [String: Any] = ["text": doc.text, "token": token, "name": doc.editorName, "path": doc.fileURL?.path ?? "", "modified": doc.isDocumentEdited]
        if let folder = appDelegate.folderPayload() { payload["folder"] = folder }
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
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            guard !hasEditorFailure else { return }
            ready = true; loadDocument()
        case "loaded":
            guard !hasEditorFailure, let token = body["token"] as? String else { return }
            session.acknowledge(token)
            if session.isLoaded { loadTimeout?.cancel(); loadTimeout = nil; webView.isHidden = false }
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
        case "editorSerializationError":
            guard let token = body["token"] as? String, session.accepts(token) else { return }
            doc.hasUnserializedEditorChanges = true
            if !doc.isDocumentEdited { doc.updateChangeCount(.changeDone) }
            reportEditorError("The latest edit could not be converted to Markdown. Save will retry reading the editor; if that fails, copy your text before closing the window.")
        case "new": appDelegate.newDocument(nil)
        case "open": appDelegate.controller.openDocument(nil)
        case "openFolder": appDelegate.openFolder(nil)
        case "refreshFolder": appDelegate.refreshFolders()
        case "save": doc.save(nil)
        case "saveAs": doc.saveAs(nil)
        case "print": printDocument(nil)
        case "exportHTML": if let html = body["html"] as? String { exportHTML(html) }
        case "openPath":
            if let path = body["path"] as? String, let folder = appDelegate.workspace {
                let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                let root = folder.standardizedFileURL.resolvingSymlinksInPath()
                guard url.path.hasPrefix(root.path + "/"), markdownExtensions.contains(url.pathExtension.lowercased()), url != doc.fileURL else { return }
                pendingPath = url
                doc.canClose(withDelegate: self, shouldClose: #selector(canSwitch(_:shouldClose:contextInfo:)), contextInfo: nil)
            }
        case "openExternal":
            if let string = body["url"] as? String, let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        case "appearance":
            window?.appearance = NSAppearance(named: (body["theme"] as? String) == "dark" ? .darkAqua : .aqua)
        default: break
        }
    }
    @objc func canSwitch(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let url = pendingPath else { pendingPath = nil; return }
        pendingPath = nil
        appDelegate.controller.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
            else { document.close() }
        }
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
        // Ensure source mode is converted before the print operation snapshots it.
        guard canSynchronize else { reportEditorError("Printing is unavailable until the editor has loaded."); return }
        webView.evaluateJavaScript("if(window.app.isSource()) window.app.command('source')") { [weak self] _, error in
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
    private var pendingFileOpens = 0
    private var launchFinished = false
    private var restorationFinished = false
    private var startupCompleted = false
    var currentEditor: EditorWindowController? { NSApp.keyWindow?.windowController as? EditorWindowController }

    init(controller: DocumentController? = nil, recoveryStore: RecoveryStore = .shared) {
        self.controller = controller
        self.recoveryStore = recoveryStore
        super.init()
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        if controller == nil { controller = DocumentController() }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidFinishRestoringWindows(_:)), name: NSApplication.didFinishRestoringWindowsNotification, object: NSApp)
        buildMenu()
        if let path = UserDefaults.standard.string(forKey: "workspace"), FileManager.default.fileExists(atPath: path) { workspace = URL(fileURLWithPath: path) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        NSApp?.activate(ignoringOtherApps: true)
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
        guard launchFinished, restorationFinished, pendingFileOpens == 0, !startupCompleted else { return }
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
                if let markdown = doc as? MarkdownDocument,
                   let url = Bundle.main.url(forResource: "Welcome", withExtension: "md") {
                    markdown.text = try String(contentsOf: url, encoding: .utf8)
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
    // Associated document types normally go through NSDocumentController.
    // This also handles URL events forwarded directly by Finder or the Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        openFiles(urls)
    }
    func openFiles(_ urls: [URL]) {
        pendingFileOpens += urls.count
        for url in urls {
            controller.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                guard let self else { return }
                self.pendingFileOpens -= 1
                if let error { self.controller.presentError(error) }
                self.finishStartupIfReady()
            }
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
        edit.addItem(.separator()); command(edit, "Find…", "find", "f")
        let paragraph = menu("Paragraph")
        command(paragraph, "Body", "format:paragraph", "0")
        for level in 1...6 { command(paragraph, "Heading \(level)", "format:h\(level)", "\(level)") }
        paragraph.addItem(.separator()); command(paragraph, "Bullet List", "format:bulletList"); command(paragraph, "Numbered List", "format:orderedList"); command(paragraph, "Task List", "format:taskList"); command(paragraph, "Quote", "format:blockquote"); command(paragraph, "Code Block", "format:codeBlock"); command(paragraph, "Table", "format:table")
        let format = menu("Format")
        command(format, "Bold", "format:bold", "b"); command(format, "Italic", "format:italic", "i"); command(format, "Strikethrough", "format:strike"); command(format, "Inline Code", "format:code"); format.addItem(.separator()); command(format, "Link…", "format:link", "k"); command(format, "Image…", "format:image")
        let view = menu("View")
        command(view, "Toggle Sidebar", "sidebar", "l", modifiers: [.command, .shift]); command(view, "Document Outline", "outline"); command(view, "Source Mode", "source", "/"); view.addItem(.separator()); command(view, "Focus Mode", "focus", "f", modifiers: [.command, .shift]); command(view, "Typewriter Mode", "typewriter"); view.addItem(.separator()); command(view, "Paper", "theme:light"); command(view, "Parchment", "theme:sepia"); command(view, "Midnight", "theme:dark"); view.addItem(.separator()); item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
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
