import Cocoa

/// Selected rows in the app's green rather than the system accent. The row stays
/// emphasized so AppKit keeps its text white; inactive windows get a dimmer green
/// instead of the gray that would come with accent-tinted text.
final class SidebarRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true } set { needsDisplay = true }
    }

    override func drawSelection(in _: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let active = window?.isKeyWindow == true
        SidebarViewController.selection.withAlphaComponent(active ? 1 : 0.6).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

final class SidebarRowFactory {
    func height(for node: SidebarNode?) -> CGFloat {
        switch node?.kind {
        case .openFolderPrompt: return 92
        case .message: return 40
        case .header: return 28
        case let .openFile(file) where !file.detail.isEmpty: return 38
        default: return 26
        }
    }

    private weak var target: SidebarViewController?
    init(target: SidebarViewController) {
        self.target = target
    }

    func fileRow(_ node: SidebarNode, currentPath: String) -> NSView? {
        switch node.kind {
        case let .header(title, refresh):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            var views: [NSView] = [label, NSView()]
            if refresh {
                let button = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh folder") ?? NSImage(), target: target, action: #selector(SidebarViewController.refreshClicked(_:)))
                button.isBordered = false; button.toolTip = "Refresh folder"
                views.append(button)
            }
            return row(views)
        case let .openFile(file):
            let label = name(file.name)
            var views: [NSView] = [icon("doc.text"), label]
            if !file.detail.isEmpty {
                let detail = NSTextField(labelWithString: file.detail)
                detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingHead
                [label, detail].forEach { $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
                let lines = NSStackView(views: [label, detail])
                lines.orientation = .vertical; lines.alignment = .leading; lines.spacing = 1
                views[1] = lines
            }
            if file.modified {
                let dot = NSTextField(labelWithString: "●"); dot.font = .systemFont(ofSize: 7); dot.textColor = SidebarViewController.accent; dot.toolTip = "Unsaved changes"
                views.append(dot)
            }
            let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close \(file.name)") ?? NSImage(), target: target, action: #selector(SidebarViewController.closeClicked(_:)))
            close.isBordered = false; close.toolTip = "Close \(file.name)"; close.identifier = NSUserInterfaceItemIdentifier(file.id)
            close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            views += [NSView(), close]
            let cell = row(views); cell.toolTip = file.path.isEmpty ? file.name : file.path
            cell.textField = label
            return cell
        case let .folder(entry, _):
            return row([icon("folder"), name(entry.name)])
        case let .file(entry):
            let label = name(entry.name)
            if entry.path == currentPath {
                label.textColor = SidebarViewController.accent; label.font = .systemFont(ofSize: 13, weight: .medium)
            }
            let cell = row([icon("doc.text"), label]); cell.toolTip = entry.path
            return cell
        case let .message(text):
            let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor; label.font = .systemFont(ofSize: 12)
            return row([label])
        case .openFolderPrompt:
            let detail = NSTextField(wrappingLabelWithString: "Open a folder to browse your Markdown files."); detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
            detail.alignment = .center
            let button = NSButton(title: "Open Folder…", target: target, action: #selector(SidebarViewController.openFolderClicked(_:)))
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
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if let label = views.first(where: { $0 is NSTextField }) as? NSTextField {
            cell.textField = label; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
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

    func headingRow(_ heading: HeadingEntry) -> NSView? {
        let label = name(heading.text); label.lineBreakMode = .byTruncatingTail; label.toolTip = heading.text
        if heading.level == 1 {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        let cell = row([label])
        (cell.subviews.first as? NSStackView)?.edgeInsets.left = CGFloat(heading.level - 1) * 12
        return cell
    }
}
