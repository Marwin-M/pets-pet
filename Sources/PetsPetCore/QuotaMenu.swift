import Foundation

public enum QuotaMenu {
    public static func rows(snapshot: QuotaSnapshot?, at now: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        let fresh = snapshot?.isFresh(at: now) == true
        var rows: [String] = []
        for (name, window) in [("5H", snapshot?.fiveHour), ("W", snapshot?.weekly)] {
            let remaining = fresh ? window?.remaining(at: now).map { "\($0)%" } ?? "--" : "--"
            let reset: String
            if snapshot != nil && !fresh { reset = "等待刷新" }
            else if let seconds = window?.resetsAt, seconds.isFinite {
                reset = seconds > now.timeIntervalSince1970 ? formatter.string(from: Date(timeIntervalSince1970: seconds)) : "已到重置时间，等待刷新"
            } else { reset = "未提供" }
            rows.append("\(name) 剩余 \(remaining) · 重置 \(reset)")
        }
        guard let snapshot else { return rows + ["重置卡：暂不可用", "最近到期：未提供"] }
        guard fresh else { return rows + ["重置卡：等待刷新", "最近到期：等待刷新"] }
        guard let cards = snapshot.resetCredits, cards.availableCount >= 0 else {
            return rows + ["重置卡：暂不可用", "最近到期：未提供"]
        }
        if cards.availableCount == 0 { return rows + ["重置卡：0 张", "最近到期：—"] }
        if cards.needsRefresh(at: now) { return rows + ["重置卡：等待刷新", "最近到期：已到期，等待刷新"] }
        rows.append("重置卡：\(cards.availableCount) 张")
        if let expiry = cards.earliestExpiry {
            rows.append("\(cards.hasCompleteDetails ? "最近到期" : "已知最近到期")：\(formatter.string(from: Date(timeIntervalSince1970: expiry)))")
        } else if cards.hasCompleteDetails && cards.available.allSatisfy({ $0.expiresAt == nil }) {
            rows.append("最近到期：无到期限制")
        } else { rows.append("最近到期：未提供") }
        return rows
    }
}
