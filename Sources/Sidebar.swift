import Cocoa

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    static let defaultWidth: CGFloat = 244
    private static let openFileType = NSPasteboard.PasteboardType("com.infiniteviewtech.margin.open-file")
    static let accent = NSColor(name: "MarginAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xA2 / 255, green: 0xB9 / 255, blue: 0x9A / 255, alpha: 1)
            : NSColor(srgbRed: 0x53 / 255, green: 0x74 / 255, blue: 0x60 / 255, alpha: 1)
    }

    // The darker accent in both appearances keeps white text on it readable.
    static let selection = NSColor(srgbRed: 0x53 / 255, green: 0x74 / 255, blue: 0x60 / 255, alpha: 1)
    var state = SidebarState() {
        didSet {
            if state !== oldValue {
                appliedTree = nil; observeState(); applyState()
            }
        }
    }

    var onSelectOpenFile: (String) -> Void = { _ in }
    var onCloseOpenFile: (String) -> Void = { _ in }
    // An open file's id and its new position among the open files.
    var onMoveOpenFile: (String, Int) -> Void = { _, _ in }
    var onOpenPath: (String) -> Void = { _ in }
    var onReveal: (Int) -> Void = { _ in }
    // A folder path to create a file in, and a file path with its new name.
    var onNewFile: (String) -> Void = { _ in }
    var onRename: (String, String) -> Void = { _, _ in }
    var renamingPath: String? {
        fileActions.renamingPath
    }

    private lazy var rowFactory = SidebarRowFactory(target: self)
    private lazy var fileActions = SidebarFileActions(host: self)
    /// new, open, openFolder, refreshFolder, or toggleSidebar.
    var onAction: (String) -> Void = { _ in }

    private(set) var openFiles: [OpenFileEntry] = []
    private(set) var folder: FolderEntry?
    private(set) var headings: [HeadingEntry] = []
    var currentPath = "" {
        didSet {
            if currentPath != oldValue {
                reloadFiles()
            }
        }
    }

    let modeControl = NSSegmentedControl(labels: ["Files", "Outline"], trackingMode: .selectOne, target: nil, action: nil)
    let filterField = NSSearchField()
    let filesView = NSOutlineView()
    let outlineView = NSTableView()
    let toggleButton = NSButton()
    private let filesScroll = NSScrollView()
    private let outlineScroll = NSScrollView()
    private let outlineEmpty = NSTextField(wrappingLabelWithString: "Add a heading to give your words a little structure.")
    private var roots: [SidebarNode] = []
    /// Set while the tree and the state are brought in line, so neither change echoes back into the other.
    private var syncingTree = false
    // The filter and opened folders the tree shows.
    private var appliedTree: (filter: String, toggled: Set<String>)?
    private var stateObserver: NSObjectProtocol?

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

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
        filesView.menu = NSMenu()
        filesView.menu?.delegate = self
        filesView.registerForDraggedTypes([Self.openFileType])
        filesView.setDraggingSourceOperationMask(.move, forLocal: true)
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
            outlineEmpty.widthAnchor.constraint(equalTo: outlineStack.widthAnchor),
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
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        stateObserver = NotificationCenter.default.addObserver(forName: .sidebarStateChanged, object: state, queue: .main) { [weak self] _ in self?.applyState() }
    }

    private func applyState() {
        guard isViewLoaded else { return }
        modeControl.selectedSegment = state.mode.rawValue
        view.subviews.first { $0.identifier?.rawValue == "files" }?.isHidden = state.mode != .files
        view.subviews.first { $0.identifier?.rawValue == "outline" }?.isHidden = state.mode != .outline
        if filterField.stringValue != state.filter {
            filterField.stringValue = state.filter
        }
        // Width and collapsing are in the state too, and change on every step of a divider drag.
        if !syncingTree, appliedTree.map({ $0.filter != state.filter || $0.toggled != state.toggledFolders }) ?? true {
            reloadFiles()
        }
        outlineEmpty.isHidden = !headings.isEmpty
    }

    // MARK: Files list

    private func reloadFiles() {
        guard isViewLoaded else { return }
        // Rebuilding would end the rename in progress; it happens once the rename ends.
        guard renamingPath == nil else { return }
        let query = state.filter.trimmingCharacters(in: .whitespaces).lowercased()
        filterField.isHidden = folder == nil
        roots = SidebarTreeBuilder.roots(folder: folder, openFiles: openFiles, query: query)
        appliedTree = (state.filter, state.toggledFolders)
        syncingTree = true
        filesView.reloadData()
        /// AppKit only keeps a folder open inside a closed one if it was opened while showing, so a closed
        /// folder holding open ones is opened for them and closed again after.
        func expand(_ nodes: [SidebarNode]) {
            for node in nodes {
                guard case let .folder(entry, depth) = node.kind else { continue }
                let open = !query.isEmpty || state.isExpanded(entry, depth: depth)
                guard open || holdsOpenFolder(node) else { continue }
                filesView.expandItem(node)
                expand(node.children)
                if !open {
                    filesView.collapseItem(node)
                }
            }
        }
        func holdsOpenFolder(_ node: SidebarNode) -> Bool {
            node.children.contains {
                if case let .folder(entry, depth) = $0.kind {
                    return state.isExpanded(entry, depth: depth) || holdsOpenFolder($0)
                }; return false
            }
        }
        expand(roots)
        syncingTree = false
        selectCurrentFile()
    }

    private func selectCurrentFile() {
        let current = roots.firstIndex {
            if case let .openFile(file) = $0.kind {
                return file.current
            }; return false
        }
        if let current {
            filesView.selectRowIndexes(IndexSet(integer: filesView.row(forItem: roots[current])), byExtendingSelection: false)
        } else {
            filesView.deselectAll(nil)
        }
    }

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    func outlineView(_: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSelectable == true
    }

    func outlineView(_: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        rowFactory.height(for: item as? SidebarNode)
    }

    /// Open files reorder by dragging within their section.
    func outlineView(_: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard case let .openFile(file) = (item as? SidebarNode)?.kind else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(file.id, forType: Self.openFileType)
        return writer
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: Self.openFileType) != nil, !openFiles.isEmpty else { return [] }
        // Root rows are the Open Files header, then the open files.
        let position = item == nil && index >= 1 ? min(index, openFiles.count + 1) : (index < 1 ? 1 : openFiles.count + 1)
        if item != nil || position != index {
            outlineView.setDropItem(nil, dropChildIndex: position)
        }
        return .move
    }

    func outlineView(_: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let id = info.draggingPasteboard.string(forType: Self.openFileType), item == nil, index >= 1 else { return false }
        onMoveOpenFile(id, min(index - 1, openFiles.count))
        return true
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        folderToggled(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        folderToggled(notification, expanded: false)
    }

    private func folderToggled(_ notification: Notification, expanded: Bool) {
        guard !syncingTree, state.filter.isEmpty, let node = notification.userInfo?["NSObject"] as? SidebarNode,
              case let .folder(entry, depth) = node.kind else { return }
        // AppKit reports the open folders inside a collapsing folder as collapsing too, and as expanding when it
        // reopens; only the folder toggled is remembered, unless Option closed the ones inside it as well.
        if let parent = filesView.parent(forItem: node), !filesView.isItemExpanded(parent), expanded || !optionClicked {
            return
        }
        // The view already shows the change, and AppKit is still walking its rows, so the tree is not rebuilt.
        syncingTree = true
        state.setExpanded(expanded, folder: entry, depth: depth)
        syncingTree = false
        appliedTree = (state.filter, state.toggledFolders)
    }

    /// Option-clicking a folder also opens or closes the folders inside it, as on the disclosure triangle.
    private var optionClicked: Bool {
        NSApp?.currentEvent?.modifierFlags.contains(.option) == true
    }

    func outlineView(_: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        return rowFactory.fileRow(node, currentPath: currentPath)
    }

    // MARK: Outline list

    func numberOfRows(in _: NSTableView) -> Int {
        headings.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row index: Int) -> NSView? {
        rowFactory.headingRow(headings[index])
    }

    // MARK: Actions

    /// Rows act on click; selection only marks the current tab.
    @objc private func filesClicked(_: Any?) {
        if filesView.clickedRow >= 0 {
            activateFile(row: filesView.clickedRow)
        }
    }

    func activateFile(row: Int) {
        guard let node = filesView.item(atRow: row) as? SidebarNode else { return }
        switch node.kind {
        case let .openFile(file): onSelectOpenFile(file.id)
        case let .file(entry): onOpenPath(entry.path)
        case .folder:
            if filesView.isItemExpanded(node) {
                filesView.collapseItem(node, collapseChildren: optionClicked)
            } else {
                filesView.expandItem(node, expandChildren: optionClicked)
            }
        default: break
        }
        DispatchQueue.main.async { [weak self] in self?.selectCurrentFile() }
    }

    @objc private func outlineClicked(_: Any?) {
        activateHeading(row: outlineView.clickedRow)
    }

    func activateHeading(row: Int) {
        guard headings.indices.contains(row) else { return }
        onReveal(headings[row].pos)
        outlineView.deselectAll(nil)
    }

    @objc func closeClicked(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue {
            onCloseOpenFile(id)
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        state.mode = SidebarMode(rawValue: sender.selectedSegment) ?? .files
    }

    @objc private func toggleClicked(_: Any?) {
        onAction("toggleSidebar")
    }

    @objc func refreshClicked(_: Any?) {
        onAction("refreshFolder")
    }

    @objc func openFolderClicked(_: Any?) {
        onAction("openFolder")
    }

    @objc private func newClicked(_: Any?) {
        onAction("new")
    }

    @objc private func openClicked(_: Any?) {
        onAction("open")
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === filterField {
            state.filter = filterField.stringValue
        }
    }

    // MARK: New file and rename

    func menuNeedsUpdate(_ menu: NSMenu) {
        fileActions.menuNeedsUpdate(menu)
    }

    func beginRename(path: String) {
        fileActions.beginRename(path: path)
    }

    func prepareRename(path: String) -> NSTextField? {
        guard isViewLoaded else { return nil }
        var ancestor = (path as NSString).deletingLastPathComponent
        syncingTree = true
        while let folder, ancestor.hasPrefix(folder.path + "/") {
            if let node = node(forPath: ancestor), case let .folder(entry, depth) = node.kind, !state.isExpanded(entry, depth: depth) {
                state.setExpanded(true, folder: entry, depth: depth)
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        syncingTree = false
        reloadFiles()
        guard let node = node(forPath: path), case .file = node.kind else { return nil }
        let row = filesView.row(forItem: node)
        guard row >= 0, let cell = filesView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, let field = cell.textField else { return nil }
        filesView.scrollRowToVisible(row)
        return field
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        fileActions.control(control, textView: textView, doCommandBy: selector)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        fileActions.controlTextDidEndEditing(notification)
    }

    func finishRename(path: String, name: String, cancelled: Bool = false) {
        fileActions.finishRename(path: path, name: name, cancelled: cancelled)
    }

    func renameDidEnd(path: String, name: String, cancelled: Bool) {
        reloadFiles()
        if !cancelled, name != (path as NSString).lastPathComponent {
            onRename(path, name)
        }
    }

    private func node(forPath path: String) -> SidebarNode? {
        func find(_ nodes: [SidebarNode]) -> SidebarNode? {
            for node in nodes {
                switch node.kind {
                case let .file(entry) where entry.path == path: return node
                case let .folder(entry, _) where entry.path == path: return node
                default: if let found = find(node.children) {
                        return found
                    }
                }
            }
            return nil
        }
        return find(roots)
    }

    // MARK: Inspection for tests

    var openFileNames: [String] {
        roots.compactMap { $0.openFile?.name }
    }

    var currentOpenFileName: String? {
        roots.lazy.compactMap(\.openFile).first { $0.current }?.name
    }

    /// Every visible file and folder row, indented by depth.
    var visibleTreeRows: [String] {
        (0 ..< filesView.numberOfRows).compactMap { row in
            guard let node = filesView.item(atRow: row) as? SidebarNode else { return nil }
            let indent = String(repeating: "  ", count: filesView.level(forRow: row))
            return node.treeLabel.map { indent + $0 }
        }
    }

    func rowIndex(named name: String) -> Int? {
        (0 ..< filesView.numberOfRows).first { row in
            (filesView.item(atRow: row) as? SidebarNode)?.name == name
        }
    }
}
