import Foundation

/// A slow consumer receives the newest value, rather than replaying a queue of
/// obsolete positions. `offer` elects exactly one pending delivery callback.
public final class LatestValue<Value> {
    private let lock = NSLock()
    private var pending = false
    private var value: Value?

    public init() {}

    @discardableResult public func offer(_ value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.value = value
        guard !pending else { return false }
        pending = true
        return true
    }

    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        defer { value = nil; pending = false }
        return value
    }
}
