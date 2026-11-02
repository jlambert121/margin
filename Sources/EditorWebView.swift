import Cocoa
import OSLog
import UniformTypeIdentifiers
import WebKit

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

/// Markdown files dropped on the editor open as tabs; anything else, such as
/// images, still goes to WebKit for the editor's own drop handling.
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
        if paste != nil {
            menu.insertItem(.separator(), at: index); index += 1
        }
        for item in items {
            menu.insertItem(item, at: index); index += 1
        }
        if paste == nil, index < menu.items.count {
            menu.insertItem(.separator(), at: index)
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        documentMenuRequested = false
    }

    /// WebKit registers its own editing undo on the responder chain's undo
    /// manager, which is otherwise the document's. The document's undo works
    /// on whole Markdown snapshots, so WebKit's steps must stay out of it.
    private let editingUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 1
        return manager
    }()

    override var undoManager: UndoManager? {
        editingUndoManager
    }

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
        if handlingFileDrop {
            handlingFileDrop = false
        } else {
            super.draggingExited(sender)
        }
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
        if !handlingFileDrop {
            super.concludeDragOperation(sender)
        }
    }
}

/// The editor's column, which reports when the title bar and tab bar over its
/// top change height: the tab bar appearing or hiding, or full screen.
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
