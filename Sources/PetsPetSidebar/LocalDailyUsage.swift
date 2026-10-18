import Foundation
import SQLite3
import CryptoKit

public struct LocalDailyUsage: Sendable {
    public let dayStart: Date
    public let dayEnd: Date
    public let timeZoneIdentifier: String
    public let usage: TokenBreakdown
    public let isComplete: Bool
    public let fetchedAt: Date
    /// Diagnostic counters contain no paths, account identifiers or message text.
    public let bytesRead: Int
    public let filesRead: Int
}

/// Only statistical events and session identity are decoded. Cache offsets, hashes and counters,
/// never message text. Initial scans are bounded; subsequent reads follow appends.
public actor LocalDailyUsageReader {
    private struct Record { let path: String?; let total: Int64?; let active: Bool }
    private struct Fingerprint: Hashable {
        let origin: String
        let timestamp: Date
        let input: Int64
        let cached: Int64
        let output: Int64
    }
    private struct Contribution { let key: Fingerprint; let usage: TokenBreakdown }
    private struct Entry {
        var inode: UInt64 = 0
        var size: UInt64 = 0
        var modified = Date.distantPast
        var offset: UInt64 = 0
        var anchor = Data()
        var origin: String?
        var originBeganAt: Date?
        var previous: TokenBreakdown?
        var previousDate: Date?
        var events: [Contribution] = []
        var uncertain = false
        var pending = false
    }
    private let home: URL
    private var dayStart: Date?
    private var timeZoneIdentifier = ""
    private var entries: [String: Entry] = [:]
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()

    public init(home: URL = LocalUsageReader().home) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func read(at now: Date = Date(), timeZone: TimeZone = .current, byteBudget: Int = 512 * 1024 * 1024) throws -> LocalDailyUsage {
        try Task.checkCancellation()
        guard now.timeIntervalSince1970.isFinite else { throw SidebarError.protocolError }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw SidebarError.protocolError }
        if dayStart != start || timeZoneIdentifier != timeZone.identifier {
            entries.removeAll(); dayStart = start; timeZoneIdentifier = timeZone.identifier
        }
        let records = try records(since: start)
        var complete = true, remaining = max(0, byteBudget), bytes = 0, files = 0
        var retained: [String: Entry] = [:]
        let deadline = Date().addingTimeInterval(8)
        for record in records {
            try Task.checkCancellation()
            if record.active && record.total == nil { complete = false }
            guard let raw = record.path, raw.hasPrefix("/"), raw.utf8.count <= 4096 else {
                if record.active && record.total != 0 { complete = false }; continue
            }
            let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
            guard url.pathExtension == "jsonl", ["sessions", "archived_sessions"].contains(where: { url.path.hasPrefix(home.appendingPathComponent($0).path + "/") }) else {
                if record.active && record.total != 0 { complete = false }; continue
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value, let modified = attrs[.modificationDate] as? Date else {
                if record.active && record.total != 0 { complete = false }; continue
            }
            let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            guard record.active || modified >= start || entries[url.path] != nil else { continue }
            // Multiple DB entries and aliases may point at the same rollout.
            if retained[url.path] != nil { continue }
            do {
                var entry = entries[url.path] ?? Entry()
                if entry.inode != inode || size < entry.offset || (size == entry.size && modified != entry.modified) { entry = Entry() }
                if size != entry.size || modified != entry.modified || entry.offset < size {
                    guard remaining > 0, Date() < deadline else { complete = false; retained[url.path] = entry; continue }
                    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
                    if entry.offset > 0 {
                        let length = min(entry.offset, 1024)
                        try file.seek(toOffset: entry.offset - length)
                        let anchor = try file.read(upToCount: Int(length)) ?? Data()
                        bytes += anchor.count; remaining -= anchor.count
                        if Data(SHA256.hash(data: anchor)) != entry.anchor { entry = Entry() }
                    }
                    try file.seek(toOffset: entry.offset)
                    files += 1
                    var position = entry.offset, lineStart = position, line = Data(), oversized = false
                    while position < size && remaining > 0 && Date() < deadline {
                        try Task.checkCancellation()
                        let amount = min(256 * 1024, min(Int(size - position), remaining))
                        let chunk = try file.read(upToCount: amount) ?? Data()
                        if chunk.isEmpty { break }
                        bytes += chunk.count; remaining -= chunk.count
                        var cursor = chunk.startIndex
                        while cursor < chunk.endIndex {
                            let newline = chunk.range(of: Data([10]), options: [], in: cursor..<chunk.endIndex)?.lowerBound
                            let boundary = newline ?? chunk.endIndex
                            let length = chunk.distance(from: cursor, to: boundary)
                            if !oversized {
                                let keep = min(length, 65536 - line.count)
                                line.append(chunk[cursor..<chunk.index(cursor, offsetBy: keep)])
                                oversized = keep < length
                            }
                            position += UInt64(length)
                            if let newline {
                                position += 1
                                if !oversized { consume(line, entry: &entry, scope: url.path, start: start, end: end, now: now) }
                                else if statisticalPrefix(line) { entry.uncertain = true }
                                line.removeAll(keepingCapacity: true); oversized = false
                                entry.offset = position; lineStart = position
                                cursor = chunk.index(after: newline)
                            } else { cursor = chunk.endIndex }
                        }
                    }
                    entry.pending = position < size || position != lineStart
                    if entry.offset > 0 {
                        let length = min(entry.offset, 1024)
                        try file.seek(toOffset: entry.offset - length)
                        let anchor = try file.read(upToCount: Int(length)) ?? Data()
                        bytes += anchor.count; remaining -= anchor.count
                        entry.anchor = Data(SHA256.hash(data: anchor))
                    }
                    entry.inode = inode; entry.size = size; entry.modified = modified
                }
                if entry.pending || entry.uncertain { complete = false }
                // A positive DB counter without a matching statistical baseline is unknown.
                if record.active, let total = record.total, total > (entry.previous?.total ?? 0) { complete = false }
                retained[url.path] = entry
            } catch is CancellationError { throw CancellationError() }
            catch { complete = false }
        }
        entries = retained
        var unique: [Fingerprint: TokenBreakdown] = [:]
        for entry in entries.values {
            for event in entry.events {
                if let previous = unique[event.key] {
                    // Copied histories must not multiply usage. Conflicting baselines
                    // have no reliable exact total, so retain the smaller known part.
                    if previous != event.usage {
                        complete = false
                        if event.usage.total < previous.total { unique[event.key] = event.usage }
                    }
                } else { unique[event.key] = event.usage }
            }
        }
        var input: Int64 = 0, cached: Int64 = 0, output: Int64 = 0
        for usage in unique.values {
            for (left, right) in [(input, usage.input), (cached, usage.cached), (output, usage.output)] {
                guard left <= 9_007_199_254_740_991 - right else { throw SidebarError.protocolError }
            }
            input += usage.input; cached += usage.cached; output += usage.output
        }
        guard let usage = TokenBreakdown(input: input, cached: cached, output: output, total: input + output) else { throw SidebarError.protocolError }
        return LocalDailyUsage(dayStart: start, dayEnd: end, timeZoneIdentifier: timeZone.identifier, usage: usage, isComplete: complete, fetchedAt: now, bytesRead: bytes, filesRead: files)
    }

    private func statisticalPrefix(_ line: Data) -> Bool {
        let prefix = line.prefix(256)
        return prefix.range(of: Data("\"event_msg\"".utf8)) != nil
            && (prefix.range(of: Data("\"token_count\"".utf8)) != nil || prefix.range(of: Data("\"token_usage_record\"".utf8)) != nil)
    }

    private func consume(_ line: Data, entry: inout Entry, scope: String, start: Date, end: Date, now: Date) {
        if line.range(of: Data("\"session_meta\"".utf8)) != nil,
           let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], event["type"] as? String == "session_meta",
           let payload = event["payload"] as? [String: Any] {
            let raw = payload["session_id"] as? String ?? payload["id"] as? String
            entry.origin = raw.flatMap { UUID(uuidString: $0)?.uuidString }
            let stamp = payload["timestamp"] as? String ?? event["timestamp"] as? String
            entry.originBeganAt = stamp.flatMap { fractional.date(from: $0) ?? whole.date(from: $0) }
            if payload["history_base"] != nil && entry.originBeganAt == nil { entry.uncertain = true }
            return
        }
        guard line.range(of: Data("\"token_count\"".utf8)) != nil || line.range(of: Data("\"token_usage_record\"".utf8)) != nil else { return }
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            if statisticalPrefix(line) { entry.uncertain = true; entry.previous = nil }; return
        }
        guard event["type"] as? String == "event_msg", let payload = event["payload"] as? [String: Any] else { return }
        guard let type = payload["type"] as? String, type == "token_count" || type == "token_usage_record" else { return }
        guard let stamp = event["timestamp"] as? String, let date = fractional.date(from: stamp) ?? whole.date(from: stamp) else { entry.uncertain = true; entry.previous = nil; return }
        let today = date >= start && date < end && (entry.originBeganAt.map { date >= $0 } ?? true)
        guard type == "token_count" else { if today { entry.uncertain = true }; return }
        guard let info = payload["info"] as? [String: Any] else { return } // Rate-limit-only notifications.
        guard let raw = info["total_token_usage"] as? [String: Any], let total = TokenBreakdown.parse(raw) else {
            if today { entry.uncertain = true }; entry.previous = nil; return
        }
        let last = (info["last_token_usage"] as? [String: Any]).flatMap(TokenBreakdown.parse)
        var delta: TokenBreakdown?
        if let previous = entry.previous, let previousDate = entry.previousDate,
           date >= previousDate, total.input >= previous.input, total.cached >= previous.cached, total.output >= previous.output {
            delta = TokenBreakdown(input: total.input - previous.input, cached: total.cached - previous.cached, output: total.output - previous.output, total: total.total - previous.total)
            if today && previousDate < start && (delta?.total ?? 0) > 0 && delta != last {
                if let last, let difference = delta, last.input <= difference.input, last.cached <= difference.cached, last.output <= difference.output { delta = last }
                else { delta = nil }
                entry.uncertain = true // A gap straddling midnight cannot all be assigned to today.
            }
        } else {
            // Without a baseline, a carried-forward last request may belong to
            // yesterday. Start from the first known counter instead of guessing.
            if total == last { delta = total }
            else if total.total == 0 { delta = total }
            else if today { entry.uncertain = true }
        }
        entry.previous = total; entry.previousDate = date
        guard today else { return }
        guard date <= now.addingTimeInterval(5), let delta else { entry.uncertain = true; return }
        guard delta.total > 0 else { return }
        if entry.origin == nil { entry.uncertain = true }
        let key = Fingerprint(origin: entry.origin ?? scope, timestamp: date, input: total.input, cached: total.cached, output: total.output)
        entry.events.append(Contribution(key: key, usage: delta))
    }

    private func records(since start: Date) throws -> [Record] {
        let urls = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let newest = urls.compactMap { url -> (URL, Int)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let number = Int(name.dropFirst(6).dropLast(7)), number >= 0 else { return nil }
            return (url, number)
        }.max { $0.1 < $1.1 }?.0
        guard let newest else { throw SidebarError.database }
        var db: OpaquePointer?
        guard sqlite3_open_v2(newest.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw SidebarError.database
        }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path, tokens_used, updated_at FROM threads ORDER BY updated_at DESC", -1, &statement, nil) == SQLITE_OK else { throw SidebarError.database }
        defer { sqlite3_finalize(statement) }
        var result: [Record] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, result.count < 10000 else { throw SidebarError.database }
            let path = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            let total = sqlite3_column_type(statement, 1) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 1) : nil
            guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { throw SidebarError.database }
            let active = Double(sqlite3_column_int64(statement, 2)) >= start.timeIntervalSince1970
            result.append(Record(path: path, total: total.flatMap { $0 >= 0 ? $0 : nil }, active: active))
        }
    }
}
