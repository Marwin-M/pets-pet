import Foundation

/// The process can exist before its accessibility server is ready. Reconnect
/// after failure, with bounded backoff rather than reusing an invalid AX handle.
public struct MonitorRecovery {
    public private(set) var processID: Int32 = 0
    public private(set) var failures = 0
    public private(set) var retryAt = Date.distantPast
    public private(set) var needsConnection = true

    public init() {}

    public mutating func observe(processID: Int32) {
        guard self.processID != processID else { return }
        self = MonitorRecovery()
        self.processID = processID
    }

    public mutating func failed(at now: Date) {
        failures = min(failures + 1, 6)
        retryAt = now.addingTimeInterval(min(5, 0.4 * pow(2, Double(failures - 1))))
        needsConnection = true
    }

    public mutating func connected() { needsConnection = false }
    public mutating func succeeded() { failures = 0; retryAt = .distantPast }

    /// A successful AX RPC is not proof that Chromium's asynchronous tree is
    /// ready. Empty/mismatched floating windows must keep the recovery active.
    public mutating func inspected(usable: Bool, at now: Date) {
        if usable { succeeded() } else { failed(at: now) }
    }
}
