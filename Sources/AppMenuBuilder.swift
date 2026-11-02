import Cocoa

enum AppMenuBuilder {
    static func makeMenu(owner: AppDelegate) -> NSMenu {
        let bar = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); let menu = NSMenu(title: title); item.submenu = menu; bar.addItem(item); return menu
        }
        func item(_ menu: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
        }
        func command(_ menu: NSMenu, _ title: String, _ action: String, _ key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) {
            let entry = NSMenuItem(title: title, action: #selector(AppDelegate.webCommand(_:)), keyEquivalent: key); entry.keyEquivalentModifierMask = modifiers; entry.target = owner; entry.representedObject = action; menu.addItem(entry)
        }
        let app = menu("Margin")
        item(app, "About Margin", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        item(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: owner)
        item(app, "Make Margin the Default Markdown Editor…", #selector(AppDelegate.makeDefaultMarkdownEditor(_:)), target: owner)
        app.addItem(.separator())
        item(app, "Hide Margin", #selector(NSApplication.hide(_:)), "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator()); item(app, "Quit Margin", #selector(NSApplication.terminate(_:)), "q")
        let file = menu("File")
        item(file, "New", #selector(AppDelegate.newDocument(_:)), "n", target: owner)
        item(file, "New Window", #selector(AppDelegate.newWindow(_:)), "n", modifiers: [.command, .shift], target: owner)
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: owner.controller)
        item(file, "Open Folder…", #selector(AppDelegate.openFolder(_:)), "o", modifiers: [.command, .shift], target: owner)
        item(file, "Quick Open…", #selector(AppDelegate.showQuickOpen(_:)), "p", modifiers: [.command, .option], target: owner)
        let recent = NSMenu(title: "Open Recent"); let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem)
        recent.delegate = owner
        file.addItem(.separator()); item(file, "Close", #selector(EditorWindowController.closeDocument(_:)), "w")
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift])
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        item(file, "Revert to Saved…", #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator()); item(file, "Export HTML…", #selector(AppDelegate.exportHTML(_:)), target: owner)
        item(file, "Print / Save as PDF…", #selector(EditorWindowController.printDocument(_:)), "p")
        let edit = menu("Edit")
        item(edit, "Undo", #selector(EditorWindowController.undoDocument(_:)), "z")
        item(edit, "Redo", #selector(EditorWindowController.redoDocument(_:)), "z", modifiers: [.command, .shift])
        edit.addItem(.separator()); item(edit, "Cut", #selector(NSText.cut(_:)), "x"); item(edit, "Copy", #selector(NSText.copy(_:)), "c"); item(edit, "Paste", #selector(NSText.paste(_:)), "v"); item(edit, "Paste and Match Style", #selector(AppDelegate.pasteAndMatchStyle(_:)), "v", modifiers: [.command, .option, .shift], target: owner); item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator()); command(edit, "Find…", "find", "f"); command(edit, "Find and Replace…", "replace", "f", modifiers: [.command, .option]); command(edit, "Go to Line…", "goToLine", "l")
        let paragraph = menu("Paragraph")
        command(paragraph, "Body", "format:paragraph", "0", modifiers: [.command, .option])
        for level in 1 ... 6 {
            command(paragraph, "Heading \(level)", "format:h\(level)", "\(level)")
        }
        paragraph.addItem(.separator()); command(paragraph, "Bullet List", "format:bulletList"); command(paragraph, "Numbered List", "format:orderedList"); command(paragraph, "Task List", "format:taskList"); command(paragraph, "Quote", "format:blockquote"); command(paragraph, "Code Block", "format:codeBlock"); command(paragraph, "Table", "format:table")
        let format = menu("Format")
        command(format, "Bold", "format:bold", "b"); command(format, "Italic", "format:italic", "i"); command(format, "Strikethrough", "format:strike"); command(format, "Inline Code", "format:code"); format.addItem(.separator()); command(format, "Link…", "format:link", "k"); command(format, "Image…", "format:image")
        let view = menu("View")
        item(view, "Toggle Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "l", modifiers: [.command, .shift], target: owner); item(view, "Document Outline", #selector(AppDelegate.showOutline(_:)), target: owner); command(view, "Source Mode", "source", "/"); view.addItem(.separator())
        item(view, "Actual Size", #selector(AppDelegate.actualSize(_:)), "0", target: owner); item(view, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "+", target: owner); item(view, "Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-", target: owner)
        // ⌘= also zooms in, as in browsers, without a second visible item.
        item(view, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "=", target: owner); view.items.last?.isHidden = true; view.items.last?.allowsKeyEquivalentWhenHidden = true
        view.addItem(.separator()); command(view, "Typewriter Mode", "typewriter"); view.addItem(.separator()); item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        // ⌘⇧[ and ⌘⇧] switch files, as they switch tabs elsewhere in macOS. AppKit matches
        // the Shift-[ key as "{".
        let window = menu("Window"); item(window, "Previous File", #selector(AppDelegate.previousFile(_:)), "{", target: owner); item(window, "Next File", #selector(AppDelegate.nextFile(_:)), "}", target: owner)
        window.addItem(.separator()); item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"); item(window, "Zoom", #selector(NSWindow.performZoom(_:))); window.addItem(.separator()); item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))); NSApp?.windowsMenu = window
        return bar
    }
}
