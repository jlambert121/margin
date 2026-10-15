import Foundation

struct RecoveryDraft: Codable, Equatable {
    let version: Int
    let id: UUID
    let text: String
    let originalPath: String?
    let name: String
    let updatedAt: Date

    init(id: UUID, text: String, originalPath: String?, name: String) {
        version = 1
        self.id = id
        self.text = text
        self.originalPath = originalPath
        self.name = name
        updatedAt = Date()
    }
}

// All disk operations share a queue so a delayed checkpoint cannot recreate a
// draft after a successful save or an intentional close removed it.
final class RecoveryStore {
    static let shared = RecoveryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Margin/Recovery", isDirectory: true))
    let directory: URL
    private let queue = DispatchQueue(label: "com.infiniteviewtech.margin.recovery", qos: .utility)

    init(directory: URL) { self.directory = directory }

    private func writeOnQueue(_ draft: RecoveryDraft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(draft.id.uuidString + ".json")
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func write(_ draft: RecoveryDraft) throws { try queue.sync { try writeOnQueue(draft) } }

    func writeAsync(_ draft: RecoveryDraft, completion: @escaping (Error?) -> Void) {
        queue.async {
            let failure: Error?
            do { try self.writeOnQueue(draft); failure = nil }
            catch { failure = error }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    func remove(_ id: UUID) throws {
        try queue.sync {
            do { try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json")) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
        }
    }

    func readAll() throws -> (drafts: [RecoveryDraft], failures: [Error]) {
        try queue.sync {
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return ([], []) }
            var drafts: [RecoveryDraft] = []
            var failures: [Error] = []
            for file in files where file.pathExtension == "json" {
                do {
                    let draft = try JSONDecoder().decode(RecoveryDraft.self, from: Data(contentsOf: file))
                    guard draft.version == 1, file.deletingPathExtension().lastPathComponent == draft.id.uuidString else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    drafts.append(draft)
                } catch { failures.append(error) }
            }
            return (drafts.sorted { $0.updatedAt < $1.updatedAt }, failures)
        }
    }
}

// An acknowledgement belongs to one load. Old messages must never replace
// text after Undo, Revert, or reloading a failed editor.
struct EditorSession {
    private(set) var token = UUID().uuidString
    private(set) var isLoaded = false
    private var revision = 0

    mutating func beginLoad() -> String {
        token = UUID().uuidString
        isLoaded = false
        revision = 0
        return token
    }
    mutating func acknowledge(_ candidate: String) {
        if candidate == token { isLoaded = true }
    }
    func accepts(_ candidate: String) -> Bool { isLoaded && candidate == token }
    mutating func acceptChange(token candidate: String, revision next: Int) -> Bool {
        guard accepts(candidate), next > revision else { return false }
        revision = next
        return true
    }
}
