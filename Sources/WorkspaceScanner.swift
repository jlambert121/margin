import Foundation

let markdownExtensions = Set(["md", "markdown", "mdown", "mkd", "txt"])

/// A workspace folder or Markdown file; files have no children.
struct FolderEntry: Equatable {
    let name: String, path: String
    let children: [FolderEntry]?
}

enum WorkspaceScanner {
    private struct Listing {
        var folders: [URL] = []
        var files: [URL] = []
    }

    /// Breadth first, so a large subfolder can't consume the budget before root files.
    /// Limits are configurable so boundary cases can be tested with small fixtures.
    static func scan(_ workspace: URL, entryLimit: Int = 5000, depthLimit: Int = 12) -> FolderEntry {
        var remaining = entryLimit
        var listings: [String: Listing] = [:]
        var level = [workspace]
        for _ in 0 ..< max(0, depthLimit) {
            guard remaining > 0, !level.isEmpty else { break }
            var next: [URL] = []
            for folder in level {
                guard remaining > 0 else { break }
                let listing = readDirectory(folder, remaining: &remaining)
                listings[folder.path] = listing
                next += listing.folders
            }
            level = next
        }
        return FolderEntry(name: workspace.lastPathComponent, path: workspace.path,
                           children: entries(in: workspace, listings: listings))
    }

    private static func readDirectory(_ folder: URL, remaining: inout Int) -> Listing {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return Listing() }
        var listing = Listing()
        let sorted = children.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for child in sorted {
            guard remaining > 0 else { break }
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { continue }
            // Count all readable, non-hidden, non-symlink entries, even ones we omit.
            remaining -= 1
            if values.isDirectory == true {
                if !["node_modules", "vendor", "build", "dist", "DerivedData"].contains(child.lastPathComponent) {
                    listing.folders.append(child)
                }
            } else if markdownExtensions.contains(child.pathExtension.lowercased()) {
                listing.files.append(child)
            }
        }
        return listing
    }

    private static func entries(in folder: URL, listings: [String: Listing]) -> [FolderEntry] {
        guard let listing = listings[folder.path] else { return [] }
        let folders = listing.folders.compactMap { url -> FolderEntry? in
            let children = entries(in: url, listings: listings)
            return children.isEmpty ? nil : FolderEntry(name: url.lastPathComponent, path: url.path, children: children)
        }
        return folders + listing.files.map { FolderEntry(name: $0.lastPathComponent, path: $0.path, children: nil) }
    }
}
