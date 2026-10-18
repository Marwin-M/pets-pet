import Foundation
import Darwin

public struct LocalProject: Equatable, Sendable {
    public let id: String
    public let roots: [String]
    public init?(id: String, roots: [String]) {
        guard !id.isEmpty, id.count <= 512, roots.count <= 8,
              roots.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) else { return nil }
        self.id = id
        // A nested path may be an explicit symlink root pointing outside its
        // parent. Resolve and prune overlapping roots on the scanning queue.
        self.roots = Array(Set(roots)).sorted()
    }
    public static func uniqueRoots(_ roots: [String]) -> [String] {
        let sorted = Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted()
        return sorted.filter { candidate in
            !sorted.contains { parent in parent != candidate && (parent == "/" || candidate.hasPrefix(parent + "/")) }
        }
    }
    var key: String { (try? SidebarScript.json([id, roots])) ?? id }
}

/// Logical bytes, matching Finder's “Size”: include hidden/package contents and
/// count each hard-link entry. Symlinks contribute their own length, never their target.
public enum ProjectDiskUsage {
    public static func measure(_ roots: [String], timeout: TimeInterval = 180, cancelled: () -> Bool = { false }) throws -> Int64 {
        guard !roots.isEmpty else { throw SidebarError.directory }
        let deadline = Date().addingTimeInterval(timeout)
        let canonical = try LocalProject.uniqueRoots(roots.map { root in
            if cancelled() { throw SidebarError.cancelled }
            guard Date() < deadline else { throw SidebarError.timeout }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { throw SidebarError.directory }
            return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        })
        var total: Int64 = 0
        for root in canonical {
            if cancelled() { throw SidebarError.cancelled }
            guard Date() < deadline else { throw SidebarError.timeout }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else { throw SidebarError.directory }
            var failed = false
            guard let entries = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: [], options: [],
                errorHandler: { _, _ in failed = true; return false }
            ) else { throw SidebarError.directory }
            for case let url as URL in entries {
                if cancelled() { throw SidebarError.cancelled }
                guard Date() < deadline else { throw SidebarError.timeout }
                var info = stat()
                let result = url.withUnsafeFileSystemRepresentation { path in
                    path.map { lstat($0, &info) } ?? -1
                }
                guard result == 0 else { throw SidebarError.directory }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR { continue }
                // Do not deduplicate inode numbers: Finder counts every file entry.
                guard info.st_size >= 0, info.st_size <= 9_007_199_254_740_991 - total else { throw SidebarError.directory }
                total += info.st_size
            }
            if failed { throw SidebarError.directory }
            if cancelled() { throw SidebarError.cancelled }
            guard Date() < deadline else { throw SidebarError.timeout }
        }
        return total
    }
}

@MainActor public final class ProjectSizeScanner {
    private struct Entry {
        let bytes: Int64?
        let at: Date
    }
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "com.marwin.petspet.project-size"
        queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility
        return queue
    }()
    private var cache: [String: Entry] = [:]
    private var pending: [String: BlockOperation] = [:]
    private var generation = 0
    public var onChange: (() -> Void)?
    public init() {}

    public func snapshot(_ projects: [LocalProject], at now: Date = Date()) -> [String: Any] {
        let keys = Set(projects.map(\.key))
        for key in Array(pending.keys) where !keys.contains(key) { pending.removeValue(forKey: key)?.cancel() }
        cache = cache.filter { keys.contains($0.key) || now.timeIntervalSince($0.value.at) < 300 }
        var values: [String: Any] = [:]
        for project in projects.prefix(200) {
            guard !project.roots.isEmpty else {
                values[project.id] = ["state": "unavailable", "message": "此项目暂无可读取的本地目录"]; continue
            }
            let key = project.key, entry = cache[key]
            let fresh = entry.map { now.timeIntervalSince($0.at) < ($0.bytes == nil ? 30 : 300) } ?? false
            if !fresh && pending[key] == nil {
                let operation = BlockOperation(), revision = generation
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard let operation, !operation.isCancelled else { return }
                    let result = try? ProjectDiskUsage.measure(project.roots, cancelled: { operation.isCancelled })
                    guard !operation.isCancelled else { return }
                    Task { @MainActor [weak self, weak operation] in
                        guard let self, self.generation == revision, let operation, self.pending[key] === operation else { return }
                        self.pending.removeValue(forKey: key)
                        self.cache[key] = Entry(bytes: result, at: Date())
                        self.onChange?()
                    }
                }
                pending[key] = operation
                queue.addOperation(operation)
            }
            if let bytes = entry?.bytes {
                values[project.id] = ["state": "ready", "bytes": bytes, "stale": !fresh]
            } else if fresh {
                values[project.id] = ["state": "error", "message": "无法完整读取目录，可能已移动、无权限或统计超时"]
            } else { values[project.id] = ["state": "pending"] }
        }
        return values
    }

    public func cancel() {
        generation += 1
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        queue.cancelAllOperations()
    }
}
