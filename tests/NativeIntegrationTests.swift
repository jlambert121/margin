import Cocoa

// Exercise launch ordering without requiring a window server or WebKit.
final class StartupTestDocument: NSDocument {
    var presentations = 0
    override func makeWindowControllers() {}
    override func showWindows() { presentations += 1 }
}

final class OpenRequestController: DocumentController {
    var requests: [(URL, Bool)] = []
    var useNativeOpening = false
    var useWindowlessDocuments = false
    var untitledRequests = 0
    var deferOpening = false
    var pendingCompletions: [(NSDocument?, Bool, Error?) -> Void] = []
    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        untitledRequests += 1
        if useWindowlessDocuments {
            let doc = StartupTestDocument()
            doc.fileType = typeName
            return doc
        }
        return try super.makeUntitledDocument(ofType: typeName)
    }
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        requests.append((url, displayDocument))
        if useNativeOpening {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        } else if deferOpening {
            pendingCompletions.append(completionHandler)
        } else { completionHandler(nil, false, nil) }
    }
}

final class FakeDrop: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow) { draggingPasteboard = pasteboard; draggingDestinationWindow = window }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 400, y: 300) }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@main struct NativeIntegrationTests {
    static func main() throws {
        setbuf(stdout, nil)
        // NSDocumentController initialization returns the existing singleton,
        // even when invoked on a different subclass. Install the spy first.
        let controller = OpenRequestController()
        controller.useNativeOpening = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-integration-\(UUID().uuidString)")
        let recoveryStore = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let delegate = AppDelegate(controller: controller, recoveryStore: recoveryStore)
        let application = CommandLine.arguments.contains("--ui") ? NSApplication.shared : nil
        application?.delegate = delegate
        var failures = 0
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "NativeIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func test(_ name: String, _ block: @MainActor () throws -> Void) {
            do { try block(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func waitUntil(_ finished: () -> Bool) throws {
            let limit = Date().addingTimeInterval(15)
            while !finished() && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try expect(finished(), "Native operation timed out")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("A real file.md")
        let second = root.appendingPathComponent("Another.markdown")
        let text = "# Opened through AppKit\n\nA real Markdown file.\n"
        try text.write(to: first, atomically: true, encoding: .utf8)
        try "# Another file\n".write(to: second, atomically: true, encoding: .utf8)

        test("Bundle document class resolves and declares readable/writable UTIs") {
            let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
            try expect(!types.isEmpty, "Runner must execute inside an app bundle")
            for entry in types {
                guard let className = entry["NSDocumentClass"] as? String else { throw NSError(domain: "Tests", code: 1) }
                try expect(NSClassFromString(className) == MarkdownDocument.self, "Info.plist class does not resolve")
                for type in entry["LSItemContentTypes"] as? [String] ?? [] {
                    try expect(MarkdownDocument.readableTypes.contains(type), "Missing readable type: \(type)")
                    try expect(MarkdownDocument.writableTypes.contains(type), "Missing writable type: \(type)")
                }
            }
            try expect(controller.defaultType == markdownType, "Default document type is not a declared UTI")
            try expect(controller === NSDocumentController.shared, "AppKit is using a different shared controller")
        }
        test("Open is enabled by AppKit's document-controller validator") {
            let open = NSMenuItem(title: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
            open.target = controller
            try expect(controller.validateUserInterfaceItem(open), "AppKit disables File > Open")
            if let application {
                delegate.buildMenu()
                guard let file = application.mainMenu?.items.first(where: { $0.submenu?.title == "File" })?.submenu,
                      let menuOpen = file.items.first(where: { $0.action == open.action }) else {
                    throw NSError(domain: "Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "File > Open is missing"])
                }
                try expect(menuOpen.target === controller, "Open targets a different controller")
                file.update()
                try expect(menuOpen.isEnabled, "Open is greyed out after automatic menu validation")
            }
        }
        test("New documents have a writable native type and Save As is enabled") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType)
            try expect(doc.fileType == markdownType, "Untitled document has no file type")
            try expect(doc.writableTypes(for: .saveAsOperation).contains(markdownType), "No writable type for Save As")
            let saveAs = NSMenuItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "")
            try expect(doc.validateUserInterfaceItem(saveAs), "AppKit disables Save As")
        }
        let launched = Notification(name: NSApplication.didFinishLaunchingNotification)
        let restored = Notification(name: NSApplication.didFinishRestoringWindowsNotification)
        test("Restored documents suppress the welcome even when restoration finishes after launch") {
            controller.useWindowlessDocuments = true
            controller.untitledRequests = 0
            defer { controller.useWindowlessDocuments = false }
            let startup = AppDelegate(controller: controller, recoveryStore: recoveryStore)
            startup.applicationDidFinishLaunching(launched)
            try expect(controller.untitledRequests == 0, "Welcome appeared before restoration finished")
            let doc = StartupTestDocument()
            controller.addDocument(doc)
            defer { controller.removeDocument(doc) }
            startup.applicationDidFinishRestoringWindows(restored)
            try expect(controller.untitledRequests == 0, "Welcome appeared beside a restored document")
            try expect(controller.documents.count == 1, "Startup duplicated a restored document")
        }
        test("Empty startup shows one welcome when restoration finishes before launch") {
            controller.useWindowlessDocuments = true
            controller.untitledRequests = 0
            defer {
                controller.documents.forEach { controller.removeDocument($0) }
                controller.useWindowlessDocuments = false
            }
            let startup = AppDelegate(controller: controller, recoveryStore: recoveryStore)
            startup.applicationDidFinishRestoringWindows(restored)
            try expect(controller.untitledRequests == 0, "Welcome appeared before launch finished")
            startup.applicationDidFinishLaunching(launched)
            startup.applicationDidFinishRestoringWindows(restored)
            try expect(controller.untitledRequests == 1, "Empty startup did not create exactly one welcome")
            try expect((controller.documents.first as? StartupTestDocument)?.presentations == 1, "Welcome was not presented")
        }
        test("Pending launch file opens suppress the welcome until their completion") {
            controller.useWindowlessDocuments = true
            controller.useNativeOpening = false
            controller.deferOpening = true
            controller.untitledRequests = 0
            defer {
                controller.documents.forEach { controller.removeDocument($0) }
                controller.pendingCompletions.removeAll()
                controller.useWindowlessDocuments = false
                controller.useNativeOpening = true
                controller.deferOpening = false
            }
            let startup = AppDelegate(controller: controller, recoveryStore: recoveryStore)
            startup.openFiles([first])
            startup.applicationDidFinishLaunching(launched)
            startup.applicationDidFinishRestoringWindows(restored)
            try expect(controller.untitledRequests == 0, "Welcome appeared while a launch file was opening")
            let doc = StartupTestDocument()
            controller.addDocument(doc)
            controller.pendingCompletions.removeFirst()(doc, false, nil)
            try expect(controller.untitledRequests == 0, "Welcome appeared beside the opened file")
        }
        test("Recovery opens unsaved edits as a separate dirty document without overwriting the file") {
            let draft = RecoveryDraft(id: UUID(), text: "# Unsaved after a crash\n", originalPath: first.path, name: first.lastPathComponent)
            try recoveryStore.write(draft)
            defer { controller.documents.forEach { $0.close(); controller.removeDocument($0) } }
            try expect(try delegate.recoverDocuments(display: false).isEmpty, "Recovery reported an error")
            guard let recovered = controller.documents.first as? MarkdownDocument else { throw CocoaError(.fileReadUnknown) }
            try expect(recovered.fileURL == nil && recovered.isDocumentEdited, "Recovery is not a separate unsaved document")
            try expect(recovered.text == draft.text && recovered.editorName == "Recovered " + first.lastPathComponent, "Recovery text or name changed")
            try expect(try String(contentsOf: first, encoding: .utf8) == text, "Recovery overwrote the original file")
            try expect(try delegate.recoverDocuments(display: false).isEmpty && controller.documents.count == 1, "Recovery duplicated a document already open")
        }
        test("Recovery does not duplicate a document already restored with the same text") {
            let draft = RecoveryDraft(id: UUID(), text: text, originalPath: first.path, name: first.lastPathComponent)
            try recoveryStore.write(draft)
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore; doc.text = text; doc.fileURL = first
            controller.addDocument(doc)
            defer { doc.close(); controller.removeDocument(doc) }
            try expect(try delegate.recoverDocuments(display: false).isEmpty, "Recovery reported an error")
            try expect(controller.documents.count == 1, "Recovery added a duplicate alongside a restored document")
            try expect(try recoveryStore.readAll().drafts.isEmpty, "An already-saved recovery was kept")
        }
        let settingsSuite = "margin-settings-tests-\(UUID().uuidString)"
        let settingsDefaults = UserDefaults(suiteName: settingsSuite)!
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuite) }
        test("Settings default to Auto appearance and the Night icon, and persist choices") {
            let settings = Settings(defaults: settingsDefaults)
            try expect(settings.appearance == .auto && settings.appIcon == .night, "Unexpected default settings")
            settings.appearance = .dark; settings.appIcon = .serif
            let reloaded = Settings(defaults: settingsDefaults)
            try expect(reloaded.appearance == .dark && reloaded.appIcon == .serif, "Settings did not persist")
            settingsDefaults.set("missing", forKey: "appIcon")
            try expect(reloaded.appIcon == .night, "Unknown icon did not fall back to Night")
            settingsDefaults.removePersistentDomain(forName: settingsSuite)
        }
        test("Every icon choice is bundled and only Night uses the bundle icon") {
            for choice in AppIconChoice.allCases { try expect(choice.image != nil, "Missing bundled icon: \(choice.rawValue)") }
            try expect(AppIconChoice.night.dockImage == nil, "Night should restore the bundle icon")
            try expect(AppIconChoice.allCases.filter { $0 != .night }.allSatisfy { $0.dockImage != nil }, "A choice has no Dock image")
        }
        test("Settings is in the app menu and appearance is no longer in View") {
            let bar = delegate.makeMenu()
            let app = bar.items.first?.submenu
            let item = app?.items.first(where: { $0.action == #selector(AppDelegate.showSettings(_:)) })
            try expect(item?.keyEquivalent == "," && item?.keyEquivalentModifierMask == [.command], "Settings… is not on ⌘,")
            let view = bar.items.first(where: { $0.submenu?.title == "View" })?.submenu
            try expect(view?.items.contains(where: { ["Light", "Dark", "Auto"].contains($0.title) }) == false, "View still lists appearance choices")
        }
        test("Settings window choices update the stored settings") {
            let settings = Settings(defaults: settingsDefaults)
            var changes = 0
            let window = SettingsWindowController(settings: settings) { changes += 1 }
            try expect(window.iconTiles.count == AppIconChoice.allCases.count, "Not every icon is offered")
            window.appearanceControl.selectedSegment = AppearanceChoice.allCases.firstIndex(of: .light)!
            window.appearanceChanged(window.appearanceControl)
            let quote = NSButton(); quote.tag = AppIconChoice.allCases.firstIndex(of: .quote)!
            window.iconChosen(quote)
            try expect(settings.appearance == .light && settings.appIcon == .quote && changes == 2, "Settings window did not apply choices")
            try expect(window.iconTiles[.quote]?.fillColor != .clear && window.iconTiles[.night]?.fillColor == .clear, "Selection highlight is wrong")
            settingsDefaults.removePersistentDomain(forName: settingsSuite)
        }
        if application != nil {
        test("Appearance setting reaches the app and a loaded editor") {
            let settings = Settings(defaults: settingsDefaults)
            let themed = AppDelegate(controller: controller, recoveryStore: recoveryStore, settings: settings)
            let original = application?.delegate
            application?.delegate = themed
            defer { application?.delegate = original; settingsDefaults.removePersistentDomain(forName: settingsSuite); delegate.applySettings() }
            settings.appearance = .dark; settings.appIcon = .ruled
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            themed.applySettings()
            try expect(application?.appearance?.name == .darkAqua, "App appearance is not dark")
            try expect(application?.applicationIconImage !== NSImage(named: NSImage.applicationIconName), "Dock icon was not replaced")
            guard let editor = doc.editorController else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.canSynchronize && !editor.webView.isHidden }
            var bodyTheme: String?
            func poll() { editor.webView.evaluateJavaScript("document.body.dataset.theme") { result, _ in bodyTheme = result as? String } }
            try waitUntil { poll(); return bodyTheme == "dark" }
            settings.appearance = .light; themed.applySettings()
            try waitUntil { poll(); return bodyTheme == "light" }
        }
        test("Documents open as tabs, list their tab group, and accept Markdown drops") {
            let opened = { (url: URL) in controller.documents.first { $0.fileURL == url } as? MarkdownDocument }
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            let b = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            for doc in [a, b] { doc.recoveryStore = recoveryStore; controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows() }
            defer { for doc in controller.documents { doc.close() } }
            guard let editorA = a.editorController, let editorB = b.editorController, let windowA = editorA.window else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { windowA.tabbedWindows?.count == 2 }
            try expect(editorA.tabDocuments.map(\.recoveryID) == editorB.tabDocuments.map(\.recoveryID), "Tabs disagree about their group")
            try waitUntil { editorB.canSynchronize && editorA.canSynchronize }
            var listed = -1
            func pollListed(_ editor: EditorWindowController) { editor.webView.evaluateJavaScript("document.querySelectorAll('#open-files .open-file').length") { result, _ in listed = result as? Int ?? -1 } }
            try waitUntil { pollListed(editorB); return listed == 2 }

            editorA.appDelegate.openFiles([first], asTabsIn: windowA)
            try waitUntil { opened(first)?.editorController?.window.map { windowA.tabbedWindows?.contains($0) == true } == true }
            let count = controller.documents.count
            editorA.appDelegate.openFiles([first], asTabsIn: windowA)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            try expect(controller.documents.count == count && windowA.tabbedWindows?.count == 3, "Reopening an open file added a tab")
            try waitUntil { pollListed(editorA); return listed == 3 }

            let image = root.appendingPathComponent("picture.png")
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("margin-drop-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents(); pasteboard.writeObjects([image as NSURL])
            try expect(EditorWebView.markdownFiles(on: pasteboard).isEmpty, "Image drops were taken from the editor")
            pasteboard.clearContents(); pasteboard.writeObjects([second as NSURL])
            let drop = FakeDrop(pasteboard: pasteboard, window: windowA)
            try expect(editorA.webView.draggingEntered(drop) == .copy, "Markdown drop not accepted")
            try expect(editorA.webView.prepareForDragOperation(drop) && editorA.webView.performDragOperation(drop), "Markdown drop not performed")
            try waitUntil { opened(second)?.editorController?.window.map { windowA.tabbedWindows?.contains($0) == true } == true }

            guard let firstDoc = opened(first) else { throw CocoaError(.fileReadUnknown) }
            editorA.closeTab(id: firstDoc.recoveryID.uuidString)
            try waitUntil { opened(first) == nil }
            try waitUntil { windowA.tabbedWindows?.count == 3 }
            try waitUntil { pollListed(editorA); return listed == 3 }
        }
        test("Launch without a file registers and shows an editor window") {
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            delegate.applicationDidFinishRestoringWindows(restored)
            guard let doc = controller.documents.first as? MarkdownDocument else {
                throw NSError(domain: "Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch did not create a Markdown document"])
            }
            defer { doc.close() }
            try expect(doc.windowControllers.count == 1, "Document has no registered editor window")
            try expect(doc.editorController === doc.windowControllers.first, "Editor is not registered with its document")
            try expect(doc.editorController?.document === doc, "Window controller is not attached to the document")
            try expect(doc.editorController?.window?.isVisible == true, "Launch did not show a window")
            try expect(doc.editorController?.window?.isRestorable == true, "Document window cannot be restored")
            try expect(doc.editorController?.window?.restorationClass == type(of: controller), "Document window is not using native document restoration")
        }
        test("Editor process failure keeps native edits, exposes a save fallback, and retries from memory") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            guard let editor = doc.editorController else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.session.isLoaded }
            let unsaved = "# Protected after editor failure\n\nNot saved to the original file.\n"
            doc.edited(unsaved); editor.loadDocument()
            try waitUntil { editor.session.isLoaded }
            editor.webViewWebContentProcessDidTerminate(editor.webView)
            try expect(editor.hasEditorFailure && doc.text == unsaved && doc.isDocumentEdited, "Process failure cleared native edits")
            try expect(editor.window?.contentView !== editor.webView, "No native error fallback was shown")
            try expect(try recoveryStore.readAll().drafts.contains(where: { $0.id == doc.recoveryID && $0.text == unsaved }), "Failure did not checkpoint current edits")
            editor.perform(NSSelectorFromString("retryEditor:"), with: nil)
            try waitUntil { editor.session.isLoaded && !editor.hasEditorFailure }
            var result: String?
            editor.webView.evaluateJavaScript("window.app.getMarkdown()") { value, _ in result = value as? String }
            try waitUntil { result != nil }
            try expect(result == unsaved, "Retry reloaded stale file contents instead of native edits")
        }
        test("AppKit opens files and reuses documents already open") {
            var finished = false
            var opened: MarkdownDocument?
            var failure: Error?
            controller.openDocument(withContentsOf: first, display: true) { doc, _, error in
                opened = doc as? MarkdownDocument; failure = error; finished = true
            }
            try waitUntil { finished }
            if let failure { throw failure }
            try expect(opened?.text == text && opened?.fileURL == first, "Native open did not read the file")
            try expect(opened.map { controller.documents.contains($0) } == true, "Native open did not register the document")
            try expect(opened?.windowControllers.count == 1, "File open did not register an editor window")
            try expect(opened?.editorController?.window?.isVisible == true, "File open did not show a window")
            finished = false
            var reused = false
            controller.openDocument(withContentsOf: first, display: false) { doc, alreadyOpen, error in
                reused = alreadyOpen && doc === opened; failure = error; finished = true
            }
            try waitUntil { finished }
            if let failure { throw failure }
            try expect(reused, "Opening the same file created a duplicate document")
            opened?.close()
        }
        test("Native Save As, Save, and reopen preserve edits on disk") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc)
            defer { doc.close() }
            let destination = root.appendingPathComponent("Saved.md")
            @MainActor func save(_ operation: NSDocument.SaveOperationType) throws {
                var finished = false
                var failure: Error?
                doc.save(to: destination, ofType: markdownType, for: operation) { error in failure = error; finished = true }
                try waitUntil { finished }
                if let failure { throw failure }
            }
            doc.edited("# First save\n")
            try save(.saveAsOperation)
            try expect(doc.fileURL == destination && !doc.isDocumentEdited, "Save As did not set the path and clear the dirty state")
            doc.edited("# Updated\n\nSaved with native document handling.\n")
            try save(.saveOperation)
            try expect(!doc.isDocumentEdited, "Save did not clear the dirty state")
            let reopened = try controller.makeDocument(withContentsOf: destination, ofType: markdownType) as! MarkdownDocument
            try expect(reopened.text == doc.text, "Saved edits were lost after reopen")
        }
        } else {
            print("SKIP Full AppKit Open/Save and visible-menu checks require a desktop session: ./scripts/test-native.sh --ui")
        }
        test("Finder and Dock URL handlers forward every file to the document controller") {
            let requests = controller
            requests.requests.removeAll()
            requests.useNativeOpening = application != nil
            let eventDelegate = AppDelegate(controller: requests, recoveryStore: recoveryStore)
            try expect(eventDelegate.responds(to: NSSelectorFromString("application:openURLs:")), "File URL callback is not exposed to AppKit")
            if let application { eventDelegate.application(application, open: [first, second]) }
            else { eventDelegate.openFiles([first, second]) }
            if application != nil { try waitUntil { requests.documents.count == 2 } }
            try expect(requests.requests.map { $0.0 } == [first, second], "Dock request URLs were lost")
            try expect(requests.requests.allSatisfy { $0.1 }, "Dock requests do not request visible document windows")
            if application != nil { try expect((requests.documents.first(where: { $0.fileURL == first }) as? MarkdownDocument)?.text == text, "Dock file content not loaded") }
            if application != nil {
                try expect(requests.documents.allSatisfy { $0.windowControllers.first?.window?.isVisible == true }, "Dock open did not show every document window")
            }
            for doc in requests.documents { requests.removeDocument(doc); doc.close() }
        }
        if failures > 0 { exit(1) }
    }
}
