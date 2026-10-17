import AppKit

final class SupportStore {
    let directory: URL
    let diagnostics: URL
    private let events: URL
    private let queue = DispatchQueue(label: "com.marwin.petspet.storage", qos: .utility)
    private var lastGeometry: Data?

    init() throws {
        directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PetsPet", isDirectory: true)
        diagnostics = directory.appendingPathComponent("diagnostics.json")
        events = directory.appendingPathComponent("tracking.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func record(_ fields: [String: Any], event: Bool = true) {
        queue.async { [self] in
            var record = fields
            record["timestamp"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return }
            do {
                if fields["event"] == nil {
                    try data.write(to: diagnostics, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnostics.path)
                }
                guard event, var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
                line.append(0x0a)
                let bytes = (try? events.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if bytes > 1_000_000 {
                    let previous = directory.appendingPathComponent("tracking.previous.jsonl")
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: events, to: previous)
                }
                if !FileManager.default.fileExists(atPath: events.path) {
                    FileManager.default.createFile(atPath: events.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: events)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Storage errors must not interrupt Codex or the tracking loop.
            }
        }
    }

    /// Roles, hierarchy and pet-relative rectangles only; never UI text,
    /// identifiers, conversation content or account information.
    func recordGeometry(_ nodes: [[String: Any]]) {
        queue.async { [self] in
            guard let data = try? JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted, .sortedKeys]), data != lastGeometry else { return }
            let path = directory.appendingPathComponent("geometry.json")
            do {
                try data.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                lastGeometry = data
            } catch { /* Diagnostics must not interrupt tracking. */ }
        }
    }
}
