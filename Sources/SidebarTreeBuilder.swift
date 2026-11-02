import Cocoa

enum SidebarTreeBuilder {
    static func roots(folder: FolderEntry?, openFiles: [OpenFileEntry], query: String) -> [SidebarNode] {
        var nodes: [SidebarNode] = []
        if !openFiles.isEmpty {
            nodes.append(SidebarNode(.header("Open Files", refresh: false)))
            nodes += openFiles.map { SidebarNode(.openFile($0)) }
        }
        nodes.append(SidebarNode(.header(folder?.name ?? "Workspace", refresh: folder != nil)))
        if let folder {
            let tree = tree(folder.children ?? [], depth: 0, query: query)
            nodes += tree.isEmpty ? [SidebarNode(.message(query.isEmpty ? "No Markdown files in this folder." : "No matching files."))] : tree
        } else {
            nodes.append(SidebarNode(.openFolderPrompt))
        }
        return nodes
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
}
