import Foundation
import CoreGraphics

/// A drag beyond the click tolerance cancels the entire press, even on return.
/// Coordinates use the same top-left screen space as the pet's AX bounds.
public struct PetClickGesture {
    private var origin: CGPoint?
    private var pressedAt: TimeInterval = 0

    public init() {}

    public mutating func begin(at point: CGPoint, time: TimeInterval) {
        cancel()
        guard point.x.isFinite, point.y.isFinite, time.isFinite else { return }
        origin = point
        pressedAt = time
    }

    public mutating func cancel() { origin = nil }

    /// Mouse-drag events also occur with ordinary hand jitter. Only movement
    /// beyond the same tolerance used on release starts an actual drag.
    public mutating func move(to point: CGPoint) -> Bool {
        guard let origin else { return false }
        guard point.x.isFinite, point.y.isFinite,
              hypot(point.x - origin.x, point.y - origin.y) <= 4 else {
            cancel()
            return true
        }
        return false
    }

    public mutating func end(at point: CGPoint, time: TimeInterval, petRect: CGRect) -> Bool {
        defer { cancel() }
        guard let origin, point.x.isFinite, point.y.isFinite, time.isFinite,
              time >= pressedAt, time - pressedAt <= 1,
              petRect.contains(point) else { return false }
        // Also reject displacement if macOS did not deliver a drag event.
        return hypot(point.x - origin.x, point.y - origin.y) <= 4
    }
}

/// Window order comes from the system's on-screen list, front to back. The
/// rectangle and window ID must belong to a previously AX-identified pet.
public struct PetClickSurface {
    public let processID: Int32
    public let windowID: Int
    public let bounds: CGRect

    public init(processID: Int32, windowID: Int, bounds: CGRect) {
        self.processID = processID; self.windowID = windowID; self.bounds = bounds
    }

    public static func isPetExposed(at point: CGPoint, petRect: CGRect, processID: Int32, windowID: Int, surfaces: [PetClickSurface]) -> Bool {
        guard processID > 0, windowID > 0, point.x.isFinite, point.y.isFinite,
              petRect.contains(point), let front = surfaces.first(where: { $0.bounds.contains(point) }) else { return false }
        return front.processID == processID && front.windowID == windowID
    }
}
