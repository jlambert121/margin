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
    override func performOpen(_ url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        requests.append((url, displayDocument))
        if useNativeOpening {
            super.performOpen(url, display: displayDocument, completionHandler: completionHandler)
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
        // Tests that build their own AppDelegate take over controller.app; give it back.
        func test(_ name: String, _ block: @MainActor () throws -> Void) {
            do { try block(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
            controller.app = delegate
        }
        func waitUntil(line: Int = #line, _ finished: () -> Bool) throws {
            let limit = Date().addingTimeInterval(15)
            while !finished() && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try expect(finished(), "Native operation timed out (line \(line))")
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
        test("Launch-time file opens suppress the welcome until they finish") {
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
            // AppKit delivers Finder's launch-time opens here, before didFinishLaunching.
            controller.openDocument(withContentsOf: first, display: true) { _, _, _ in }
            startup.applicationDidFinishRestoringWindows(restored)
            startup.applicationDidFinishLaunching(launched)
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
        test("Settings is in the app menu on ⌘,") {
            let bar = delegate.makeMenu()
            let app = bar.items.first?.submenu
            let item = app?.items.first(where: { $0.action == #selector(AppDelegate.showSettings(_:)) })
            try expect(item?.keyEquivalent == "," && item?.keyEquivalentModifierMask == [.command], "Settings… is not on ⌘,")
        }
        test("Text zoom steps, clamps, and persists") {
            let settings = Settings(defaults: settingsDefaults)
            try expect(settings.textZoom == 1, "Default text zoom is not 100%")
            try expect(settings.zoomedIn() == 1.1 && settings.zoomedOut() == 0.9, "Zoom does not step from 100%")
            settings.textZoom = 3
            try expect(Settings(defaults: settingsDefaults).zoomedIn() == 3, "Zoom in went past the largest size")
            settings.textZoom = 0.5
            try expect(settings.zoomedOut() == 0.5, "Zoom out went past the smallest size")
            settingsDefaults.set(40.0, forKey: "textZoom")
            try expect(settings.textZoom == 3, "A stored zoom outside the range was not clamped")
            settingsDefaults.removePersistentDomain(forName: settingsSuite)
        }
        test("Zoom, find and replace, and go to line have their shortcuts, and Body moved to Option-Command-0") {
            let bar = delegate.makeMenu()
            let items = bar.items.compactMap(\.submenu).flatMap(\.items)
            func shortcut(_ title: String) -> (String, NSEvent.ModifierFlags)? { items.first { $0.title == title && !$0.isHidden }.map { ($0.keyEquivalent, $0.keyEquivalentModifierMask) } }
            try expect(shortcut("Actual Size")! == ("0", [.command]) && shortcut("Zoom In")! == ("+", [.command]) && shortcut("Zoom Out")! == ("-", [.command]), "Zoom shortcuts are wrong")
            try expect(items.contains { $0.title == "Zoom In" && $0.isHidden && $0.keyEquivalent == "=" && $0.allowsKeyEquivalentWhenHidden }, "⌘= does not zoom in")
            try expect(shortcut("Body")! == ("0", [.command, .option]), "Body is not on ⌥⌘0")
            try expect(shortcut("Find and Replace…")! == ("f", [.command, .option]) && shortcut("Go to Line…")! == ("l", [.command]), "Find and Replace or Go to Line shortcut is wrong")
            try expect(shortcut("Quick Open…")! == ("p", [.command, .option]) && shortcut("Paste and Match Style")! == ("v", [.command, .option, .shift]), "Quick Open or Paste and Match Style shortcut is wrong")
            try expect(shortcut("Print / Save as PDF…")! == ("p", [.command]), "Print lost ⌘P")
            try expect(shortcut("Previous File")! == ("{", [.command]) && shortcut("Next File")! == ("}", [.command]), "Previous or Next File is not on ⌘⇧[ / ⌘⇧]")
            try expect(shortcut("Close")! == ("w", [.command]) && shortcut("Close Window")! == ("w", [.command, .shift]) && shortcut("New Window")! == ("n", [.command, .shift]), "Close, Close Window, or New Window shortcut is wrong")
            try expect(items.first { $0.title == "Close" }?.action == #selector(EditorWindowController.closeDocument(_:)), "⌘W closes the window instead of the document")
        }
        test("⌘⇧[ and ⌘⇧] reach Previous and Next File") {
            let bar = delegate.makeMenu()
            func press(_ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> Bool {
                bar.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)!)
            }
            // The events macOS sends for ⌘⇧[ and ⌘⇧], as logged from real key presses.
            for (characters, ignoring, code) in [("[", "{", UInt16(33)), ("]", "}", 30)] {
                try expect(press(characters, ignoring, [.command, .shift], code), "No menu item took ⌘⇧\(characters) (ignoring \(ignoring))")
            }
        }
        test("Quick open matches names fuzzily, ranking word starts and prefixes first") {
            let names = ["Planning notes.md", "api-strategy-session.md", "Plan.md", "explain.md"]
            let items = names.map { QuickOpenItem(name: $0, detail: "notes", target: .file(URL(fileURLWithPath: "/notes/" + $0))) }
            try expect(QuickOpenRanking.rank(items, query: "").map(\.name) == names, "An empty query reordered the files")
            try expect(QuickOpenRanking.rank(items, query: "plan").map(\.name) == ["Plan.md", "Planning notes.md", "explain.md"], "Prefix matches not first: \(QuickOpenRanking.rank(items, query: "plan").map(\.name))")
            try expect(QuickOpenRanking.rank(items, query: "ass").first?.name == "api-strategy-session.md", "Word starts not preferred")
            try expect(QuickOpenRanking.rank(items, query: "notes/plan").first?.name == "Plan.md" || QuickOpenRanking.rank(items, query: "notes/plan").first?.name == "Planning notes.md", "Folder not searched")
            try expect(QuickOpenRanking.rank(items, query: "zzz").isEmpty, "A non-matching query matched")
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
            defer { settingsDefaults.removePersistentDomain(forName: settingsSuite); delegate.applySettings() }
            settings.appearance = .dark; settings.appIcon = .ruled
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            themed.applySettings()
            try expect(application?.appearance?.name == .darkAqua, "App appearance is not dark")
            // AppKit re-renders the Dock icon, so compare drawn pixels with a tolerance.
            func pixels(_ image: NSImage?) -> [UInt8] {
                guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap), let data = bitmap.bitmapData else { return [] }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
                NSGraphicsContext.restoreGraphicsState()
                return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * 32))
            }
            func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
                a.count == b.count && !a.isEmpty ? zip(a, b).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(a.count) : .infinity
            }
            let ruled = pixels(AppIconChoice.ruled.image)
            let dock = pixels(application?.applicationIconImage)
            let nearest = AppIconChoice.allCases.min { distance(dock, pixels($0.image)) < distance(dock, pixels($1.image)) }
            try expect(nearest == .ruled, "Dock icon is not the chosen icon (closest: \(nearest?.rawValue ?? "none"))")
            let chosenDistance = distance(dock, ruled)
            try expect(chosenDistance < 2, "Dock icon differs from the chosen icon by \(chosenDistance)")
            settings.appIcon = .night; themed.applySettings()
            try expect(distance(pixels(application?.applicationIconImage), ruled) > 10 * max(chosenDistance, 0.5), "Choosing Night did not restore the bundle icon")
            guard let editor = doc.editor else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.canSynchronize && !editor.webView.isHidden }
            var bodyTheme: String?
            func poll() { editor.webView.evaluateJavaScript("document.body.dataset.theme") { result, _ in bodyTheme = result as? String } }
            try waitUntil { poll(); return bodyTheme == "dark" }
            settings.appearance = .light; themed.applySettings()
            try waitUntil { poll(); return bodyTheme == "light" }
        }
        test("Closing a document before its editor loads ignores the editor's late messages") {
            // Holding the editors keeps their web views alive to deliver those messages.
            var closed: [DocumentEditor] = []
            for _ in 0..<5 {
                let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
                doc.recoveryStore = recoveryStore
                controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
                if let editor = doc.editor { closed.append(editor) }
                // Let the editor start loading before its document goes away.
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                doc.close()
            }
            // Their pages could still finish loading and post; closing detached them from the app.
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            try expect(closed.allSatisfy { $0.document == nil && $0.host == nil && !$0.ready }, "A closed document's editor is still connected")
        }
        test("Documents join the window after the current one, accept drops, reorder, and switch with ⌘⇧[ and ⌘⇧]") {
            let opened = { (url: URL) in controller.documents.first { $0.fileURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() } as? MarkdownDocument }
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            let b = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            for doc in [a, b] { doc.recoveryStore = recoveryStore; controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows() }
            defer { for doc in controller.documents { doc.close() } }
            guard let host = a.editor?.host, let window = host.window else { throw CocoaError(.fileReadUnknown) }
            try expect(b.editor?.host === host, "Documents did not share one window")
            func names() -> [String] { host.documents.map(\.editorName) }
            try expect(host.documents.map(\.recoveryID) == [a, b].map(\.recoveryID) && host.current === b, "New document was not added after the current one")
            try waitUntil { host.sidebar.openFileNames.count == 2 && host.sidebar.currentOpenFileName == b.editorName }

            host.select(a)
            delegate.open([first], in: host)
            try waitUntil { opened(first).map { doc in host.current === doc } == true }
            try expect(host.documents[1] === opened(first), "An opened file was not placed after the current document: \(names())")
            let count = controller.documents.count
            delegate.open([first], in: host)
            try waitUntil { !controller.isOpening }
            try expect(controller.documents.count == count && host.documents.count == 3, "Reopening an open file added it again")

            let image = root.appendingPathComponent("picture.png")
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("margin-drop-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents(); pasteboard.writeObjects([image as NSURL])
            try expect(EditorWebView.markdownFiles(on: pasteboard).isEmpty, "Image drops were taken from the editor")
            pasteboard.clearContents(); pasteboard.writeObjects([second as NSURL])
            guard let editor = host.currentEditor else { throw CocoaError(.fileReadUnknown) }
            let drop = FakeDrop(pasteboard: pasteboard, window: window)
            try expect(editor.webView.draggingEntered(drop) == .copy, "Markdown drop not accepted")
            try expect(editor.webView.prepareForDragOperation(drop) && editor.webView.performDragOperation(drop), "Markdown drop not performed")
            try waitUntil { opened(second).map { doc in host.current === doc } == true }
            try expect(names() == [a.editorName, first.lastPathComponent, second.lastPathComponent, b.editorName], "Unexpected order after the drop: \(names())")

            // ⌘⇧[ and ⌘⇧] step through the list and wrap.
            host.selectAdjacent(1); try expect(host.current === b, "Next file did not move down")
            host.selectAdjacent(1); try expect(host.current === a, "Next file did not wrap to the top")
            host.selectAdjacent(-1); try expect(host.current === b, "Previous file did not wrap to the bottom")

            // Dragging in Open Files reorders; the header is row 0, so open files start at child 1.
            let reorder = NSPasteboard(name: NSPasteboard.Name("margin-reorder-\(UUID().uuidString)"))
            defer { reorder.releaseGlobally() }
            reorder.clearContents(); reorder.setString(b.recoveryID.uuidString, forType: NSPasteboard.PasteboardType("com.infiniteviewtech.margin.open-file"))
            let move = FakeDrop(pasteboard: reorder, window: window)
            let files = host.sidebar.filesView
            try expect(host.sidebar.outlineView(files, validateDrop: move, proposedItem: nil, proposedChildIndex: 1) == .move, "Dragging an open file was refused")
            try expect(host.sidebar.outlineView(files, acceptDrop: move, item: nil, childIndex: 1), "Dropping an open file failed")
            try expect(names().first == b.editorName && host.sidebar.openFileNames == names(), "Dragging did not move the file to the top: \(names())")
            host.move(b, to: host.documents.count)
            try expect(names().last == b.editorName, "Moving to the end failed: \(names())")

            // Closing the current document selects its neighbor; closing the last closes the window.
            guard let firstDoc = opened(first) else { throw CocoaError(.fileReadUnknown) }
            host.select(firstDoc)
            let below = host.documents[host.documents.firstIndex { $0 === firstDoc }! + 1]
            host.sidebar.onCloseOpenFile(firstDoc.recoveryID.uuidString)
            try waitUntil { opened(first) == nil }
            try expect(host.current === below && host.documents.count == 3, "Closing the current document did not select the one below")
            for doc in host.documents { doc.close() }
            try expect(!window.isVisible && !delegate.windows.contains { $0 === host }, "Closing every document left the window open")
        }
        test("A window restores its documents in order, with the current one, the welcome's text, and its folder") {
            guard let welcomeText = MarkdownDocument.welcomeText() else { throw CocoaError(.fileReadNoSuchFile) }
            var fileDoc: MarkdownDocument?
            controller.openDocument(withContentsOf: first, display: true) { doc, _, _ in fileDoc = doc as? MarkdownDocument }
            try waitUntil { fileDoc != nil }
            let welcome = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            welcome.recoveryStore = recoveryStore; welcome.text = welcomeText; welcome.isWelcome = true
            let blank = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            blank.recoveryStore = recoveryStore
            for doc in [welcome, blank] { controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows() }
            guard let host = fileDoc?.editor?.host, let window = host.window else { throw CocoaError(.fileReadUnknown) }
            host.select(welcome)
            host.workspace = root
            let order = host.documents.map(\.editorName), ids = host.documents.map(\.recoveryID)
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            host.window(window, willEncodeRestorableState: archiver); archiver.finishEncoding()
            for doc in host.documents { doc.close() }
            try waitUntil { controller.documents.isEmpty }

            let restored = delegate.makeWindow()
            defer { for doc in controller.documents { doc.close() } }
            var done = false
            restored.restore(from: try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)) { done = true }
            try waitUntil { done }
            try expect(restored.documents.map(\.editorName) == order && restored.documents.map(\.recoveryID) == ids, "Restored \(restored.documents.map(\.editorName)), expected \(order)")
            try expect(restored.current?.isWelcome == true && restored.current?.text == welcomeText, "The welcome was not current, or came back blank")
            try expect(restored.documents.first?.fileURL?.resolvingSymlinksInPath() == first.resolvingSymlinksInPath(), "The file was not reopened")
            try expect(restored.workspace?.standardizedFileURL == root.standardizedFileURL, "The window's folder was not reopened")
            try waitUntil { restored.sidebar.visibleTreeRows.contains("A real file.md") }
        }
        test("The editor fills the window under the title bar, has the keyboard, and the drag strip covers the title bar") {
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            a.recoveryStore = recoveryStore; controller.addDocument(a); a.makeWindowControllers(); a.showWindows()
            defer { for doc in controller.documents { doc.close() } }
            guard let editor = a.editor, let window = editor.window else { throw CocoaError(.fileReadUnknown) }
            try expect(window.styleMask.contains(.fullSizeContentView) && window.titleVisibility == .hidden, "Editor window does not extend under a hidden title")
            try expect(window.firstResponder === editor.webView, "Typing goes to \(String(describing: window.firstResponder)), not the document")
            try waitUntil { editor.canSynchronize }
            let inset = Int(editor.view.safeAreaInsets.top)
            try expect(inset > 0, "No title bar inset")
            var state = ""
            try waitUntil { editor.webView.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--titlebar-inset').trim()") { result, _ in state = result as? String ?? "" }; return state == "\(inset)px" }
            try expect(Int(editor.titlebarDragView.frame.height) == inset, "Drag strip does not cover the title bar")
        }
        test("The sidebar runs the full window height and keeps its state while switching documents") {
            for key in ["sidebarCollapsed", "sidebarWidth"] { UserDefaults.standard.removeObject(forKey: key) }
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            let b = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            for doc in [a, b] { doc.recoveryStore = recoveryStore; controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows() }
            defer { for doc in controller.documents { doc.close() }; for key in ["sidebarCollapsed", "sidebarWidth"] { UserDefaults.standard.removeObject(forKey: key) } }
            guard let host = a.editor?.host, let window = host.window, let editorA = a.editor, let editorB = b.editor else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editorA.canSynchronize && editorB.canSynchronize }
            let sideFrame = host.sidebar.view.convert(host.sidebar.view.bounds, to: nil)
            try expect(sideFrame.maxY >= window.contentLayoutRect.maxY, "Sidebar starts below the title bar")
            try expect(Int(host.sidebarWidth) == Int(SidebarViewController.defaultWidth), "Unexpected sidebar width \(host.sidebarWidth)")
            var open = ""
            func pollOpen(_ editor: DocumentEditor) { editor.webView.evaluateJavaScript("String(document.body.classList.contains('sidebar-open'))") { result, _ in open = result as? String ?? "" } }
            try waitUntil { pollOpen(editorB); return open == "true" }
            host.toggleSidebar()
            try waitUntil { host.sidebarItem.isCollapsed }
            try waitUntil { pollOpen(editorB); return open == "false" }
            try waitUntil { pollOpen(editorA); return open == "false" }
            host.select(a)
            try expect(host.sidebarItem.isCollapsed, "Switching documents reopened the sidebar")
            host.showOutline()
            try waitUntil { !host.sidebarItem.isCollapsed && host.sidebar.state.mode == .outline }
            try waitUntil { Int(host.sidebarWidth) == Int(SidebarViewController.defaultWidth) }
            host.splitController.splitView.setPosition(300, ofDividerAt: 0)
            try waitUntil { Int(host.sidebar.state.width) == 300 }
            host.select(b)
            try expect(Int(host.sidebarWidth) == 300 && host.sidebar.state.mode == .outline, "Switching documents changed the sidebar")
            // A new window has a sidebar of its own, starting from the last width.
            delegate.newWindow(nil)
            guard let other = delegate.windows.last, other !== host, let newDoc = other.current else { throw CocoaError(.fileReadUnknown) }
            newDoc.recoveryStore = recoveryStore
            try expect(other.sidebar.state !== host.sidebar.state && other.sidebar.state.mode == .files && Int(other.sidebar.state.width) == 300, "The new window's sidebar is shared or did not start from the last width")
            try expect(host.documents.count == 2 && other.documents.count == 1, "New Window did not keep its own Open Files")
        }
        test("A new window starts without a folder, and each window keeps its own") {
            let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("margin-integration-elsewhere-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: elsewhere) }
            try "# Elsewhere\n".write(to: elsewhere.appendingPathComponent("Elsewhere.md"), atomically: true, encoding: .utf8)
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            a.recoveryStore = recoveryStore; controller.addDocument(a); a.makeWindowControllers(); a.showWindows()
            defer { for doc in controller.documents { doc.close() } }
            guard let host = a.editor?.host else { throw CocoaError(.fileReadUnknown) }
            host.workspace = root
            try waitUntil { host.sidebar.visibleTreeRows.contains("A real file.md") }
            delegate.newWindow(nil)
            guard let other = delegate.windows.last, other !== host, let newDoc = other.current else { throw CocoaError(.fileReadUnknown) }
            newDoc.recoveryStore = recoveryStore
            try expect(other.workspace == nil && other.workspaceTree == nil && !other.sidebar.visibleTreeRows.contains("A real file.md"), "The new window showed another window's folder: \(other.sidebar.visibleTreeRows)")
            other.workspace = elsewhere
            try waitUntil { other.sidebar.visibleTreeRows == ["Elsewhere.md"] }
            try expect(host.workspace == root && host.sidebar.visibleTreeRows.contains("A real file.md"), "Opening a folder in one window changed another's")
            try expect(delegate.quickOpenItems(for: other).contains { $0.name == "Elsewhere.md" } && !delegate.quickOpenItems(for: host).contains { $0.name == "Elsewhere.md" }, "Quick open listed another window's folder")
            var refreshed = false
            delegate.refreshFolders { refreshed = true }
            try waitUntil { refreshed }
            try expect(other.sidebar.visibleTreeRows == ["Elsewhere.md"] && host.sidebar.visibleTreeRows.contains("A real file.md"), "Refreshing mixed the windows' folders")
        }
        test("The sidebar lists, filters, and opens workspace files, and remembers folders opened across tabs") {
            let nested = root.appendingPathComponent("Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "# Deep\n".write(to: nested.appendingPathComponent("Deep note.md"), atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: nested) }
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            a.recoveryStore = recoveryStore; controller.addDocument(a); a.makeWindowControllers(); a.showWindows()
            defer { for doc in controller.documents { doc.close() } }
            guard let editor = a.editor, let host = editor.host else { throw CocoaError(.fileReadUnknown) }
            host.workspace = root
            try waitUntil { editor.canSynchronize }
            let sidebar = host.sidebar
            try waitUntil { sidebar.visibleTreeRows.contains("Nested/") }
            try expect(sidebar.visibleTreeRows == ["Nested/", "  Deep note.md", "A real file.md", "Another.markdown"], "Unexpected tree: \(sidebar.visibleTreeRows)")
            sidebar.state.filter = "deep"
            try expect(sidebar.visibleTreeRows == ["Nested/", "  Deep note.md"], "Filter incorrect: \(sidebar.visibleTreeRows)")
            sidebar.state.filter = "nothing like this"
            try expect(sidebar.visibleTreeRows == ["(No matching files.)"], "No-match message missing: \(sidebar.visibleTreeRows)")
            sidebar.state.filter = ""
            sidebar.activateFile(row: sidebar.rowIndex(named: "Nested")!)
            try expect(!sidebar.visibleTreeRows.contains("  Deep note.md") && sidebar.state.toggledFolders.contains { $0.hasSuffix("/Nested") }, "Collapsing a folder was not remembered")
            sidebar.activateFile(row: sidebar.rowIndex(named: "Another.markdown")!)
            try waitUntil { host.current?.fileURL?.resolvingSymlinksInPath() == second.resolvingSymlinksInPath() }
            try expect(!sidebar.visibleTreeRows.contains("  Deep note.md") && sidebar.openFileNames.count == 2 && sidebar.currentOpenFileName == "Another.markdown", "Opening a workspace file changed the tree or Open Files")

            // Refreshing picks up files added since the last scan.
            let added = root.appendingPathComponent("Added later.md")
            try "# Later\n".write(to: added, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: added) }
            delegate.refreshFolders()
            try waitUntil { sidebar.visibleTreeRows.contains("Added later.md") }
        }
        test("The outline lists the current document's headings, follows switching, and reveals one in the editor") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            doc.text = "# One\n\nText\n\n## Two\n\n```md\n# Not a heading\n```\n"
            let other = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            other.recoveryStore = recoveryStore; other.text = "# Elsewhere\n"
            for item in [doc, other] { controller.addDocument(item); item.makeWindowControllers(); item.showWindows() }
            defer { for item in controller.documents { item.close() } }
            guard let editor = doc.editor, let host = editor.host else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { host.sidebar.headings.map(\.text) == ["Elsewhere"] }
            host.select(doc)
            try waitUntil { host.sidebar.headings.map(\.text) == ["One", "Two"] }
            try expect(host.sidebar.headings.map(\.level) == [1, 2], "Heading levels wrong")
            host.sidebar.activateHeading(row: 1)
            var head = -1
            try waitUntil { editor.webView.evaluateJavaScript("app.view.state.selection.main.head") { result, _ in head = result as? Int ?? -1 }; return head == host.sidebar.headings[1].pos }
        }
        test("Quick open lists the window's documents and workspace files, opens a file into the window, and switches to an open one") {
            let a = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            a.recoveryStore = recoveryStore; controller.addDocument(a); a.makeWindowControllers(); a.showWindows()
            defer { for doc in controller.documents { doc.close() } }
            guard let host = a.editor?.host, let window = host.window else { throw CocoaError(.fileReadUnknown) }
            host.workspace = root
            var scanned = false
            host.refreshFolder { scanned = true }
            try waitUntil { scanned }
            let names = delegate.quickOpenItems(for: host).map(\.name)
            try expect(names.first == "Untitled.md" && names.contains("A real file.md") && names.contains("Another.markdown") && Set(names).count == names.count, "Unexpected candidates: \(names)")
            delegate.showQuickOpen(for: host)
            guard let picker = delegate.quickOpen else { throw CocoaError(.fileReadUnknown) }
            try expect(picker.panel.isVisible && picker.panel.parent === window, "Quick open did not appear over the window")
            picker.search("anoth")
            try expect(picker.results.first?.name == "Another.markdown", "Search did not find the file")
            picker.choose(row: 0)
            try expect(!picker.panel.isVisible && delegate.quickOpen == nil, "Quick open stayed open")
            try waitUntil { host.current?.fileURL?.resolvingSymlinksInPath() == second.resolvingSymlinksInPath() && host.documents.count == 2 }
            delegate.showQuickOpen(for: host)
            guard let again = delegate.quickOpen else { throw CocoaError(.fileReadUnknown) }
            again.search("untitled")
            again.choose(row: 0)
            try waitUntil { host.current === a }
        }
        test("The sidebar creates a file in a folder, opens it, and renames files in place") {
            let folder = root.appendingPathComponent("Rename tests", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let plain = folder.appendingPathComponent("plain.md"), taken = folder.appendingPathComponent("taken.md"), open = folder.appendingPathComponent("open.md")
            for url in [plain, taken, open] { try "# \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8) }
            let holder = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            holder.recoveryStore = recoveryStore; controller.addDocument(holder); holder.makeWindowControllers(); holder.showWindows()
            defer { for doc in controller.documents { doc.close() } }
            guard let host = holder.editor?.host else { throw CocoaError(.fileReadUnknown) }
            host.workspace = root
            var scanned = false
            host.refreshFolder { scanned = true }
            try waitUntil { scanned }
            @MainActor func rename(_ url: URL, _ name: String) throws -> Error? {
                var result: Error??
                delegate.renameWorkspaceFile(url, to: name, in: host) { result = .some($0) }
                try waitUntil { result != nil }
                return result!
            }
            try expect(try rename(plain, "Renamed") == nil && FileManager.default.fileExists(atPath: folder.appendingPathComponent("Renamed.md").path) && !FileManager.default.fileExists(atPath: plain.path), "Renaming a closed file failed")
            try expect(try rename(taken, "Renamed.md") != nil && FileManager.default.fileExists(atPath: taken.path), "A rename replaced an existing file")
            for bad in ["", "a/b", ".hidden"] { try expect(try rename(taken, bad) != nil, "Accepted the name “\(bad)”") }
            try expect(try rename(taken, "Taken") == nil && (try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains("Taken.md"), "A change of letter case failed")

            var opened: MarkdownDocument?
            controller.openDocument(withContentsOf: open, display: true) { document, _, _ in opened = document as? MarkdownDocument }
            try waitUntil { opened?.editor?.canSynchronize == true }
            guard let doc = opened, let editor = doc.editor, let window = editor.window else { throw CocoaError(.fileReadUnknown) }
            try expect(editor.host === host, "The opened file did not join the window with the folder")
            doc.edited("# Unsaved edits\n")
            try waitUntil { doc.isDocumentEdited }
            let moved = folder.appendingPathComponent("moved.md")
            try expect(try rename(open, "moved") == nil, "Renaming an open file failed")
            try expect(doc.fileURL?.standardizedFileURL == moved.standardizedFileURL && doc.isDocumentEdited && doc.text == "# Unsaved edits\n", "The open document did not follow its file or lost its edits")
            var name = ""
            try waitUntil { editor.webView.evaluateJavaScript("document.querySelector('#document-name').textContent") { result, _ in name = result as? String ?? "" }; return name == "moved.md" }

            // The sidebar names files by the paths in the scanned tree.
            guard let treeFolder = host.workspaceTree?.children?.first(where: { $0.name == "Rename tests" })?.path else { throw CocoaError(.fileReadUnknown) }
            let treeMoved = treeFolder + "/moved.md"
            guard let sidebar = editor.host?.sidebar else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { sidebar.visibleTreeRows.contains { $0.hasSuffix("moved.md") } }
            sidebar.beginRename(path: treeMoved)
            try expect(sidebar.renamingPath == treeMoved && window.firstResponder is NSTextView, "Rename did not start editing the row")
            sidebar.finishRename(path: treeMoved, name: "ignored", cancelled: true)
            try expect(doc.fileURL?.lastPathComponent == "moved.md" && sidebar.renamingPath == nil, "Cancelling a rename renamed the file")

            let before = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            sidebar.onNewFile(treeFolder)
            let created = URL(fileURLWithPath: treeFolder + "/Untitled.md")
            try waitUntil { FileManager.default.fileExists(atPath: created.path) }
            try waitUntil { (controller.documents.first { $0.fileURL?.standardizedFileURL == created.standardizedFileURL } as? MarkdownDocument)?.editor?.host?.sidebar.renamingPath == created.path }
            try expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)).subtracting(before) == ["Untitled.md"], "New File did not create one Untitled.md")
            guard let newEditor = (controller.documents.first { $0.fileURL?.standardizedFileURL == created.standardizedFileURL } as? MarkdownDocument)?.editor, let newHost = newEditor.host else { throw CocoaError(.fileReadUnknown) }
            try expect(newHost === editor.host && newHost.current === newEditor.document, "The new file did not open in the window")
            newHost.sidebar.finishRename(path: created.path, name: "Fresh note")
            try waitUntil { FileManager.default.fileExists(atPath: folder.appendingPathComponent("Fresh note.md").path) && newEditor.doc.fileURL?.lastPathComponent == "Fresh note.md" }
        }
        test("Right-clicking the document adds Insert and formatting commands after Paste") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            guard let editor = doc.editor, let window = editor.window else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.canSynchronize }
            func webKitMenu() -> NSMenu {
                let menu = NSMenu()
                for id in ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste", "Services"] {
                    let item = NSMenuItem(title: id, action: nil, keyEquivalent: ""); item.identifier = NSUserInterfaceItemIdentifier(id); menu.addItem(item)
                }
                return menu
            }
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let field = webKitMenu()
            editor.webView.willOpenMenu(field, with: event)
            try expect(field.items.count == 4, "A right-click outside the document got document commands")
            let menu = webKitMenu()
            editor.webView.documentMenuRequested = true
            editor.webView.willOpenMenu(menu, with: event)
            let titles = menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
            try expect(Array(titles.prefix(4)) == ["WKMenuItemIdentifierCut", "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste", "-"] && titles.contains("Insert Table") && titles.last == "Services", "Commands not placed after Paste: \(titles)")
            try expect(menu.items.first { $0.title == "Paragraph" }?.submenu?.items.contains { $0.title == "Heading 2" } == true, "Paragraph submenu missing")
            editor.webView.willOpenMenu(webKitMenu(), with: event)
            try expect(!editor.webView.documentMenuRequested, "The request carried over to the next menu")
            guard let table = menu.items.first(where: { $0.title == "Insert Table" }) else { throw CocoaError(.fileReadUnknown) }
            editor.formatFromMenu(table)
            var text = ""
            try waitUntil { editor.webView.evaluateJavaScript("app.getMarkdown()") { result, _ in text = result as? String ?? "" }; return text.contains("| Column | Column | Column |") }
        }
        test("Typing in the page marks the document unsaved") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            guard let editor = doc.editor else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.canSynchronize }
            var finished = false
            editor.webView.evaluateJavaScript("app.view.dispatch({ changes: { from: 0, insert: '# Typed\\n' }, userEvent: 'input.type' }); 1") { _, _ in finished = true }
            try waitUntil { finished && doc.text == "# Typed\n" }
            try waitUntil { doc.isDocumentEdited }
        }
        test("Editor typing makes one document undo step and the undo key reverts it") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            doc.text = "# Start\n"
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            guard let editor = doc.editor else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.canSynchronize }
            var finished = false
            // execCommand goes through WebKit's own editing, which registers WebKit undo steps.
            editor.webView.evaluateJavaScript("app.view.contentDOM.focus(); app.view.dispatch({ selection: { anchor: 0 } }); document.execCommand('insertText', false, 'typed '); 1") { _, _ in finished = true }
            try waitUntil { finished && doc.text != "# Start\n" && doc.undoManager?.canUndo == true }
            finished = false
            var hidden = false
            let visibility = editor.webView.observe(\.isHidden) { view, _ in hidden = hidden || view.isHidden }
            defer { visibility.invalidate() }
            editor.webView.evaluateJavaScript("app.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true, cancelable: true })); 1") { _, _ in finished = true }
            try waitUntil { finished && doc.text == "# Start\n" }
            try expect(!hidden, "Undo hid the editor while it reloaded the text")
            try expect(doc.undoManager?.canUndo == false, "WebKit editing steps reached the document's undo stack")
            try expect(!doc.isDocumentEdited, "Undoing the only edit left the document edited")
        }
        test("Files opened together join the window in the order they were requested") {
            let names = (1...5).map { "Order \($0).md" }
            let urls = names.map { root.appendingPathComponent($0) }
            for url in urls { try "# \(url.lastPathComponent)\n".write(to: url, atomically: true, encoding: .utf8) }
            for round in 1...3 {
                for url in urls { controller.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
                try waitUntil { urls.allSatisfy { url in controller.documents.contains { $0.fileURL == url } } }
                let order = (controller.documents.compactMap { ($0 as? MarkdownDocument)?.editor?.host }.first?.documents ?? []).map(\.editorName)
                for doc in controller.documents { doc.close() }
                try expect(order == names, "Round \(round): files opened as \(order)")
            }
        }
        test("The editor window remembers its frame for the next window") {
            NSWindow.removeFrame(usingName: "MarginEditor")
            defer { NSWindow.removeFrame(usingName: "MarginEditor") }
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            guard let window = doc.editor?.window else { throw CocoaError(.fileReadUnknown) }
            try expect(window.frameAutosaveName == "MarginEditor", "Editor window has no frame autosave name")
            let frame = NSRect(x: 120, y: 140, width: 910, height: 640)
            window.setFrame(frame, display: false)
            doc.close()
            let next = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            next.recoveryStore = recoveryStore
            controller.addDocument(next); next.makeWindowControllers(); next.showWindows()
            defer { next.close() }
            try expect(next.editor?.window?.frame.size == frame.size, "Next window did not reuse the saved size")
        }
        test("Launch without a file shows a restorable editor window holding the document") {
            delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            delegate.applicationDidFinishRestoringWindows(restored)
            guard let doc = controller.documents.first as? MarkdownDocument else {
                throw NSError(domain: "Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Launch did not create a Markdown document"])
            }
            defer { doc.close() }
            guard let host = doc.editor?.host, let window = host.window else { throw CocoaError(.fileReadUnknown) }
            try expect(host.current === doc && window.isVisible, "Launch did not show the document in a window")
            try expect(doc.windowForSheet === window, "Sheets for the document would not appear over its window")
            try expect(window.isRestorable && window.restorationClass == EditorWindowRestoration.self, "The window does not restore its documents")
        }
        test("Editor process failure keeps native edits, exposes a save fallback, and retries from memory") {
            let doc = try controller.makeUntitledDocument(ofType: markdownType) as! MarkdownDocument
            doc.recoveryStore = recoveryStore
            controller.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
            defer { doc.close() }
            guard let editor = doc.editor else { throw CocoaError(.fileReadUnknown) }
            try waitUntil { editor.session.isLoaded }
            let unsaved = "# Protected after editor failure\n\nNot saved to the original file.\n"
            doc.edited(unsaved); editor.loadDocument()
            try waitUntil { editor.session.isLoaded }
            editor.webViewWebContentProcessDidTerminate(editor.webView)
            try expect(editor.hasEditorFailure && doc.text == unsaved && doc.isDocumentEdited, "Process failure cleared native edits")
            try expect(editor.isShowingFailure && editor.webView.isHidden, "No native error fallback was shown")
            try expect(try recoveryStore.readAll().drafts.contains(where: { $0.id == doc.recoveryID && $0.text == unsaved }), "Failure did not checkpoint current edits")
            editor.perform(NSSelectorFromString("retryEditor:"), with: nil)
            try waitUntil { editor.session.isLoaded && !editor.hasEditorFailure }
            try expect(!editor.isShowingFailure && !editor.webView.isHidden, "Retry left the error fallback in place of the editor")
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
            try expect(opened?.editor?.host?.current === opened, "File open did not add the document to a window")
            try expect(opened?.editor?.window?.isVisible == true, "File open did not show a window")
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
            doc.edited("# Changed after saving\n")
            try waitUntil { doc.isDocumentEdited }
            doc.undoManager?.disableUndoRegistration()
            doc.edited("# Saved with undo registration off\n")
            doc.undoManager?.enableUndoRegistration()
            try save(.saveOperation)
            try expect(try String(contentsOf: destination, encoding: .utf8) == doc.text, "Save without an undo count did not complete")
            let reopened = try controller.makeDocument(withContentsOf: destination, ofType: markdownType) as! MarkdownDocument
            try expect(reopened.text == doc.text, "Saved edits were lost after reopen")
        }
        test("Another application's change reloads a clean file, and is offered beside unsaved edits") {
            let url = root.appendingPathComponent("Watched.md")
            try "# Watched\n".write(to: url, atomically: true, encoding: .utf8)
            var opened: MarkdownDocument?
            var finished = false
            controller.openDocument(withContentsOf: url, display: true) { doc, _, _ in opened = doc as? MarkdownDocument; finished = true }
            try waitUntil { finished }
            guard let doc = opened, let editor = doc.editor else { throw CocoaError(.fileReadUnknown) }
            doc.recoveryStore = recoveryStore
            defer { doc.close() }
            try waitUntil { editor.canSynchronize && !editor.webView.isHidden }
            var result: Any?
            func poll(_ script: String) -> Bool {
                editor.webView.evaluateJavaScript(script) { value, _ in result = value }
                return result as? Bool == true
            }
            @MainActor func run(_ script: String) throws {
                var ran = false
                editor.webView.evaluateJavaScript(script + "; true") { _, _ in ran = true }
                try waitUntil { ran }
                result = nil
            }
            try "# Changed elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
            try waitUntil { doc.text == "# Changed elsewhere\n" }
            try waitUntil { poll("app.getMarkdown() === '# Changed elsewhere\\n' && document.querySelector('#toast').textContent === 'Reloaded from disk' && document.querySelector('#disk-banner').hidden") }
            try run("app.view.dispatch({ changes: { from: app.view.state.doc.length, insert: 'My edit\\n' } })")
            try waitUntil { doc.isDocumentEdited }
            try "# Changed elsewhere\nTheir edit\n".write(to: url, atomically: true, encoding: .utf8)
            try waitUntil { doc.diskConflict?.text == "# Changed elsewhere\nTheir edit\n" }
            result = nil
            try waitUntil { poll("!document.querySelector('#disk-banner').hidden && app.getMarkdown() === '# Changed elsewhere\\nMy edit\\n'") }
            try run("document.querySelector('#disk-compare').click()")
            try waitUntil { poll("app.isComparing() && document.querySelectorAll('.cm-deletedChunk').length === 1") }
            try run("document.querySelector('#compare-keep-mine').click()")
            try waitUntil { !doc.isDocumentEdited && doc.diskConflict == nil }
            try expect(try String(contentsOf: url, encoding: .utf8) == "# Changed elsewhere\nMy edit\n", "Keep mine for all did not save the edits")
            try waitUntil { poll("document.querySelector('#modified-dot').hidden && document.querySelector('#disk-banner').hidden") }
            try run("app.view.dispatch({ changes: { from: 0, insert: 'Discard me\\n' } })")
            try waitUntil { doc.isDocumentEdited }
            try "# From disk\n".write(to: url, atomically: true, encoding: .utf8)
            try waitUntil { doc.diskConflict != nil }
            var hidden = false
            let visibility = editor.webView.observe(\.isHidden) { view, _ in hidden = hidden || view.isHidden }
            defer { visibility.invalidate() }
            doc.reloadFromDisk()
            try expect(!hidden, "Reloading from disk hid the editor")
            result = nil
            try waitUntil { poll("app.getMarkdown() === '# From disk\\n' && document.querySelector('#modified-dot').hidden && document.querySelector('#disk-banner').hidden") }
        }
        } else {
            print("SKIP Full AppKit Open/Save and visible-menu checks require a desktop session: ./scripts/test-native.sh --ui")
        }
        test("Opens requested together reach AppKit one at a time, in request order") {
            controller.useNativeOpening = false
            controller.deferOpening = true
            controller.requests.removeAll()
            defer {
                controller.pendingCompletions.removeAll()
                controller.useNativeOpening = true
                controller.deferOpening = false
            }
            var completed: [URL] = []
            for url in [first, second] { controller.openDocument(withContentsOf: url, display: true) { _, _, _ in completed.append(url) } }
            try expect(controller.requests.map(\.0) == [first] && controller.isOpening, "The second open started before the first finished")
            controller.pendingCompletions.removeFirst()(nil, false, nil)
            try expect(controller.requests.map(\.0) == [first, second] && completed == [first], "The next open did not start after the first finished")
            controller.pendingCompletions.removeFirst()(nil, false, nil)
            try expect(completed == [first, second] && !controller.isOpening, "Opens did not all finish in order")
        }
        if failures > 0 { exit(1) }
    }
}
