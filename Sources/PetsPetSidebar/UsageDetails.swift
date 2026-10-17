import Foundation
import CoreFoundation

public struct TokenBreakdown: Equatable, Sendable {
    public let input: Int64
    public let cached: Int64
    public let output: Int64
    public let total: Int64
    public var uncached: Int64 { input - cached }

    public init?(input: Int64, cached: Int64, output: Int64, total: Int64) {
        let limit: Int64 = 9_007_199_254_740_991
        guard [input, cached, output, total].allSatisfy({ $0 >= 0 && $0 <= limit }),
              cached <= input, input <= limit - output, input + output == total else { return nil }
        self.input = input; self.cached = cached; self.output = output; self.total = total
    }

    public var fields: [String: Int64] { ["input": input, "cached": cached, "output": output, "total": total] }

    fileprivate static func parse(_ values: [String: Any]) -> TokenBreakdown? {
        func integer(_ key: String) -> Int64? {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  value.doubleValue >= 0, value.doubleValue <= 9_007_199_254_740_991 else { return nil }
            return value.int64Value
        }
        guard let input = integer("input_tokens"), let cached = integer("cached_input_tokens"),
              let output = integer("output_tokens"), let total = integer("total_tokens") else { return nil }
        return TokenBreakdown(input: input, cached: cached, output: output, total: total)
    }
}

/// Bounded tail reads of statistical events. Chat text is not extracted or retained.
/// Cache keys include file identity, length and modification time; appends invalidate it.
public actor UsageDetailsReader {
    private struct Stamp: Equatable {
        let path: String
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private struct Entry { let stamp: Stamp; let value: TokenBreakdown? }
    private var cache: [String: Entry] = [:]
    private let home: URL
    public init(home: URL) { self.home = home.resolvingSymlinksInPath().standardizedFileURL }

    public func read(_ records: [String: LocalUsageRecord], byteBudget: Int = 8 * 1024 * 1024) -> [String: TokenBreakdown] {
        var remaining = max(0, byteBudget)
        var details: [String: TokenBreakdown] = [:]
        cache = cache.filter { records[$0.key] != nil }
        for (id, record) in records.sorted(by: { $0.key < $1.key }).prefix(2000) {
            guard let raw = record.rollout, raw.hasPrefix("/"), raw.utf8.count <= 4096 else { continue }
            let url = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
            let permitted = ["sessions", "archived_sessions"].contains {
                url.path.hasPrefix(home.appendingPathComponent($0).path + "/")
            }
            guard permitted, url.pathExtension == "jsonl",
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let modified = attrs[.modificationDate] as? Date else { continue }
            let stamp = Stamp(path: url.path, size: size, modified: modified, inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            let value: TokenBreakdown?
            if let entry = cache[id], entry.stamp == stamp { value = entry.value }
            else {
                guard remaining > 0 else { continue }
                let result = tail(url, size: size, budget: &remaining)
                value = result.value
                if result.complete { cache[id] = Entry(stamp: stamp, value: value) }
            }
            // Never mix a new total with a breakdown from an earlier record or fork.
            if let value, value.total == record.total { details[id] = value }
        }
        return details
    }

    private func tail(_ url: URL, size: UInt64, budget: inout Int) -> (value: TokenBreakdown?, complete: Bool) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return (nil, false) }
        defer { try? file.close() }
        let maximum = min(size, 4 * 1024 * 1024)
        if maximum == 0 { return (nil, true) }
        var count = min(maximum, 64 * 1024)
        while count > 0 {
            guard budget >= Int(count) else { return (nil, false) }
            budget -= Int(count)
            do {
                try file.seek(toOffset: size - count)
                let bytes = try file.read(upToCount: Int(count)) ?? Data()
                guard bytes.count == Int(count) else { return (nil, false) }
                // Ignore both a partial leading line and an unfinished final write.
                var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
                if count < size && !lines.isEmpty { lines.removeFirst() }
                if bytes.last != 10 && !lines.isEmpty { lines.removeLast() }
                for line in lines.reversed() where line.count <= 65536 {
                    guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                          let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          event["type"] as? String == "event_msg",
                          let payload = event["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any] else { continue }
                    guard let values = info["total_token_usage"] as? [String: Any] else { return (nil, true) }
                    return (TokenBreakdown.parse(values), true)
                }
            } catch { return (nil, false) }
            if count == maximum { return (nil, true) }
            count = min(maximum, count * 2)
        }
        return (nil, true)
    }
}
