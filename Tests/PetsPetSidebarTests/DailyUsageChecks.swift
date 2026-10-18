import Foundation
import SQLite3
import PetsPetSidebar

/// Real read-only SQLite and append-only JSONL fixtures; no application launch.
struct DailyUsageChecks {
    private final class Fixture {
        let home: URL
        let db: URL
        let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        init(_ root: URL) throws {
            home = root.appendingPathComponent(UUID().uuidString)
            db = home.appendingPathComponent("state_5.sqlite")
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try sql("CREATE TABLE threads (id TEXT, rollout_path TEXT, tokens_used INTEGER, updated_at INTEGER)")
        }
        func sql(_ text: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(db.path, &handle) == SQLITE_OK else { throw SidebarError.database }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw SidebarError.database }
        }
        func file(_ data: Data, total: Int64, path: URL? = nil) throws -> URL {
            let url = path ?? home.appendingPathComponent("sessions/" + UUID().uuidString + ".jsonl")
            let id = UUID().uuidString
            var header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "session_id": id, "timestamp": "2026-10-16T00:00:00Z"]])
            header.append(10)
            let hasHeader = data.prefix(256).range(of: Data("\"session_meta\"".utf8)) != nil
            try (hasHeader ? data : header + data).write(to: url)
            try sql("INSERT INTO threads VALUES ('\(UUID().uuidString)', '\(url.path.replacingOccurrences(of: "'", with: "''"))', \(total), \(Int(now.timeIntervalSince1970)))")
            return url
        }
    }
    private static func event(_ date: String, input: Int64, cached: Int64, output: Int64, lastInput: Int64? = nil, lastCached: Int64? = nil, lastOutput: Int64? = nil) throws -> Data {
        func usage(_ i: Int64, _ c: Int64, _ o: Int64) -> [String: Int64] {
            ["input_tokens": i, "cached_input_tokens": c, "output_tokens": o, "total_tokens": i + o, "reasoning_output_tokens": o]
        }
        let value: [String: Any] = ["timestamp": date, "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": usage(input, cached, output), "last_token_usage": usage(lastInput ?? input, lastCached ?? cached, lastOutput ?? output)]]]
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); return data
    }
    static func run(root: URL) async throws -> Int {
        var count = 0
        func expect(_ value: Bool, _ message: String) throws {
            count += 1
            if !value { throw NSError(domain: "DailyUsageChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let before = "2026-10-16T15:59:00Z", first = "2026-10-16T16:01:00Z", next = "2026-10-17T10:00:00.100Z"
        let f = try Fixture(root)
        let baseline = try event(before, input: 100, cached: 60, output: 20)
        let today = try event(first, input: 160, cached: 100, output: 30, lastInput: 60, lastCached: 40, lastOutput: 10)
        let more = try event(next, input: 200, cached: 120, output: 40, lastInput: 40, lastCached: 20, lastOutput: 10)
        let file = try f.file(baseline + today + today + more, total: 240)
        let reader = LocalDailyUsageReader(home: f.home)
        let initial = try await reader.read(at: f.now, timeZone: f.zone)
        try expect(initial.usage.total == 120 && initial.usage.input == 100 && initial.usage.cached == 60 && initial.usage.output == 20, "today uses cumulative differences; cache and reasoning are already subsets")
        try expect(initial.isComplete, "valid midnight baseline gives complete result")
        let cached = try await reader.read(at: f.now, timeZone: f.zone)
        try expect(cached.bytesRead == 0 && cached.filesRead == 0 && cached.usage == initial.usage, "unchanged files are not rescanned")
        let append = try event("2026-10-17T11:00:00Z", input: 250, cached: 140, output: 50, lastInput: 50, lastCached: 20, lastOutput: 10)
        let writer = try FileHandle(forWritingTo: file); try writer.seekToEnd(); try writer.write(contentsOf: append); try writer.close()
        let grown = try await reader.read(at: f.now, timeZone: f.zone)
        try expect(grown.usage.total == 180 && grown.isComplete, "appended data is counted once")
        try expect(grown.bytesRead < initial.bytesRead + append.count + 2048, "append scan is bounded to new bytes and small anchors")
        // A second thread containing copied statistical history cannot multiply usage.
        _ = try f.file(Data(contentsOf: file), total: 300)
        let copied = try await reader.read(at: f.now, timeZone: f.zone)
        try expect(copied.usage.total == grown.usage.total, "copied histories and repeated events are deduplicated")
        // Same inode, longer rewrite: the saved boundary hash invalidates its old counters.
        let replacement = try event(first, input: 500, cached: 250, output: 100)
        try (replacement + Data(repeating: 32, count: 1000) + Data([10])).write(to: file)
        let rewritten = try await reader.read(at: f.now, timeZone: f.zone)
        try expect(rewritten.usage.total == 780, "rewrite invalidation replaces rather than adds old contributions")
        let changedZone = try await reader.read(at: f.now, timeZone: TimeZone(secondsFromGMT: 0)!)
        try expect(changedZone.isComplete && changedZone.usage.total == 110, "system timezone changes rebuild the calendar-day cache")
        let tomorrow = try await reader.read(at: f.now.addingTimeInterval(86400), timeZone: f.zone)
        try expect(tomorrow.usage.total == 0 && tomorrow.isComplete, "calendar day rollover clears old contributions")

        let concurrent = try Fixture(root)
        let identical = try event(first, input: 100, cached: 80, output: 20)
        _ = try concurrent.file(identical, total: 120)
        _ = try concurrent.file(identical, total: 120)
        let originalDB = try Data(contentsOf: concurrent.db)
        let independent = try await LocalDailyUsageReader(home: concurrent.home).read(at: f.now, timeZone: f.zone)
        try expect(independent.isComplete && independent.usage.total == 240, "independent sessions with identical time and counters both count")
        try expect(try Data(contentsOf: concurrent.db) == originalDB, "daily reader does not change SQLite data")

        let fork = try Fixture(root)
        _ = try fork.file(baseline + today + more, total: 240)
        let childID = UUID().uuidString
        var childHeader = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["session_id": childID, "timestamp": "2026-10-17T11:30:00Z"]])
        childHeader.append(10)
        let childRequest = try event("2026-10-17T11:45:00Z", input: 250, cached: 140, output: 50, lastInput: 50, lastCached: 20, lastOutput: 10)
        _ = try fork.file(childHeader + baseline + today + more + childRequest, total: 300)
        let forkResult = try await LocalDailyUsageReader(home: fork.home).read(at: f.now, timeZone: f.zone)
        try expect(forkResult.isComplete && forkResult.usage.total == 180, "a new fork identity does not count inherited pre-creation statistics again")

        let repeatMidnight = try Fixture(root)
        let repeated = try event(first, input: 100, cached: 60, output: 20)
        _ = try repeatMidnight.file(baseline + repeated + today, total: 190)
        let repeatResult = try await LocalDailyUsageReader(home: repeatMidnight.home).read(at: f.now, timeZone: f.zone)
        try expect(repeatResult.isComplete && repeatResult.usage.total == 70, "unchanged counters after midnight do not count yesterday's last request again")

        let replay = try Fixture(root)
        let requestA = try event(first, input: 100, cached: 0, output: 0)
        let requestB = try event(next, input: 200, cached: 0, output: 0, lastInput: 100)
        let requestC = try event("2026-10-17T11:00:00Z", input: 300, cached: 0, output: 0, lastInput: 100)
        let replayFile = try replay.file(requestA + requestB + requestA + requestC, total: 300)
        let replayReader = LocalDailyUsageReader(home: replay.home)
        let replayResult = try await replayReader.read(at: f.now, timeZone: f.zone)
        try expect(replayResult.isComplete && replayResult.usage.total == 300, "non-adjacent duplicates do not rewind the cumulative baseline or inflate the next delta")
        let replayWriter = try FileHandle(forWritingTo: replayFile)
        try replayWriter.seekToEnd()
        try replayWriter.write(contentsOf: requestB + (try event("2026-10-17T11:30:00Z", input: 400, cached: 0, output: 0, lastInput: 100)))
        try replayWriter.close()
        let replayAppend = try await replayReader.read(at: f.now, timeZone: f.zone)
        try expect(replayAppend.isComplete && replayAppend.usage.total == 400, "duplicate recognition survives incremental appends")
        let replayCached = try await replayReader.read(at: f.now, timeZone: f.zone)
        try expect(replayCached.bytesRead == 0 && replayCached.usage.total == 400, "deduplicated results remain cached without rescanning unchanged files")

        let unordered = try Fixture(root)
        let delayed = try event("2026-10-17T09:00:00Z", input: 150, cached: 0, output: 0, lastInput: 50)
        _ = try unordered.file(requestA + requestB + delayed + requestC, total: 300)
        let unorderedResult = try await LocalDailyUsageReader(home: unordered.home).read(at: f.now, timeZone: f.zone)
        try expect(!unorderedResult.isComplete && unorderedResult.usage.total == 300, "unseen out-of-order events mark partial coverage without replacing a newer baseline")

        let rollback = try Fixture(root)
        let restarted = try event(next, input: 20, cached: 0, output: 0)
        _ = try rollback.file(requestA + restarted + requestA + (try event("2026-10-17T11:00:00Z", input: 40, cached: 0, output: 0, lastInput: 20)), total: 40)
        let rollbackResult = try await LocalDailyUsageReader(home: rollback.home).read(at: f.now, timeZone: f.zone)
        try expect(!rollbackResult.isComplete && rollbackResult.usage.total == 140, "counter rollback is partial even when its first request is valid; older duplicates cannot replace the new baseline")

        let partial = try Fixture(root)
        let incompleteLine = try event(first, input: 100, cached: 80, output: 20)
        let pending = try partial.file(Data(incompleteLine.dropLast()), total: 120)
        let partialReader = LocalDailyUsageReader(home: partial.home)
        let unfinished = try await partialReader.read(at: partial.now, timeZone: partial.zone)
        try expect(unfinished.usage.total == 0 && !unfinished.isComplete, "unfinished writes are unknown, not zero usage")
        let finish = try FileHandle(forWritingTo: pending); try finish.seekToEnd(); try finish.write(contentsOf: Data([10])); try finish.close()
        let finished = try await partialReader.read(at: partial.now, timeZone: partial.zone)
        try expect(finished.usage.total == 120 && finished.isComplete, "only complete lines are committed to the incremental cache")
        let limitedReader = LocalDailyUsageReader(home: partial.home)
        let limited = try await limitedReader.read(at: partial.now, timeZone: partial.zone, byteBudget: 1)
        try expect(!limited.isComplete, "budget exhaustion reports partial coverage")
        let resumed = try await limitedReader.read(at: partial.now, timeZone: partial.zone)
        try expect(resumed.isComplete && resumed.usage.total == 120, "later reads resume safely after a bounded scan")
        try FileManager.default.removeItem(at: pending)
        let deleted = try await partialReader.read(at: partial.now, timeZone: partial.zone)
        try expect(!deleted.isComplete && deleted.usage.total == 0, "missing active statistics never produce a complete zero")

        let ambiguity = try Fixture(root)
        _ = try ambiguity.file(try event(first, input: 10000, cached: 9000, output: 1000, lastInput: 100, lastCached: 80, lastOutput: 20), total: 11000)
        let ambiguous = try await LocalDailyUsageReader(home: ambiguity.home).read(at: ambiguity.now, timeZone: ambiguity.zone)
        try expect(!ambiguous.isComplete && ambiguous.usage.total == 0, "unknown initial baseline does not assign lifetime totals or a carried-forward last request to today")
        let gap = try Fixture(root)
        _ = try gap.file(baseline + (try event(first, input: 1000, cached: 600, output: 200, lastInput: 50, lastCached: 30, lastOutput: 10)), total: 1200)
        let gapResult = try await LocalDailyUsageReader(home: gap.home).read(at: gap.now, timeZone: gap.zone)
        try expect(!gapResult.isComplete && gapResult.usage.total == 60, "missing events spanning midnight only count the confirmed latest request")
        let resets = try Fixture(root)
        let reset = try event(next, input: 20, cached: 10, output: 5)
        _ = try resets.file(today + reset, total: 25)
        let resetResult = try await LocalDailyUsageReader(home: resets.home).read(at: resets.now, timeZone: resets.zone)
        try expect(!resetResult.isComplete && resetResult.usage.total == 25, "counter restarts do not subtract or re-add lifetime usage")

        let invalid = try Fixture(root)
        let bad = Data(#"{"timestamp":"2026-10-17T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":-1,"cached_input_tokens":0,"output_tokens":0,"total_tokens":-1}}}}"#.utf8) + Data([10])
        _ = try invalid.file(bad, total: 10)
        let invalidResult = try await LocalDailyUsageReader(home: invalid.home).read(at: invalid.now, timeZone: invalid.zone)
        try expect(!invalidResult.isComplete && invalidResult.usage.total == 0, "invalid counters cannot masquerade as valid zero")
        let outside = try Fixture(root)
        _ = try outside.file(incompleteLine, total: 120, path: outside.home.deletingLastPathComponent().appendingPathComponent("outside.jsonl"))
        let outsideResult = try await LocalDailyUsageReader(home: outside.home).read(at: outside.now, timeZone: outside.zone)
        try expect(!outsideResult.isComplete && outsideResult.bytesRead == 0, "paths outside local session roots are never read")
        let empty = try Fixture(root)
        let zero = try await LocalDailyUsageReader(home: empty.home).read(at: empty.now, timeZone: empty.zone)
        try expect(zero.isComplete && zero.usage.total == 0, "successful empty local database has known zero")
        let missingHome = root.appendingPathComponent("missing-daily-home")
        var missingFailed = false
        do { _ = try await LocalDailyUsageReader(home: missingHome).read(at: empty.now) }
        catch { missingFailed = true }
        try expect(missingFailed && !FileManager.default.fileExists(atPath: missingHome.path), "missing database throws and is never created")
        let badDate = try Fixture(root)
        _ = try badDate.file(try event("not-a-date", input: 1, cached: 0, output: 1), total: 2)
        let badDateResult = try await LocalDailyUsageReader(home: badDate.home).read(at: f.now, timeZone: f.zone)
        try expect(!badDateResult.isComplete && badDateResult.usage.total == 0, "malformed dates do not become valid zero")
        let dst = try await LocalDailyUsageReader(home: empty.home).read(at: ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z")!, timeZone: TimeZone(identifier: "America/New_York")!)
        try expect(dst.dayEnd.timeIntervalSince(dst.dayStart) == 23 * 3600, "daylight-saving day boundaries use the calendar")
        let cancel = Task { () throws -> LocalDailyUsage in
            while !Task.isCancelled { await Task.yield() }
            return try await LocalDailyUsageReader(home: f.home).read(at: f.now)
        }
        cancel.cancel()
        do { _ = try await cancel.value; try expect(false, "cancelled read must stop") }
        catch is CancellationError { try expect(true, "read responds to cancellation") }
        print("Local daily usage checks passed: \(count) assertions (real SQLite/JSONL, incremental reads, no message extraction).")
        return count
    }
}
