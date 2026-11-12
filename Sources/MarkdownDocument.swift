import Cocoa
import OSLog
import UniformTypeIdentifiers
import WebKit

let markdownType = "net.daringfireball.markdown"
let plainTextType = "public.plain-text"

extension Notification.Name {
    /// Posted when a document's name, path, or unsaved state, or a window's tabs, change.
    static let openFilesChanged = Notification.Name("Margin.openFilesChanged")
}

/// A version of the file that another application wrote while the document had unsaved edits.
struct DiskVersion: Equatable {
    let text: String
    let date: Date
}

/// Info.plist uses this Objective-C name. An unqualified Swift class name does
/// not resolve through NSClassFromString, so AppKit otherwise disables Open.
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
    var editorName: String {
        fileURL?.lastPathComponent ?? recoveredName ?? "Untitled.md"
    }

    var isEmptyPlaceholder: Bool {
        fileURL == nil && recoveredName == nil && recoveredOriginalURL == nil && !isDocumentEdited && !uncountedEdit && (text.isEmpty || isWelcome)
    }

    override class var autosavesInPlace: Bool {
        true
    }

    override var fileURL: URL? {
        didSet { NotificationCenter.default.post(name: .openFilesChanged, object: self) }
    }

    /// Every edit updates the change count; the open files only show whether it is unsaved.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        let wasEdited = isDocumentEdited
        super.updateChangeCount(change)
        if change == .changeDone, uncountedEdit {
            uncountedEdit = false; runSavesWaitingForEdit()
        }
        if isDocumentEdited != wasEdited {
            NotificationCenter.default.post(name: .openFilesChanged, object: self)
        }
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        let wasEdited = isDocumentEdited
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        if isDocumentEdited != wasEdited {
            NotificationCenter.default.post(name: .openFilesChanged, object: self)
        }
    }

    /// Documents have no window controllers of their own: a window holds several and
    /// shows one at a time. AppKit asks for windows when it opens or creates a document,
    /// which then joins the frontmost window.
    override func makeWindowControllers() {
        guard editor?.host == nil else { return }
        (NSDocumentController.shared as? DocumentController)?.app?.windowForNewDocuments().add(self)
    }

    func makeEditor() -> DocumentEditor {
        if let editor {
            return editor
        }
        let editor = DocumentEditor(document: self)
        self.editor = editor
        return editor
    }

    override func showWindows() {
        if editor?.host == nil {
            makeWindowControllers()
        }
        editor?.host?.select(self)
        editor?.host?.showWindow(nil)
    }

    override var windowForSheet: NSWindow? {
        editor?.host?.window ?? super.windowForSheet
    }

    /// Save prompts appear over the document they ask about.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        editor?.host?.select(self)
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }

    override func data(ofType _: String) throws -> Data {
        Data(text.utf8)
    }

    /// Markdown is a flat UTF-8 file; avoid NSFileWrapper's dependency on
    /// LaunchServices file-kind lookups when reading and writing its bytes.
    override func read(from url: URL, ofType typeName: String) throws {
        try read(from: Data(contentsOf: url), ofType: typeName)
    }

    override func write(to url: URL, ofType typeName: String) throws {
        try data(ofType: typeName).write(to: url, options: .atomic)
    }

    override func read(from data: Data, ofType _: String) throws {
        text = try Self.decode(data)
        if !reverting {
            editor?.loadDocument()
        }
    }

    static func decode(_ data: Data) throws -> String {
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadInapplicableStringEncodingError,
                          userInfo: [NSLocalizedDescriptionKey: "This file is not UTF-8 text. Convert it to UTF-8 before opening it."])
        }
        return decoded
    }

    /// NSDocument clears the edited state only after reading, so the editor
    /// loads the reverted text once that state is final.
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
        if saveOperation != .saveToOperation, saveOperation != .autosaveElsewhereOperation {
            if text == savedText {
                clearRecovery()
            } else {
                flushRecovery()
            }
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
        if manager == nil {
            updateChangeCount(.changeDone)
        } else {
            uncountedEdit = true
        }
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
            if let error {
                self.reportRecoveryError(error)
            } else {
                self.recoveryErrorReported = false
            }
        }
    }

    private func reportRecoveryError(_ error: Error) {
        guard !recoveryErrorReported else { return }
        recoveryErrorReported = true
        let failure = NSError(domain: "Margin.Recovery", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The recovery copy could not be updated.",
            NSLocalizedRecoverySuggestionErrorKey: "Your edits are still in memory. Save the document to protect them before quitting.",
            NSUnderlyingErrorKey: error,
        ])
        if let onRecoveryError {
            onRecoveryError(failure)
        } else {
            presentError(failure)
        }
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

    /// A periodic autosave would raise AppKit's conflict alert over the editor's
    /// own choice. Closing and quitting still autosave and ask through AppKit.
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool, completionHandler: @escaping (Error?) -> Void) {
        if autosavingIsImplicitlyCancellable, diskConflict != nil {
            completionHandler(CocoaError(.userCancelled)); return
        }
        // An untitled document's first autosave gives it the copy its window reopens it from.
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable) { [weak self] error in
            self?.editor?.host?.window?.invalidateRestorableState()
            completionHandler(error)
        }
    }

    /// NSDocument hears when another application changes the file, but only
    /// refuses the next save. A clean document reloads; an edited one keeps its
    /// text while the editor offers the version on disk.
    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.scheduleDiskCheck() }
    }

    /// Formatters and checkouts can write a file several times in a row.
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
                if synchronized {
                    self.applyDiskChange()
                }
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
                NSUnderlyingErrorKey: error,
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
        if let coordinationError {
            throw coordinationError
        }
        return try Self.decode(result.get())
    }

    private func reportDiskError(_ error: Error) {
        if let onDiskError {
            onDiskError(error)
        } else if let window = windowForSheet {
            presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            presentError(error)
        }
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
                if response == .alertFirstButtonReturn {
                    self.reloadFromDisk()
                }
                activityCompletion()
            }
        }
    }

    /// Saving over the disk version is the choice the user just made, so
    /// AppKit's check for a newer file must not ask again. A newer change still does.
    func keepMine() {
        guard diskConflict != nil else { return }
        let save = { [weak self] in
            guard let self, let conflict = self.diskConflict else { return }
            self.fileModificationDate = conflict.date
            self.save(withDelegate: self, didSave: #selector(self.document(_:didKeepMine:contextInfo:)), contextInfo: nil)
        }
        guard let editor, editor.canSynchronize else { save(); return }
        editor.synchronize { [weak self] synchronized in
            if synchronized {
                save()
            } else {
                self?.resendDiskConflict()
            }
        }
    }

    @objc private func document(_: NSDocument, didKeepMine didSave: Bool, contextInfo _: UnsafeMutableRawPointer?) {
        if !didSave {
            resendDiskConflict()
        }
    }

    private func resendDiskConflict() {
        if let diskConflict {
            editor?.send("diskChanged", diskConflict.text)
        }
    }

    private func clearDiskConflict() {
        guard diskConflict != nil else { return }
        diskConflict = nil
        editor?.send("diskChanged", nil)
    }

    /// NSDocument counts an undo-registered edit with updateChangeCount(.changeDone)
    /// when the edit's undo group closes, possibly later still while it checks
    /// autosaving safety. A save that starts before then takes its change-count
    /// token too early and the late count re-dirties the saved document, so a
    /// save waits until that count has been reported here.
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
        if !saves.isEmpty {
            DispatchQueue.main.async { saves.forEach { $0() } }
        }
    }

    override func save(_ sender: Any?) {
        synchronizeBeforeSaving { [weak self] in self?.saveSynchronized(sender) }
    }

    private func saveSynchronized(_ sender: Any?) {
        super.save(sender)
    }

    override func saveAs(_ sender: Any?) {
        synchronizeBeforeSaving { [weak self] in self?.saveAsSynchronized(sender) }
    }

    private func saveAsSynchronized(_ sender: Any?) {
        super.saveAs(sender)
    }

    private func synchronizeBeforeSaving(_ action: @escaping () -> Void) {
        guard let editor, editor.canSynchronize else { action(); return }
        editor.synchronize {
            success in if success {
                action()
            }
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        savePanel.allowsOtherFileTypes = true
        if fileURL == nil {
            savePanel.nameFieldStringValue = editorName
        }
        return true
    }
}

// Local image requests are confined to the document's folder. Markdown never
// receives unrestricted file:// access or the ability to run native commands.
