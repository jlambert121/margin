import Foundation

@main struct WorkspaceScannerTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("margin-scanner-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var failures = 0
        func test(_ name: String, _ body: (URL) throws -> Void) {
            do {
                let workspace = root.appendingPathComponent(UUID().uuidString)
                try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
                try body(workspace)
                print("PASS \(name)")
            } catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "WorkspaceScannerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func file(_ path: String, in workspace: URL) throws {
            let url = workspace.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Note\n".utf8).write(to: url)
        }
        func names(_ entry: FolderEntry) -> [String] {
            (entry.children ?? []).map(\.name)
        }

        test("Filters hidden entries, symlinks, non-Markdown files, and generated directories") { workspace in
            for path in ["Visible.MD", "note.markdown", "draft.mdown", "other.mkd", "plain.txt", "ignore.csv", ".hidden.md", ".hidden/inside.md",
                         "node_modules/skip.md", "vendor/skip.md", "build/skip.md", "dist/skip.md", "DerivedData/skip.md"]
            {
                try file(path, in: workspace)
            }
            try manager.createSymbolicLink(at: workspace.appendingPathComponent("linked.md"), withDestinationURL: workspace.appendingPathComponent("Visible.MD"))
            try manager.createSymbolicLink(at: workspace.appendingPathComponent("loop"), withDestinationURL: workspace)
            let tree = WorkspaceScanner.scan(workspace)
            try expect(Set(names(tree)) == Set(["Visible.MD", "note.markdown", "draft.mdown", "other.mkd", "plain.txt"]), "Unexpected entries: \(names(tree))")
            try expect(tree.path == workspace.path && tree.name == workspace.lastPathComponent, "Root identity changed")
            try expect(tree.children?.allSatisfy { $0.children == nil && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == workspace.appendingPathComponent($0.name).resolvingSymlinksInPath() } == true, "File paths or leaf representation changed")
        }
        test("Sorts naturally with folders before files and prunes empty folders") { workspace in
            for path in ["Z folder/note.md", "A folder/10.md", "A folder/2.md", "empty/ignore.csv", "10.md", "2.md"] {
                try file(path, in: workspace)
            }
            let tree = WorkspaceScanner.scan(workspace)
            try expect(names(tree) == ["A folder", "Z folder", "2.md", "10.md"], "Wrong root order: \(names(tree))")
            try expect(names(tree.children![0]) == ["2.md", "10.md"], "Wrong nested order")
        }
        test("Breadth-first scanning preserves shallower files when a subfolder exhausts the budget") { workspace in
            for path in ["A large/1.md", "A large/2.md", "A large/3.md", "Z sibling/note.md", "Root.md"] {
                try file(path, in: workspace)
            }
            let tree = WorkspaceScanner.scan(workspace, entryLimit: 5)
            try expect(names(tree) == ["A large", "Root.md"], "Root file lost or unscanned folder retained")
            try expect(names(tree.children![0]) == ["1.md", "2.md"], "Budget was not shared across directories")
        }
        test("Ignored regular entries consume the budget, but hidden files and symlinks do not") { workspace in
            for path in [".hidden.md", "A.csv", "B.md", "C.md"] {
                try file(path, in: workspace)
            }
            try manager.createSymbolicLink(at: workspace.appendingPathComponent("AA.md"), withDestinationURL: workspace.appendingPathComponent("C.md"))
            try expect(names(WorkspaceScanner.scan(workspace, entryLimit: 2)) == ["B.md"], "Entry counting changed")
        }
        test("Depth limits include the root level and prune unvisited descendants") { workspace in
            for path in ["Root.md", "Outer/Mid.md", "Outer/Inner/Deep.md"] {
                try file(path, in: workspace)
            }
            try expect(names(WorkspaceScanner.scan(workspace, depthLimit: 1)) == ["Root.md"], "Depth one scanned beyond the root")
            let two = WorkspaceScanner.scan(workspace, depthLimit: 2)
            try expect(names(two) == ["Outer", "Root.md"] && names(two.children![0]) == ["Mid.md"], "Depth two included deeper descendants")
            let three = WorkspaceScanner.scan(workspace, depthLimit: 3)
            try expect(names(three.children![0]) == ["Inner", "Mid.md"], "Depth three lost a reachable folder")
        }
        test("Default depth limit stops after twelve directory levels") { workspace in
            let prefix = Array(repeating: "nested", count: 11).joined(separator: "/")
            try file(prefix + "/Visible.md", in: workspace)
            try file(prefix + "/deeper/Hidden.md", in: workspace)
            var tree = WorkspaceScanner.scan(workspace)
            for _ in 0 ..< 11 {
                try expect(names(tree) == ["nested"], "Reachable directory was lost")
                tree = tree.children![0]
            }
            try expect(names(tree) == ["Visible.md"], "Default depth boundary changed")
        }
        test("Empty, missing, and zero-budget workspaces return an empty root") { workspace in
            try expect(names(WorkspaceScanner.scan(workspace)).isEmpty, "Empty folder was not empty")
            try expect(names(WorkspaceScanner.scan(workspace.appendingPathComponent("missing"))).isEmpty, "Missing folder was not empty")
            try file("Note.md", in: workspace)
            try expect(names(WorkspaceScanner.scan(workspace, entryLimit: 0)).isEmpty, "Zero entry budget scanned files")
            try expect(names(WorkspaceScanner.scan(workspace, depthLimit: 0)).isEmpty, "Zero depth scanned files")
        }
        if failures > 0 {
            exit(1)
        }
    }
}
