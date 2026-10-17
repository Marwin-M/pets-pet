import Foundation

public enum QuotaDisplayMode: String, CaseIterable {
    case automatic, quota, countdown

    public static let defaultsKey = "quotaDisplayMode"

    public init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .automatic }

    public var title: String {
        switch self {
        case .automatic: return "自动（按可用额度）"
        case .quota: return "5H＋W 剩余额度"
        case .countdown: return "重置倒计时＋W 剩余额度"
        }
    }

    public func resolved(for snapshot: QuotaSnapshot?) -> QuotaDisplayMode {
        guard self == .automatic else { return self }
        // Presence of a window is independent of its current percentage and the plan.
        // Retain the last known layout while data is stale; values still become unknown.
        return snapshot?.fiveHour == nil && snapshot?.weekly != nil ? .countdown : .quota
    }
}
