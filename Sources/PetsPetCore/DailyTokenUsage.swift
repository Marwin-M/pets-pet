import Foundation

public struct DailyTokenUsageSnapshot: Equatable {
    public let dayStart: Date
    public let dayEnd: Date
    public let timeZoneIdentifier: String
    public let input: Int64
    public let cached: Int64
    public let output: Int64
    public let isComplete: Bool
    public let fetchedAt: Date
    public var total: Int64 { input + output }

    public init?(dayStart: Date, dayEnd: Date, timeZoneIdentifier: String, input: Int64, cached: Int64, output: Int64, isComplete: Bool, fetchedAt: Date) {
        guard [dayStart, dayEnd, fetchedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              dayEnd > dayStart, TimeZone(identifier: timeZoneIdentifier) != nil,
              input >= 0, cached >= 0, cached <= input, output >= 0,
              input <= Int64.max - output else { return nil }
        self.dayStart = dayStart; self.dayEnd = dayEnd; self.timeZoneIdentifier = timeZoneIdentifier
        self.input = input; self.cached = cached; self.output = output
        self.isComplete = isComplete; self.fetchedAt = fetchedAt
    }

    public func isFresh(at now: Date, timeZone: TimeZone = .current) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let age = now.timeIntervalSince(fetchedAt)
        return age >= -5 && age < 150 && timeZoneIdentifier == timeZone.identifier
            && calendar.startOfDay(for: now) == dayStart && now < dayEnd
    }
}

public struct DailyTokenUsageMenu {
    public let title: String
    public let toolTip: String

    public init(snapshot: DailyTokenUsageSnapshot?, loading: Bool = false, at now: Date, timeZone: TimeZone = .current) {
        let date = DateFormatter()
        date.locale = Locale(identifier: "zh_CN"); date.calendar = Calendar(identifier: .gregorian)
        date.timeZone = timeZone; date.dateFormat = "yyyy-MM-dd"
        let source = "本机今日：\(date.string(from: now))（\(timeZone.identifier)），从当天 0 点起统计已记录的输入＋输出。仅覆盖本机记录，不包含其他设备或未落地的云端用量。"
        if let snapshot, snapshot.isFresh(at: now, timeZone: timeZone), snapshot.isComplete || snapshot.total > 0 {
            title = "今日 Token：\(Self.count(snapshot.total))\(snapshot.isComplete ? "" : "（部分）")"
            toolTip = "\(source)\n输入（已含缓存）：\(Self.count(snapshot.input))\n其中缓存输入：\(Self.count(snapshot.cached))\n输出（已含推理）：\(Self.count(snapshot.output))\n缓存和推理不重复相加。\(snapshot.isComplete ? "" : "\n记录不完整，当前数字仅为已确认部分，不代表全天完整用量。")"
        } else {
            let stale = snapshot.map { !$0.isFresh(at: now, timeZone: timeZone) } ?? false
            title = "今日 Token：\(loading ? "读取中…" : stale ? "等待刷新" : "暂不可用")"
            toolTip = "\(source)\n\(snapshot?.isComplete == false ? "记录不完整，暂无法确认当日用量。" : "尚无可用统计，请刷新并检查本机 Codex 记录是否可读。")不代表用量为 0。"
        }
    }

    private static func count(_ value: Int64) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
