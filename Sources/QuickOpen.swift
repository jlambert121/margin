import Cocoa

struct QuickOpenItem {
    enum Target { case document(MarkdownDocument), file(URL) }
    let name: String
    // Where the file is: its folder in the workspace, or its folder path.
    let detail: String
    let target: Target
}

enum QuickOpenRanking {
    // The query's characters in order within the text, ignoring case. Matches that are
    // consecutive, start a word, or start the text score higher. Nil when it does not match.
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(query.lowercased()), text = Array(text.lowercased())
        guard !query.isEmpty else { return 0 }
        var score = 0, from = 0, previous = -2
        for character in query {
            guard let found = text[from...].firstIndex(of: character) else { return nil }
            if found == previous + 1 { score += 5 }
            if found == 0 || !(text[found - 1].isLetter || text[found - 1].isNumber) { score += 3 }
            score += 1
            previous = found; from = found + 1
        }
        if text.starts(with: query) { score += 10 }
        return score
    }
    // Names match first; the folder counts for less, and among equals the shorter name wins.
    // With no query the given order stays.
    static func rank(_ items: [QuickOpenItem], query: String) -> [QuickOpenItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, item -> (item: QuickOpenItem, score: Int, index: Int)? in
            if let score = score(query, in: item.name) { return (item, score * 2, index) }
            if let score = score(query, in: item.detail + "/" + item.name) { return (item, score, index) }
            return nil
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.name.count != $1.item.name.count { return $0.item.name.count < $1.item.name.count }
            return $0.index < $1.index
        }.map(\.item)
    }
}

final class QuickOpenPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// A search field over the current window that opens a file or switches to a tab.
final class QuickOpenController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let panel = QuickOpenPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.borderless], backing: .buffered, defer: true)
    let field = NSSearchField()
    let table = NSTableView()
    private let items: [QuickOpenItem]
    private(set) var results: [QuickOpenItem] = []
    private let onChoose: (QuickOpenItem) -> Void
    var onClose: () -> Void = {}

    init(items: [QuickOpenItem], onChoose: @escaping (QuickOpenItem) -> Void) {
        self.items = items; self.onChoose = onChoose
        super.init()
        let background = NSVisualEffectView()
        background.material = .popover; background.state = .active; background.blendingMode = .behindWindow
        background.wantsLayer = true; background.layer?.cornerRadius = 12; background.layer?.masksToBounds = true
        panel.contentView = background
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.delegate = self
        field.placeholderString = "Open a file by name"
        field.font = .systemFont(ofSize: 16)
        field.delegate = self
        field.focusRingType = .none
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        table.dataSource = self; table.delegate = self
        table.rowHeight = 40
        table.target = self; table.action = #selector(rowClicked(_:))
        table.setAccessibilityLabel("Matching files")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        for view in [field, scroll] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(view) }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8)
        ])
        update()
    }

    func show(over window: NSWindow) {
        let frame = window.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 110 - panel.frame.height))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }
    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose()
    }
    func search(_ query: String) { field.stringValue = query; update() }
    private func update() {
        results = QuickOpenRanking.rank(items, query: field.stringValue)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); table.scrollRowToVisible(0) }
    }
    func choose(row: Int) {
        guard results.indices.contains(row) else { return }
        let item = results[row]
        close()
        onChoose(item)
    }

    func controlTextDidChange(_ notification: Notification) { update() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !results.isEmpty else { return true }
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(max(table.selectedRow + step, 0), results.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)): choose(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
    @objc private func rowClicked(_ sender: Any?) { choose(row: table.clickedRow) }
    func windowDidResignKey(_ notification: Notification) { close() }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 13, weight: .medium); name.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingHead
        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(stack); cell.textField = name
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
