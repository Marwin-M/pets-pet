import Foundation
import SQLite3

public enum SidebarError: Error {
    case database, protocolError, disconnected, timeout, cancelled, directory
}

public struct LocalUsageRecord: Sendable {
    public let total: Int64
    public let rollout: String?
    public init(total: Int64, rollout: String?) { self.total = total; self.rollout = rollout }
}

/// Read usage counters and their local statistics-file location, never credentials.
public struct LocalUsageReader: Sendable {
    public let home: URL
    public init(home: URL = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")) { self.home = home }

    public func read(_ ids: [String]) throws -> [String: Int64] {
        try records(ids).mapValues(\.total)
    }

    public func records(_ ids: [String]) throws -> [String: LocalUsageRecord] {
        let ids = Array(Set(ids.filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() })).prefix(2000)
        guard !ids.isEmpty else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let versions = files.compactMap { url -> (URL, Int)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)), version >= 0 else { return nil }
            return (url, version)
        }
        // A newer schema is authoritative. Do not silently show an old database.
        guard let file = versions.max(by: { $0.1 < $1.1 })?.0 else { throw SidebarError.database }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw SidebarError.database
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let all = Array(ids)
        var totals: [String: LocalUsageRecord] = [:]
        for start in stride(from: 0, to: all.count, by: 200) {
            let chunk = Array(all[start..<min(start + 200, all.count)])
            let suffix = " FROM threads WHERE id IN (\(Array(repeating: "?", count: chunk.count).joined(separator: ",")))"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, tokens_used, rollout_path" + suffix, -1, &statement, nil) != SQLITE_OK {
                // Older schemas may expose a total without detailed local records.
                sqlite3_finalize(statement); statement = nil
                guard sqlite3_prepare_v2(db, "SELECT id, tokens_used, NULL" + suffix, -1, &statement, nil) == SQLITE_OK else { throw SidebarError.database }
            }
            defer { sqlite3_finalize(statement) }
            for (index, id) in chunk.enumerated() {
                let bound = id.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                guard bound == SQLITE_OK else { throw SidebarError.database }
            }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw SidebarError.database }
                guard let raw = sqlite3_column_text(statement, 0), sqlite3_column_type(statement, 1) == SQLITE_INTEGER else { continue }
                let total = sqlite3_column_int64(statement, 1)
                if total >= 0 && total <= 9_007_199_254_740_991 {
                    let path = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                    totals[String(cString: raw)] = LocalUsageRecord(total: total, rollout: path)
                }
            }
        }
        return totals
    }
}
