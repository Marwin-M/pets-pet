import AppKit
import ApplicationServices
import PetsPetCore

/// Observes clicks without consuming them, so Codex retains its pet animation.
/// Capture the frontmost window on mouse-down, using the pet identity already
/// verified by PetMonitor. Re-reading the AX subtree later races Codex's click
/// animation/reflow. Gesture processing remains on a serial background queue.
final class PetClickMonitor {
    var onClick: (() -> Void)?
    var onDecision: ((String) -> Void)?
    /// `true` ends a drag and requests a short final-position settling period.
    var onDrag: ((_ released: Bool) -> Void)?
    private var eventMonitor: Any?
    private var processID: pid_t = 0
    private var windowID: Int?
    private var petRect: CGRect?
    private var observedAt: TimeInterval = 0
    private var generation: UInt64 = 0
    private var pressPending = false
    private let queue = DispatchQueue(label: "com.marwin.petspet.click", qos: .userInitiated)
    private var gesture = PetClickGesture()
    private var gestureGeneration: UInt64 = 0
    private var verifiedPress = false
    private var dragged = false
    private struct DragDelivery { let released: Bool; let generation: UInt64 }
    private let dragDelivery = LatestValue<DragDelivery>()

    func start() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        updateTarget(processID: 0, windowID: nil, rect: nil)
        cancelPendingClick()
    }

    func updateTarget(processID: pid_t, windowID: Int?, rect: CGRect?) {
        if self.processID != processID || self.windowID != windowID || (petRect != nil && rect == nil) { cancelPendingClick() }
        self.processID = processID
        self.windowID = windowID
        petRect = rect
        observedAt = ProcessInfo.processInfo.systemUptime
    }

    func cancelPendingClick() {
        generation &+= 1
        pressPending = false
        queue.async {
            self.gesture.cancel()
            self.verifiedPress = false; self.dragged = false
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseDragged {
            guard pressPending else { return }
            guard let point = event.cgEvent?.location else { cancelPendingClick(); return }
            let epoch = generation
            queue.async {
                guard self.verifiedPress, self.gestureGeneration == epoch else { return }
                guard self.dragged || self.gesture.move(to: point) else { return }
                self.dragged = true
                self.deliverDrag(released: false, generation: epoch)
            }
            return
        }
        guard event.type == .leftMouseDown || pressPending else { return }
        guard let rect = petRect, processID > 0,
              TrackingCadence.isFresh(observedAt: observedAt, now: ProcessInfo.processInfo.systemUptime),
              let cgEvent = event.cgEvent, AXIsProcessTrusted() else {
            cancelPendingClick()
            return
        }
        let point = cgEvent.location
        let time = event.timestamp
        let epoch = generation
        let pid = processID
        if event.type == .leftMouseDown {
            pressPending = rect.contains(point)
            guard pressPending else { cancelPendingClick(); return }
            guard let windowID, petIsExposed(at: point, rect: rect, processID: pid, windowID: windowID) else {
                onDecision?("coveredOrUnconfirmedWindow")
                cancelPendingClick()
                return
            }
            queue.async {
                self.gesture.cancel()
                self.verifiedPress = false; self.dragged = false
                self.gestureGeneration = epoch
                self.verifiedPress = true
                self.gesture.begin(at: point, time: time)
            }
        } else if event.type == .leftMouseUp {
            pressPending = false
            queue.async {
                defer { self.verifiedPress = false; self.dragged = false }
                if self.verifiedPress, self.gestureGeneration == epoch, self.dragged {
                    self.deliverDrag(released: true, generation: epoch)
                    self.report("drag", generation: epoch)
                    return
                }
                guard self.gestureGeneration == epoch,
                      self.gesture.end(at: point, time: time, petRect: rect) else {
                    self.report("releaseOutsideOrLongPress", generation: epoch)
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == epoch, self.processID == pid,
                          self.petRect != nil, AXIsProcessTrusted(),
                          TrackingCadence.isFresh(observedAt: self.observedAt, now: ProcessInfo.processInfo.systemUptime) else { return }
                    self.onClick?()
                    self.onDecision?("toggle")
                }
            }
        }
    }

    private func deliverDrag(released: Bool, generation: UInt64) {
        // Coalesce high-rate mouse input instead of replaying old events on
        // the main thread. A release is the final sample of the press.
        guard dragDelivery.offer(DragDelivery(released: released, generation: generation)) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let sample = self.dragDelivery.take(), self.generation == sample.generation,
                  self.petRect != nil, AXIsProcessTrusted() else { return }
            self.onDrag?(sample.released)
        }
    }

    private func petIsExposed(at point: CGPoint, rect: CGRect, processID: pid_t, windowID: Int) -> Bool {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let surfaces: [PetClickSurface] = entries.compactMap { entry in
            // Our quota panel is explicitly mouse-through. All other visible
            // windows remain blockers, including other windows owned by Codex.
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw) else { return nil }
            return PetClickSurface(processID: pid, windowID: id, bounds: bounds)
        }
        return PetClickSurface.isPetExposed(at: point, petRect: rect, processID: processID, windowID: windowID, surfaces: surfaces)
    }

    private func report(_ decision: String, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.onDecision?(decision)
        }
    }
}
