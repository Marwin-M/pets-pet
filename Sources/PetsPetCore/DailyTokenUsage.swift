import Foundation

public struct DailyTokenUsageSnapshot: Equatable {
    public let buckets: [String: Int64]
    public let fetchedAt: Date

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= -5 && age < 150
    }
}

public enum DailyTokenUsageParser {
    private struct Response: Decodable {
        struct Bucket: Decodable { let startDate: String; let tokens: Int64 }
        let dailyUsageBuckets: [Bucket]?
    }

    public static func parse(_ data: Data, at now: Date = Date()) throws -> DailyTokenUsageSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var buckets: [String: Int64] = [:]
        let formatter = DailyTokenUsageMenu.dateFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
        for bucket in response.dailyUsageBuckets ?? [] {
            // Reject ambiguous totals instead of summing duplicate dates or accepting bad dates.
            guard bucket.startDate.utf8.count == 10,
                  let date = formatter.date(from: bucket.startDate),
                  formatter.string(from: date) == bucket.startDate,
                  bucket.tokens >= 0, buckets[bucket.startDate] == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid daily usage bucket"))
            }
            buckets[bucket.startDate] = bucket.tokens
        }
        return DailyTokenUsageSnapshot(buckets: buckets, fetchedAt: now)
    }
}

public struct DailyTokenUsageMenu {
    public let title: String
    public let toolTip: String

    public init(snapshot: DailyTokenUsageSnapshot?, loading: Bool = false, at now: Date, timeZone: TimeZone = .current) {
        let date = Self.dateFormatter(timeZone: timeZone).string(from: now)
        let source = "官方统计日：\(date)。以 Codex 官方每日统计为准，可能存在延迟；官方未说明日界线时区。"
        if let snapshot, snapshot.isFresh(at: now), let tokens = snapshot.buckets[date] {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            let count = formatter.string(from: NSNumber(value: tokens)) ?? String(tokens)
            title = "今日 Token：\(count)"
            toolTip = "账号每日 Token 总量：\(count)。\n\(source)"
        } else {
            let stale = snapshot.map { !$0.isFresh(at: now) } ?? false
            title = "今日 Token：\(loading ? "读取中…" : stale ? "等待刷新" : "暂不可用")"
            toolTip = "\(source)\n尚无可用的当日统计，不代表用量为 0；可尝试刷新或检查 Codex 登录状态。"
        }
    }

    static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
