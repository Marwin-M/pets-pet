import Foundation

public struct QuotaWindow: Codable, Equatable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(usedPercent: Double?, windowDurationMins: Int?, resetsAt: Double?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public func remaining(at now: Date) -> Int? {
        guard let usedPercent, usedPercent.isFinite,
              resetsAt == nil || resetsAt! > now.timeIntervalSince1970 else { return nil }
        return Int((100 - min(100, max(0, usedPercent))).rounded())
    }
}

public struct QuotaSnapshot: Codable, Equatable {
    public let fiveHour: QuotaWindow?
    public let weekly: QuotaWindow?
    public let fetchedAt: Date
    public let resetCredits: ResetCreditsSummary?

    public init(fiveHour: QuotaWindow?, weekly: QuotaWindow?, fetchedAt: Date, resetCredits: ResetCreditsSummary? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.resetCredits = resetCredits
    }

    public func isFresh(at now: Date) -> Bool { now.timeIntervalSince(fetchedAt) >= -5 && now.timeIntervalSince(fetchedAt) < 150 }
}

/// Only fields needed for display are retained; credit IDs and descriptions
/// are neither stored nor logged. The server count is authoritative.
public struct ResetCredit: Codable, Equatable {
    public let resetType: String
    public let status: String
    public let expiresAt: Double?
}

public struct ResetCreditsSummary: Codable, Equatable {
    public let availableCount: Int
    public let credits: [ResetCredit]?

    private enum CodingKeys: String, CodingKey { case availableCount, credits }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try values.decode(Int.self, forKey: .availableCount)
        credits = try? values.decode([ResetCredit].self, forKey: .credits)
    }

    public var available: [ResetCredit] {
        (credits ?? []).filter { $0.status == "available" && $0.resetType == "codexRateLimits" }
    }
    public var earliestExpiry: Double? {
        available.compactMap(\.expiresAt).filter { $0.isFinite && $0 > 0 }.min()
    }
    public var hasCompleteDetails: Bool {
        availableCount >= 0 && credits != nil && available.count == availableCount
    }
    public func needsRefresh(at now: Date) -> Bool {
        availableCount < 0 || (earliestExpiry.map { $0 <= now.timeIntervalSince1970 } ?? false)
    }
}

public enum QuotaParseError: Error, LocalizedError {
    case noCodexBucket, noSupportedWindows
    public var errorDescription: String? {
        switch self {
        case .noCodexBucket: return "未找到明确的 Codex 额度类型"
        case .noSupportedWindows: return "账号未提供 5 小时或周额度"
        }
    }
}

public enum QuotaParser {
    private struct Bucket: Decodable {
        let limitId: String?
        let primary: QuotaWindow?
        let secondary: QuotaWindow?
    }
    private struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let rateLimitResetCredits: ResetCreditsSummary?
        private enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitId, rateLimitResetCredits }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            rateLimits = try values.decodeIfPresent(Bucket.self, forKey: .rateLimits)
            rateLimitsByLimitId = try values.decodeIfPresent([String: Bucket].self, forKey: .rateLimitsByLimitId)
            // New optional fields must never break the established quota rings.
            rateLimitResetCredits = try? values.decode(ResetCreditsSummary.self, forKey: .rateLimitResetCredits)
        }
    }

    public static func parse(_ data: Data, at now: Date = Date()) throws -> QuotaSnapshot {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let bucket: Bucket
        if let buckets = response.rateLimitsByLimitId, !buckets.isEmpty {
            guard let codex = buckets["codex"], codex.limitId == nil || codex.limitId == "codex" else { throw QuotaParseError.noCodexBucket }
            bucket = codex
        } else {
            guard let legacy = response.rateLimits, legacy.limitId == nil || legacy.limitId == "codex" else { throw QuotaParseError.noCodexBucket }
            bucket = legacy
        }
        let windows = [bucket.primary, bucket.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.windowDurationMins == 300 }
        let weekly = windows.first { $0.windowDurationMins == 10080 }
        guard fiveHour != nil || weekly != nil else { throw QuotaParseError.noSupportedWindows }
        return QuotaSnapshot(fiveHour: fiveHour, weekly: weekly, fetchedAt: now, resetCredits: response.rateLimitResetCredits)
    }
}
