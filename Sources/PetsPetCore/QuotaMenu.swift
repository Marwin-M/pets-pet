import Foundation

public enum QuotaMenu {
    public static func rows(snapshot: QuotaSnapshot?, mode: QuotaDisplayMode = .automatic, dailyUsage: DailyTokenUsageSnapshot? = nil, dailyLoading: Bool = false, at now: Date, timeZone: TimeZone = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        let fresh = snapshot?.isFresh(at: now) == true
        let showsCountdown = mode.resolved(for: snapshot) == .countdown
        var rows: [String] = []
        if showsCountdown {
            if let countdown = snapshot?.countdown(at: now) {
                rows.append("D 距周额度重置 \(countdown.daysText) 天")
            } else if !fresh {
                rows.append("D 距周额度重置 -- · 等待刷新")
            } else if let reset = snapshot?.weekly?.resetsAt, reset.isFinite, reset <= now.timeIntervalSince1970 {
                rows.append("D 已到重置时间，等待刷新")
            } else { rows.append("D 距周额度重置 -- · 重置时间未提供或无效") }
        }
        let windows = showsCountdown ? [("W", snapshot?.weekly)] : [("5H", snapshot?.fiveHour), ("W", snapshot?.weekly)]
        for (name, window) in windows {
            if name == "5H", fresh, window == nil {
                rows.append("5H 剩余 -- · 该账号未提供 5 小时额度")
                continue
            }
            let remaining = fresh ? window?.remaining(at: now).map { "\($0)%" } ?? "--" : "--"
            let reset: String
            if snapshot != nil && !fresh { reset = "等待刷新" }
            else if let seconds = window?.resetsAt, seconds.isFinite {
                reset = seconds > now.timeIntervalSince1970 ? formatter.string(from: Date(timeIntervalSince1970: seconds)) : "已到重置时间，等待刷新"
            } else { reset = "未提供" }
            rows.append("\(name) 剩余 \(remaining) · 重置 \(reset)")
        }
        rows.append(DailyTokenUsageMenu(snapshot: dailyUsage, loading: dailyLoading, at: now, timeZone: timeZone).title)
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
