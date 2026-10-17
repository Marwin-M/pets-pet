import Foundation

/// Motion events temporarily enable a 60 Hz position reader. No fast timer is
/// needed between gestures; the 1 Hz discovery loop provides idle updates.
public struct TrackingCadence {
    public static let idleInterval: TimeInterval = 1
    public static let frameInterval: TimeInterval = 1.0 / 60
    public static let inputLifetime: TimeInterval = 2
    private var fastUntil: TimeInterval = 0

    public init() {}

    public mutating func moved(at time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        fastUntil = max(fastUntil, time + 0.15)
    }

    public mutating func released(at time: TimeInterval) {
        guard time.isFinite, time >= 0 else { return }
        fastUntil = max(fastUntil, time + 0.2)
    }

    public func isFast(at time: TimeInterval) -> Bool { time.isFinite && time >= 0 && time < fastUntil }

    public static func isFresh(observedAt: TimeInterval, now: TimeInterval) -> Bool {
        observedAt.isFinite && observedAt >= 0 && now.isFinite && now >= observedAt && now - observedAt <= inputLifetime
    }

    public mutating func reset() { fastUntil = 0 }
}
