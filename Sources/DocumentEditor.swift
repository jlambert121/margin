import Cocoa
import OSLog
import UniformTypeIdentifiers
import WebKit

final class MessageBridge: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// The editor fills the window under the title bar, and the web view does not
/// move the window, so this strip over the title bar's height does.
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
    var isShowingFailure: Bool {
        failureView != nil
    }

    var doc: MarkdownDocument {
        document!
    }

    var window: NSWindow? {
        host?.window
    }

    private var app: AppDelegate? {
        (NSDocumentController.shared as? DocumentController)?.app
    }

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
            titlebarDragView.leadingAnchor.constraint(equalTo: view.leadingAnchor), titlebarDragView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
    /// The document closed; its page must not reach the app any more.
    func tearDown() {
        loadTimeout?.cancel(); loadTimeout = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "native")
        webView.stopLoading()
        view.removeFromSuperview()
    }

    var canSynchronize: Bool {
        ready && session.isLoaded && !hasEditorFailure
    }

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
            if self.session.isLoaded {
                self.reportEditorError("An editor command failed: \(error.localizedDescription)")
            } else {
                self.showEditorFailure("The document could not be displayed: \(error.localizedDescription)")
            }
        }
    }

    func synchronize(_ completion: @escaping (Bool) -> Void) {
        let token = session.token
        webView.evaluateJavaScript("window.app.snapshot()") { [weak self] result, error in
            guard let self else { completion(false); return }
            guard token == self.session.token, error == nil, let snapshot = result as? [String: Any],
                  let text = snapshot["text"] as? String, let revision = snapshot["revision"] as? Int,
                  snapshot["token"] as? String == token, self.session.accepts(token)
            else {
                self.reportEditorError("The latest editor text could not be read. Saving was cancelled; your last received edits are still in memory.")
                completion(false)
                return
            }
            if self.session.acceptChange(token: token, revision: revision) {
                self.doc.edited(text)
            }
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
        if doc.isDocumentEdited {
            doc.flushRecovery()
        }
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
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -36),
        ])
        webView.isHidden = true
        // NSTextView's initial frame must follow the laid-out scroll viewport.
        view.layoutSubtreeIfNeeded()
        text.setFrameSize(scroll.contentSize)
    }

    @objc private func retryEditor(_: Any?) {
        startEditor()
    }

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
        if !session.isLoaded {
            webView.isHidden = true
        }
        let token = session.beginLoad()
        armLoadTimeout()
        assets.root = (doc.fileURL ?? doc.recoveredOriginalURL)?.deletingLastPathComponent()
        var payload: [String: Any] = ["text": doc.text, "token": token, "name": doc.editorName, "path": doc.fileURL?.path ?? "", "modified": doc.isDocumentEdited]
        if let zoom = app?.settings.textZoom {
            payload["textZoom"] = zoom
        }
        payload["titlebar"] = ["inset": view.safeAreaInsets.top]
        sentTitlebarInset = view.safeAreaInsets.top
        if let host {
            payload["sidebarOpen"] = !host.sidebarItem.isCollapsed
        }
        if let notice {
            payload["notice"] = notice
        }
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

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
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
               let revision = body["revision"] as? Int, session.acceptChange(token: token, revision: revision)
            {
                doc.edited(text)
                failureText?.string = doc.text
            }
        case "editorError":
            let message = body["message"] as? String ?? "An editor operation failed."
            if session.isLoaded {
                reportEditorError(message)
            } else {
                showEditorFailure(message)
            }
        case "undo": doc.undoManager?.undo()
        case "redo": doc.undoManager?.redo()
        case "new": app?.newDocument(nil)
        case "open": NSDocumentController.shared.openDocument(nil)
        case "openFolder": app?.openFolder(nil)
        case "save": doc.save(nil)
        case "diskReload": doc.confirmReloadFromDisk()
        case "diskKeepMine": doc.keepMine()
        case "diskSaveAs": doc.saveAs(nil)
        case "saveAs": doc.saveAs(nil)
        case "print": printDocument(nil)
        case "exportHTML": if let html = body["html"] as? String {
                exportHTML(html)
            }
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
            if host?.current === document {
                host?.sidebar.setHeadings(headings)
            }
        case "openExternal":
            if let string = body["url"] as? String, let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    private func sendTitlebar() {
        let inset = view.safeAreaInsets.top
        guard canSynchronize, inset != sentTitlebarInset else { return }
        sentTitlebarInset = inset
        send("titlebar", ["inset": inset])
    }

    /// Insert items first, then the Paragraph and Format menus' commands.
    func documentMenuItems() -> [NSMenuItem] {
        func format(_ title: String, _ kind: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(formatFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = kind
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem?]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            for item in items {
                menu.addItem(item ?? .separator())
            }
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); parent.submenu = menu
            return parent
        }
        let headings = (1 ... 6).map { format("Heading \($0)", "h\($0)") }
        return [
            format("Insert Table", "table"), format("Insert Link…", "link"), format("Insert Image…", "image"), format("Insert Code Block", "codeBlock"),
            submenu("Paragraph", [format("Body", "paragraph")] + headings + [nil, format("Bullet List", "bulletList"), format("Numbered List", "orderedList"), format("Task List", "taskList"), format("Quote", "blockquote")]),
            submenu("Format", [format("Bold", "bold"), format("Italic", "italic"), format("Strikethrough", "strike"), format("Inline Code", "code")]),
        ]
    }

    @objc func formatFromMenu(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? String else { return }
        send("format", kind)
    }

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url, ["https", "http", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        } else if let url = navigationAction.request.url, url.isFileURL, url.lastPathComponent == "index.html" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        showEditorFailure("The editor could not be loaded: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
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

    @objc func printDocument(_: Any?) {
        // The page prints a rendered copy of the Markdown rather than the editor.
        guard canSynchronize else { reportEditorError("Printing is unavailable until the editor has loaded."); return }
        webView.evaluateJavaScript("window.app.preparePrint()") { [weak self] _, error in
            guard let self, let window = self.window else { return }
            if let error {
                self.reportEditorError("The document could not be prepared for printing: \(error.localizedDescription)"); return
            }
            let info = self.doc.printInfo
            info.topMargin = 45; info.bottomMargin = 45; info.leftMargin = 45; info.rightMargin = 45
            let operation = self.webView.printOperation(with: info)
            operation.showsPrintPanel = true
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
    }
}
