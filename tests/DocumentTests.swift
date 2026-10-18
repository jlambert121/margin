import Cocoa
import WebKit
import UniformTypeIdentifiers

@main struct DocumentTests {
    static func main() throws {
        var failures = 0
        func test(_ name: String, _ block: () throws -> Void) {
            do { try block(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryStore = RecoveryStore(directory: root.appendingPathComponent("Recovery"))
        test("UTF-8 document loading preserves bytes, whitespace, and Unicode") {
            let text = "---\ntitle: Test\n---\n\n# Héllo 👋\r\n\n  spaces  \n"
            let doc = MarkdownDocument()
            try doc.read(from: Data(text.utf8), ofType: markdownType)
            try expect(doc.text == text, "Original content changed")
            try expect(try doc.data(ofType: markdownType) == Data(text.utf8), "Round trip changed bytes")
        }
        test("Invalid UTF-8 is rejected without replacing existing contents") {
            let doc = MarkdownDocument(); doc.text = "Keep this"
            var rejected = false
            do { try doc.read(from: Data([0xff, 0xfe, 0xff]), ofType: markdownType) } catch { rejected = true }
            try expect(rejected && doc.text == "Keep this", "Invalid encoding accepted")
        }
        test("File writing and reading round trip on disk") {
            let url = root.appendingPathComponent("Round trip.md")
            let doc = MarkdownDocument(); doc.text = "# Saved\n\n- [ ] A task\n"
            try doc.write(to: url, ofType: markdownType)
            let reopened = MarkdownDocument()
            try reopened.read(from: Data(contentsOf: url), ofType: markdownType)
            try expect(reopened.text == doc.text, "Saved content did not round trip")
        }
        test("Changes register native undo and redo") {
            let doc = MarkdownDocument(); doc.undoManager = UndoManager()
            doc.recoveryStore = recoveryStore
            defer { doc.close() }
            doc.undoManager?.beginUndoGrouping(); doc.edited("One"); doc.undoManager?.endUndoGrouping()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            try expect(doc.isDocumentEdited, "Editing did not mark document dirty")
            doc.undoManager?.undo(); try expect(doc.text.isEmpty, "Undo did not restore content")
            try expect(!doc.isDocumentEdited, "Undo back to the original content still reports unsaved changes")
            doc.undoManager?.redo(); try expect(doc.text == "One", "Redo did not restore change")
        }
        test("Recovery drafts survive reopening the store with exact UTF-8 text") {
            let draft = RecoveryDraft(id: UUID(), text: "# Héllo 👋\r\n\nUnsaved  \n", originalPath: "/notes/Original.md", name: "Original.md")
            try recoveryStore.write(draft)
            let reopened = RecoveryStore(directory: recoveryStore.directory)
            let result = try reopened.readAll()
            try expect(result.failures.isEmpty && result.drafts == [draft], "Recovery text or metadata changed on disk")
            try reopened.remove(draft.id)
        }
        test("Damaged recovery files are reported and retained while valid drafts remain readable") {
            let draft = RecoveryDraft(id: UUID(), text: "Keep these edits", originalPath: nil, name: "Untitled.md")
            try recoveryStore.write(draft)
            let corrupt = recoveryStore.directory.appendingPathComponent(UUID().uuidString + ".json")
            try Data("broken JSON".utf8).write(to: corrupt)
            let result = try recoveryStore.readAll()
            try expect(result.drafts == [draft] && result.failures.count == 1, "A damaged file prevented valid draft recovery")
            try expect(FileManager.default.fileExists(atPath: corrupt.path), "Damaged recovery was silently discarded")
            try recoveryStore.remove(draft.id); try FileManager.default.removeItem(at: corrupt)
        }
        test("Queued checkpoints cannot recreate a draft after save or discard removes it") {
            let draft = RecoveryDraft(id: UUID(), text: "An old checkpoint", originalPath: nil, name: "Untitled.md")
            recoveryStore.writeAsync(draft) { _ in }
            try recoveryStore.remove(draft.id)
            try expect(try recoveryStore.readAll().drafts.isEmpty, "A stale write recreated the removed recovery")
        }
        test("Recovery follows native undo and explicit close discards the recovery") {
            let doc = MarkdownDocument(); doc.recoveryStore = recoveryStore; doc.undoManager = UndoManager()
            doc.undoManager?.beginUndoGrouping(); doc.edited("Unsaved edit"); doc.undoManager?.endUndoGrouping()
            doc.flushRecovery()
            try expect(try recoveryStore.readAll().drafts.first?.text == "Unsaved edit", "Edit was not checkpointed")
            doc.undoManager?.undo(); doc.flushRecovery()
            try expect(try recoveryStore.readAll().drafts.isEmpty, "Undo back to the original content left a stale recovery")
            doc.undoManager?.redo()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            doc.flushRecovery()
            try expect(try recoveryStore.readAll().drafts.first?.text == "Unsaved edit", "Redo was not checkpointed")
            doc.close()
            try expect(try recoveryStore.readAll().drafts.isEmpty, "Closing left an unwanted recovery")
        }
        test("Recovery write failures are reported without clearing unsaved text") {
            let blocked = root.appendingPathComponent("Not a directory")
            try Data("Keep this file".utf8).write(to: blocked)
            let doc = MarkdownDocument(); doc.recoveryStore = RecoveryStore(directory: blocked)
            var reported: Error?
            doc.onRecoveryError = { reported = $0 }
            doc.edited("My unsaved work"); doc.flushRecovery()
            let limit = Date().addingTimeInterval(3)
            while reported == nil && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try expect(reported != nil, "Recovery failure was silent")
            try expect(doc.text == "My unsaved work" && doc.isDocumentEdited, "Recovery failure cleared the edits")
            try expect(try String(contentsOf: blocked, encoding: .utf8) == "Keep this file", "Recovery failure damaged an existing file")
        }
        test("Stale editor messages cannot overwrite a newer load") {
            var session = EditorSession()
            let first = session.beginLoad()
            try expect(!session.accepts(first), "Changes were accepted before the document loaded")
            session.acknowledge(first)
            try expect(session.accepts(first), "Loaded editor changes were rejected")
            let next = session.beginLoad()
            session.acknowledge(first)
            try expect(!session.isLoaded && !session.accepts(first), "An old load acknowledgement replaced current state")
            session.acknowledge(next)
            try expect(session.accepts(next) && !session.accepts(first), "A stale edit could overwrite the current document")
            try expect(session.acceptChange(token: next, revision: 2), "Latest snapshot was rejected")
            try expect(!session.acceptChange(token: next, revision: 1), "Delayed older text could overwrite the latest snapshot")
        }
        // Disk changes are written with a later date than NSDocument recorded, as another application's save would be.
        var nextDiskDate = Date().addingTimeInterval(5)
        func writeElsewhere(_ data: Data, to url: URL) throws {
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: nextDiskDate], ofItemAtPath: url.path)
            nextDiskDate.addTimeInterval(5)
        }
        func diskText(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func wait(_ message: String, until finished: () -> Bool) throws {
            let limit = Date().addingTimeInterval(5)
            while !finished() && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try expect(finished(), message)
        }
        func checkDisk(_ doc: MarkdownDocument) throws {
            var finished = false
            doc.checkDisk { finished = true }
            try wait("The disk check did not finish") { finished }
        }
        func openFile(_ name: String, _ text: String) throws -> (MarkdownDocument, URL) {
            let url = root.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            let doc = try MarkdownDocument(contentsOf: url, ofType: markdownType)
            doc.recoveryStore = recoveryStore
            return (doc, url)
        }
        func edit(_ doc: MarkdownDocument, _ text: String) throws {
            doc.undoManager?.beginUndoGrouping(); doc.edited(text); doc.undoManager?.endUndoGrouping()
            try wait("The edit did not mark the document edited") { doc.isDocumentEdited }
        }
        test("A clean document reloads when another application changes its file") {
            let (doc, url) = try openFile("Reload.md", "# Original\n")
            defer { doc.close() }
            try writeElsewhere(Data("# Changed elsewhere\n".utf8), to: url)
            try checkDisk(doc)
            try expect(doc.text == "# Changed elsewhere\n" && !doc.isDocumentEdited && doc.diskConflict == nil, "The clean document did not reload")
        }
        test("Unsaved edits stay when the file changes, periodic autosave waits, and Keep mine saves them") {
            let (doc, url) = try openFile("Keep mine.md", "# Original\n")
            defer { doc.close() }
            try edit(doc, "# My edits\n")
            try writeElsewhere(Data("# Theirs\n".utf8), to: url)
            try checkDisk(doc)
            try expect(doc.text == "# My edits\n" && doc.isDocumentEdited, "The disk version replaced unsaved edits")
            try expect(doc.diskConflict?.text == "# Theirs\n", "The disk version was not offered")
            try writeElsewhere(Data("# Theirs, again\n".utf8), to: url)
            try checkDisk(doc)
            try expect(doc.diskConflict?.text == "# Theirs, again\n", "A newer disk version did not replace the offered one")
            var autosaveError: Error?
            var autosaved = false
            doc.autosave(withImplicitCancellability: true) { autosaveError = $0; autosaved = true }
            try wait("Autosave did not finish") { autosaved }
            try expect((autosaveError as? CocoaError)?.code == .userCancelled && diskText(url) == "# Theirs, again\n", "Periodic autosave ran while the disk version was unresolved")
            doc.keepMine()
            try wait("Keep mine did not save") { !doc.isDocumentEdited }
            try expect(try diskText(url) == "# My edits\n" && doc.diskConflict == nil, "Keep mine did not write the edits over the disk version")
        }
        test("Reload replaces unsaved edits with the disk version") {
            let (doc, url) = try openFile("Discard.md", "# Original\n")
            defer { doc.close() }
            try edit(doc, "# Discard these\n")
            try writeElsewhere(Data("# Disk version\n".utf8), to: url)
            try checkDisk(doc)
            doc.reloadFromDisk()
            try expect(doc.text == "# Disk version\n" && !doc.isDocumentEdited && doc.diskConflict == nil, "Reload did not take the disk version")
            try expect(try recoveryStore.readAll().drafts.allSatisfy { $0.id != doc.recoveryID }, "Reload left a recovery copy of the discarded edits")
        }
        test("A disk version matching the edits, or unreadable, leaves the document alone") {
            let (doc, url) = try openFile("Same.md", "# Original\n")
            defer { doc.close() }
            var errors: [Error] = []
            doc.onDiskError = { errors.append($0) }
            try edit(doc, "# Same\n")
            try writeElsewhere(Data("# Same\n".utf8), to: url)
            try checkDisk(doc)
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try expect(doc.diskConflict == nil && doc.fileModificationDate == date, "A matching disk version was treated as a conflict")
            try writeElsewhere(Data([0xff, 0xfe, 0xff]), to: url)
            try checkDisk(doc)
            try checkDisk(doc)
            try expect(errors.count == 1 && doc.text == "# Same\n" && doc.diskConflict == nil, "An unreadable disk version was not reported once: \(errors.count)")
        }
        test("Local images load while traversal, symlinks, and non-images are rejected") {
            let images = root.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let bytes = Data([0x89, 0x50, 0x4e, 0x47])
            try bytes.write(to: images.appendingPathComponent("A picture.png"))
            try bytes.write(to: root.appendingPathComponent("outside.png"))
            try bytes.write(to: images.appendingPathComponent("private.txt"))
            try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("escape.png"), withDestinationURL: root.appendingPathComponent("outside.png"))
            let handler = AssetHandler(); handler.root = images
            let (data, mime) = try handler.readAsset(URL(string: "markdown-asset://local/A%20picture.png")!)
            try expect(data == bytes && mime == "image/png", "Relative image did not load")
            for path in ["../outside.png", "escape.png", "private.txt"] {
                var rejected = false
                do { _ = try handler.readAsset(URL(string: "markdown-asset://local/" + path)!) } catch { rejected = true }
                try expect(rejected, "Unsafe image path was accepted: \(path)")
            }
        }
        test("Folder navigation includes Markdown and skips hidden files and symlinks") {
            try "# Visible".write(to: root.appendingPathComponent("Visible.md"), atomically: true, encoding: .utf8)
            try "# Hidden".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
            try "Other".write(to: root.appendingPathComponent("ignore.csv"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.md"), withDestinationURL: root.appendingPathComponent("Visible.md"))
            let names = (AppDelegate.scanFolder(root).children ?? []).map(\.name)
            try expect(names.contains("Visible.md") && !names.contains(".hidden.md") && !names.contains("ignore.csv") && !names.contains("linked.md"), "Folder filtering failed")
        }
        if failures > 0 { exit(1) }
    }
}
