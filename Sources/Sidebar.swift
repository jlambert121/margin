import Cocoa

struct OpenFileEntry: Equatable {
    let id: String, name: String, path: String
    let modified: Bool, current: Bool
}

struct HeadingEntry: Equatable {
    let level: Int, text: String, pos: Int
}

// A workspace folder or Markdown file; files have no children.
struct FolderEntry: Equatable {
    let name: String, path: String
    let children: [FolderEntry]?
}

enum SidebarMode: Int { case files, outline }

extension Notification.Name {
    static let sidebarStateChanged = Notification.Name("Margin.sidebarStateChanged")
}

// Sidebar layout and navigation shared by every tab in a window's tab group,
// so switching tabs leaves the sidebar as it was.
final class SidebarState {
    var collapsed: Bool { didSet { if collapsed != oldValue { defaults.set(collapsed, forKey: "sidebarCollapsed"); changed() } } }
    var width: CGFloat { didSet { if abs(width - oldValue) > 0.5 { defaults.set(Double(width), forKey: "sidebarWidth"); changed() } } }
    var mode: SidebarMode = .files { didSet { if mode != oldValue { changed() } } }
    var filter = "" { didSet { if filter != oldValue { changed() } } }
    // Top-level folders start open and nested ones closed; these paths are the exceptions.
    var toggledFolders: Set<String> = [] { didSet { if toggledFolders != oldValue { changed() } } }
    private let defaults: UserDefaults

    // New tab groups start from the last collapsed state and width.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = defaults.bool(forKey: "sidebarCollapsed")
        let stored = defaults.double(forKey: "sidebarWidth")
        width = stored > 0 ? CGFloat(stored) : SidebarViewController.defaultWidth
    }
    func copy() -> SidebarState {
        let copy = SidebarState(defaults: defaults)
        copy.collapsed = collapsed; copy.width = width; copy.mode = mode; copy.filter = filter; copy.toggledFolders = toggledFolders
        return copy
    }
    func isExpanded(_ folder: FolderEntry, depth: Int) -> Bool { (depth == 0) != toggledFolders.contains(folder.path) }
    func setExpanded(_ expanded: Bool, folder: FolderEntry, depth: Int) {
        if expanded == (depth == 0) { toggledFolders.remove(folder.path) } else { toggledFolders.insert(folder.path) }
    }
    private func changed() { NotificationCenter.default.post(name: .sidebarStateChanged, object: self) }
}

enum SidebarStates {
    private static let byGroup = NSMapTable<NSWindowTabGroup, SidebarState>.weakToStrongObjects()
    // A window joining a group takes the group's state. A window that becomes
    // a group of its own keeps what it had, as a copy once another group shares it.
    static func state(for group: NSWindowTabGroup, current: SidebarState) -> SidebarState {
        if let existing = byGroup.object(forKey: group) { return existing }
        let shared = byGroup.objectEnumerator()?.allObjects.contains { ($0 as AnyObject) === current } == true
        let state = shared ? current.copy() : current
        byGroup.setObject(state, forKey: group)
        return state
    }
}

final class SidebarNode {
    enum Kind {
        case header(String, refresh: Bool)
        case openFile(OpenFileEntry)
        case folder(FolderEntry, depth: Int)
        case file(FolderEntry)
        case message(String)
        case openFolderPrompt
    }
    let kind: Kind
    var children: [SidebarNode]
    init(_ kind: Kind, children: [SidebarNode] = []) { self.kind = kind; self.children = children }
    var isSelectable: Bool {
        switch kind { case .openFile, .file, .folder: return true; default: return false }
    }
}

// Selected rows in the app's green rather than the system accent. The row stays
// emphasized so AppKit keeps its text white; inactive windows get a dimmer green
// instead of the gray that would come with accent-tinted text.
final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set { needsDisplay = true } }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let active = window?.isKeyWindow == true
        SidebarViewController.selection.withAlphaComponent(active ? 1 : 0.6).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let defaultWidth: CGFloat = 244
    static let accent = NSColor(name: "MarginAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xa2 / 255, green: 0xb9 / 255, blue: 0x9a / 255, alpha: 1)
            : NSColor(srgbRed: 0x53 / 255, green: 0x74 / 255, blue: 0x60 / 255, alpha: 1)
    }
    // The darker accent in both appearances keeps white text on it readable.
    static let selection = NSColor(srgbRed: 0x53 / 255, green: 0x74 / 255, blue: 0x60 / 255, alpha: 1)
    var state = SidebarState() { didSet { if state !== oldValue { appliedTree = nil; observeState(); applyState() } } }
    var onSelectOpenFile: (String) -> Void = { _ in }
    var onCloseOpenFile: (String) -> Void = { _ in }
    var onOpenPath: (String) -> Void = { _ in }
    var onReveal: (Int) -> Void = { _ in }
    // new, open, openFolder, refreshFolder, or toggleSidebar.
    var onAction: (String) -> Void = { _ in }

    private(set) var openFiles: [OpenFileEntry] = []
    private(set) var folder: FolderEntry?
    private(set) var headings: [HeadingEntry] = []
    var currentPath = "" { didSet { if currentPath != oldValue { reloadFiles() } } }

    let modeControl = NSSegmentedControl(labels: ["Files", "Outline"], trackingMode: .selectOne, target: nil, action: nil)
    let filterField = NSSearchField()
    let filesView = NSOutlineView()
    let outlineView = NSTableView()
    let toggleButton = NSButton()
    private let filesScroll = NSScrollView()
    private let outlineScroll = NSScrollView()
    private let outlineEmpty = NSTextField(wrappingLabelWithString: "Add a heading to give your words a little structure.")
    private var roots: [SidebarNode] = []
    private var applyingExpansion = false
    // The filter and opened folders the tree was last built with.
    private var appliedTree: (filter: String, toggled: Set<String>)?
    private var stateObserver: NSObjectProtocol?

    deinit { if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) } }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: 600))
        let mark = NSTextField(labelWithString: "m")
        mark.font = NSFont(name: "Georgia-BoldItalic", size: 22) ?? .boldSystemFont(ofSize: 22)
        mark.textColor = Self.accent
        let title = NSTextField(labelWithString: "Margin")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        toggleButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Hide sidebar")
        toggleButton.isBordered = false; toggleButton.bezelStyle = .regularSquare
        toggleButton.toolTip = "Hide sidebar (⇧⌘L)"
        toggleButton.target = self; toggleButton.action = #selector(toggleClicked(_:))
        let brand = NSStackView(views: [mark, title, NSView(), toggleButton])
        brand.orientation = .horizontal; brand.spacing = 6

        modeControl.target = self; modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentDistribution = .fillEqually
        modeControl.selectedSegmentBezelColor = Self.selection
        modeControl.selectedSegment = 0

        filterField.placeholderString = "Filter workspace"
        filterField.delegate = self
        filterField.controlSize = .small

        filesView.headerView = nil
        filesView.style = .sourceList
        filesView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files")))
        filesView.outlineTableColumn = filesView.tableColumns.first
        filesView.dataSource = self; filesView.delegate = self
        filesView.target = self; filesView.action = #selector(filesClicked(_:))
        filesView.indentationPerLevel = 12
        filesView.setAccessibilityLabel("Files")
        filesScroll.documentView = filesView
        filesScroll.hasVerticalScroller = true; filesScroll.drawsBackground = false; filesScroll.borderType = .noBorder
        let filesStack = NSStackView(views: [filterField, filesScroll])
        filesStack.orientation = .vertical; filesStack.alignment = .leading; filesStack.spacing = 8

        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline")))
        outlineView.dataSource = self; outlineView.delegate = self
        outlineView.target = self; outlineView.action = #selector(outlineClicked(_:))
        outlineView.setAccessibilityLabel("Document outline")
        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true; outlineScroll.drawsBackground = false; outlineScroll.borderType = .noBorder
        outlineEmpty.textColor = .secondaryLabelColor
        outlineEmpty.font = .systemFont(ofSize: 12)
        let outlineStack = NSStackView(views: [outlineEmpty, outlineScroll])
        outlineStack.orientation = .vertical; outlineStack.alignment = .leading; outlineStack.spacing = 8

        let newButton = NSButton(title: "New document", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(newClicked(_:)))
        newButton.isBordered = false; newButton.imagePosition = .imageLeading; newButton.toolTip = "New document (⌘N)"
        let openButton = NSButton(image: NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open file") ?? NSImage(), target: self, action: #selector(openClicked(_:)))
        openButton.isBordered = false; openButton.toolTip = "Open file (⌘O)"
        let footer = NSStackView(views: [newButton, NSView(), openButton])
        footer.orientation = .horizontal

        for (index, part) in [brand, modeControl, filesStack, outlineStack, footer].enumerated() {
            part.translatesAutoresizingMaskIntoConstraints = false
            part.identifier = NSUserInterfaceItemIdentifier(["brand", "mode", "files", "outline", "footer"][index])
            view.addSubview(part)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            modeControl.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 12),
            filesStack.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            outlineStack.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            filesStack.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            outlineStack.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            filesScroll.widthAnchor.constraint(equalTo: filesStack.widthAnchor),
            outlineScroll.widthAnchor.constraint(equalTo: outlineStack.widthAnchor),
            outlineEmpty.widthAnchor.constraint(equalTo: outlineStack.widthAnchor)
        ])
        for part in [brand, modeControl, filesStack, outlineStack, footer] {
            let inset: CGFloat = part === filesStack || part === outlineStack ? 4 : 14
            part.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset).isActive = true
            part.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset).isActive = true
        }
        filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14).isActive = true
        filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14).isActive = true
        self.view = view
        observeState()
        applyState()
    }

    // MARK: Data from the editor window

    func setOpenFiles(_ files: [OpenFileEntry]) {
        guard files != openFiles else { return }
        openFiles = files; reloadFiles()
    }
    func setFolder(_ entry: FolderEntry?) {
        guard entry != folder else { return }
        folder = entry; reloadFiles()
    }
    func setHeadings(_ entries: [HeadingEntry]) {
        guard entries != headings else { return }
        headings = entries
        guard isViewLoaded else { return }
        outlineView.reloadData()
        outlineEmpty.isHidden = !headings.isEmpty
    }

    // MARK: State

    private func observeState() {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        stateObserver = NotificationCenter.default.addObserver(forName: .sidebarStateChanged, object: state, queue: .main) { [weak self] _ in self?.applyState() }
    }
    private func applyState() {
        guard isViewLoaded else { return }
        modeControl.selectedSegment = state.mode.rawValue
        view.subviews.first { $0.identifier?.rawValue == "files" }?.isHidden = state.mode != .files
        view.subviews.first { $0.identifier?.rawValue == "outline" }?.isHidden = state.mode != .outline
        if filterField.stringValue != state.filter { filterField.stringValue = state.filter }
        // Width and collapsing are in the state too, and change on every step of a divider drag.
        if appliedTree.map({ $0.filter != state.filter || $0.toggled != state.toggledFolders }) ?? true { reloadFiles() }
        outlineEmpty.isHidden = !headings.isEmpty
    }

    // MARK: Files list

    private func reloadFiles() {
        guard isViewLoaded else { return }
        let query = state.filter.trimmingCharacters(in: .whitespaces).lowercased()
        var nodes: [SidebarNode] = []
        if !openFiles.isEmpty {
            nodes.append(SidebarNode(.header("Open Files", refresh: false)))
            nodes += openFiles.map { SidebarNode(.openFile($0)) }
        }
        nodes.append(SidebarNode(.header(folder?.name ?? "Workspace", refresh: folder != nil)))
        filterField.isHidden = folder == nil
        if let folder {
            let tree = Self.tree(folder.children ?? [], depth: 0, query: query)
            nodes += tree.isEmpty ? [SidebarNode(.message(query.isEmpty ? "No Markdown files in this folder." : "No matching files."))] : tree
        } else {
            nodes.append(SidebarNode(.openFolderPrompt))
        }
        roots = nodes
        appliedTree = (state.filter, state.toggledFolders)
        applyingExpansion = true
        filesView.reloadData()
        func expand(_ nodes: [SidebarNode]) {
            for node in nodes {
                guard case let .folder(entry, depth) = node.kind else { continue }
                if !query.isEmpty || state.isExpanded(entry, depth: depth) { filesView.expandItem(node); expand(node.children) }
            }
        }
        expand(roots)
        applyingExpansion = false
        let current = roots.firstIndex { if case let .openFile(file) = $0.kind { return file.current }; return false }
        if let current { filesView.selectRowIndexes(IndexSet(integer: filesView.row(forItem: roots[current])), byExtendingSelection: false) }
        else { filesView.deselectAll(nil) }
    }
    private static func tree(_ entries: [FolderEntry], depth: Int, query: String) -> [SidebarNode] {
        entries.compactMap { entry in
            if let children = entry.children {
                let nested = tree(children, depth: depth + 1, query: query)
                return nested.isEmpty ? nil : SidebarNode(.folder(entry, depth: depth), children: nested)
            }
            return query.isEmpty || entry.name.lowercased().contains(query) ? SidebarNode(.file(entry)) : nil
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? SidebarNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? SidebarNode)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? SidebarNode)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarNode)?.isSelectable == true }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? SidebarNode)?.kind {
        case .openFolderPrompt: return 92
        case .message: return 40
        case .header: return 28
        default: return 26
        }
    }
    func outlineViewItemDidExpand(_ notification: Notification) { folderToggled(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { folderToggled(notification, expanded: false) }
    private func folderToggled(_ notification: Notification, expanded: Bool) {
        guard !applyingExpansion, state.filter.isEmpty, let node = notification.userInfo?["NSObject"] as? SidebarNode,
              case let .folder(entry, depth) = node.kind else { return }
        state.setExpanded(expanded, folder: entry, depth: depth)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case let .header(title, refresh):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            var views: [NSView] = [label, NSView()]
            if refresh {
                let button = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh folder") ?? NSImage(), target: self, action: #selector(refreshClicked(_:)))
                button.isBordered = false; button.toolTip = "Refresh folder"
                views.append(button)
            }
            return row(views)
        case let .openFile(file):
            var views: [NSView] = [icon("doc.text"), name(file.name)]
            if file.modified {
                let dot = NSTextField(labelWithString: "●"); dot.font = .systemFont(ofSize: 7); dot.textColor = Self.accent; dot.toolTip = "Unsaved changes"
                views.append(dot)
            }
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(file.name)") ?? NSImage(), target: self, action: #selector(closeClicked(_:)))
            close.isBordered = false; close.toolTip = "Close \(file.name)"; close.identifier = NSUserInterfaceItemIdentifier(file.id)
            close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            views += [NSView(), close]
            let cell = row(views); cell.toolTip = file.path.isEmpty ? file.name : file.path
            return cell
        case let .folder(entry, _):
            return row([icon("folder"), name(entry.name)])
        case let .file(entry):
            let label = name(entry.name)
            if entry.path == currentPath { label.textColor = Self.accent; label.font = .systemFont(ofSize: 13, weight: .medium) }
            let cell = row([icon("doc.text"), label]); cell.toolTip = entry.path
            return cell
        case let .message(text):
            let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
            return row([label])
        case .openFolderPrompt:
            let detail = NSTextField(wrappingLabelWithString: "Open a folder to browse your Markdown files."); detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
            detail.alignment = .center
            let button = NSButton(title: "Open Folder…", target: self, action: #selector(openFolderClicked(_:)))
            button.toolTip = "Open Folder (⇧⌘O)"
            let stack = NSStackView(views: [detail, button])
            stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .centerX
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
            return stack
        }
    }
    private func row(_ views: [NSView]) -> NSTableCellView {
        let cell = NSTableCellView()
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        if let label = views.first(where: { $0 is NSTextField }) as? NSTextField { cell.textField = label; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return cell
    }
    private func icon(_ symbol: String) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        view.contentTintColor = .secondaryLabelColor
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        return view
    }
    private func name(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13); label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    // MARK: Outline list

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        let heading = headings[index]
        let label = name(heading.text); label.lineBreakMode = .byTruncatingTail; label.toolTip = heading.text
        if heading.level == 1 { label.font = .systemFont(ofSize: 13, weight: .semibold) }
        let cell = row([label])
        (cell.subviews.first as? NSStackView)?.edgeInsets.left = CGFloat(heading.level - 1) * 12
        return cell
    }

    // MARK: Actions

    // Rows act on click; selection only marks the current tab.
    @objc private func filesClicked(_ sender: Any?) { if filesView.clickedRow >= 0 { activateFile(row: filesView.clickedRow) } }
    func activateFile(row: Int) {
        guard let node = filesView.item(atRow: row) as? SidebarNode else { return }
        switch node.kind {
        case let .openFile(file): onSelectOpenFile(file.id)
        case let .file(entry): onOpenPath(entry.path)
        case .folder: filesView.isItemExpanded(node) ? filesView.collapseItem(node) : filesView.expandItem(node)
        default: break
        }
        reloadSelectionSoon()
    }
    @objc private func outlineClicked(_ sender: Any?) { activateHeading(row: outlineView.clickedRow) }
    func activateHeading(row: Int) {
        guard headings.indices.contains(row) else { return }
        onReveal(headings[row].pos)
        outlineView.deselectAll(nil)
    }
    @objc private func closeClicked(_ sender: NSButton) { if let id = sender.identifier?.rawValue { onCloseOpenFile(id) } }
    @objc private func modeChanged(_ sender: NSSegmentedControl) { state.mode = SidebarMode(rawValue: sender.selectedSegment) ?? .files }
    @objc private func toggleClicked(_ sender: Any?) { onAction("toggleSidebar") }
    @objc private func refreshClicked(_ sender: Any?) { onAction("refreshFolder") }
    @objc private func openFolderClicked(_ sender: Any?) { onAction("openFolder") }
    @objc private func newClicked(_ sender: Any?) { onAction("new") }
    @objc private func openClicked(_ sender: Any?) { onAction("open") }
    func controlTextDidChange(_ notification: Notification) { state.filter = filterField.stringValue }
    private func reloadSelectionSoon() { DispatchQueue.main.async { [weak self] in self?.reloadFiles() } }

    // MARK: Inspection for tests

    var openFileNames: [String] { roots.compactMap { if case let .openFile(file) = $0.kind { return file.name }; return nil } }
    var currentOpenFileName: String? { roots.lazy.compactMap { if case let .openFile(file) = $0.kind, file.current { return file.name }; return nil }.first }
    // Every visible file and folder row, indented by depth.
    var visibleTreeRows: [String] {
        (0..<filesView.numberOfRows).compactMap { row in
            guard let node = filesView.item(atRow: row) as? SidebarNode else { return nil }
            let indent = String(repeating: "  ", count: filesView.level(forRow: row))
            switch node.kind {
            case let .folder(entry, _): return indent + entry.name + "/"
            case let .file(entry): return indent + entry.name
            case let .message(text): return indent + "(" + text + ")"
            default: return nil
            }
        }
    }
    func rowIndex(named name: String) -> Int? {
        (0..<filesView.numberOfRows).first { row in
            switch (filesView.item(atRow: row) as? SidebarNode)?.kind {
            case let .openFile(file): return file.name == name
            case let .file(entry): return entry.name == name
            case let .folder(entry, _): return entry.name == name
            default: return false
            }
        }
    }
}
