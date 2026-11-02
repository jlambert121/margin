import Cocoa

struct OpenFileEntry: Equatable {
    let id: String, name: String, path: String
    // Folders that tell this file apart from open files with the same name, or empty.
    var detail = ""
    let modified: Bool, current: Bool
}

struct HeadingEntry: Equatable {
    let level: Int, text: String, pos: Int
}

enum SidebarMode: Int { case files, outline }

extension Notification.Name {
    static let sidebarStateChanged = Notification.Name("Margin.sidebarStateChanged")
}

/// A window's sidebar layout and navigation, which stay as they are while switching documents.
final class SidebarState {
    var collapsed: Bool {
        didSet {
            if collapsed != oldValue {
                defaults.set(collapsed, forKey: "sidebarCollapsed"); changed()
            }
        }
    }

    var width: CGFloat {
        didSet {
            if abs(width - oldValue) > 0.5 {
                defaults.set(Double(width), forKey: "sidebarWidth"); changed()
            }
        }
    }

    var mode: SidebarMode = .files {
        didSet {
            if mode != oldValue {
                changed()
            }
        }
    }

    var filter = "" {
        didSet {
            if filter != oldValue {
                changed()
            }
        }
    }

    /// Top-level folders start open and nested ones closed; these paths are the exceptions.
    var toggledFolders: Set<String> = [] {
        didSet {
            if toggledFolders != oldValue {
                changed()
            }
        }
    }

    private let defaults: UserDefaults

    /// New windows start from the last collapsed state and width.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = defaults.bool(forKey: "sidebarCollapsed")
        let stored = defaults.double(forKey: "sidebarWidth")
        width = stored > 0 ? CGFloat(stored) : SidebarViewController.defaultWidth
    }

    func isExpanded(_ folder: FolderEntry, depth: Int) -> Bool {
        (depth == 0) != toggledFolders.contains(folder.path)
    }

    func setExpanded(_ expanded: Bool, folder: FolderEntry, depth: Int) {
        if expanded == (depth == 0) {
            toggledFolders.remove(folder.path)
        } else {
            toggledFolders.insert(folder.path)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .sidebarStateChanged, object: self)
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
    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind; self.children = children
    }

    var isSelectable: Bool {
        switch kind { case .openFile, .file, .folder: return true; default: return false }
    }

    var openFile: OpenFileEntry? {
        if case let .openFile(file) = kind {
            return file
        }
        return nil
    }

    var name: String? {
        switch kind {
        case let .openFile(file): return file.name
        case let .file(entry), let .folder(entry, _): return entry.name
        default: return nil
        }
    }

    var treeLabel: String? {
        switch kind {
        case let .folder(entry, _): return entry.name + "/"
        case let .file(entry): return entry.name
        case let .message(text): return "(" + text + ")"
        default: return nil
        }
    }
}
