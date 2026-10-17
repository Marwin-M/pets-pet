import AppKit
import ApplicationServices
import PetsPetCore

struct PetState {
    var phase: String
    var rect: CGRect?
    var occupiedRect: CGRect?
    var layer: Int = 3
    var scannedNodes = 0
    var candidateCount = 0
    var windowCount = 0
    var axError: Int32 = 0
    var processID: Int32 = 0
    var petWindowID: Int?
    var screenWindowCount = 0
    var axWindowCount = 0
    var manualActivationError: Int32 = 0
    var chromiumActivationError: Int32 = 0
    var trackingHz: Double = 0
    var positionReadMs: Double = 0
    var positionReadMaxMs: Double = 0
    var scanMs: Double = 0
    var followingMode = "idle"
    var deliveryDelayMs: Double = 0
    static let permission = PetState(phase: "需要辅助功能权限")
}

final class PetMonitor {
    var onChange: ((PetState) -> Void)?
    var onGeometry: (([[String: Any]]) -> Void)?
    private let queue = DispatchQueue(label: "com.marwin.petspet.discovery", qos: .userInitiated)
    private let trackingQueue = DispatchQueue(label: "com.marwin.petspet.position", qos: .userInteractive)
    private let cacheLock = NSLock()
    private var running = false
    private var generation: UInt64 = 0
    private var inspectionGeneration: UInt64 = 0
    private struct Input {
        let state: PetState
        let target: AXUIElement?
        let observedAt: TimeInterval
    }
    private struct Delivery { let state: PetState; let generation: UInt64; let sampledAt: TimeInterval }
    private var input: Input?
    private var cadence = TrackingCadence()
    private var fastTracking = false
    private var trackingTimer: DispatchSourceTimer?
    private let delivery = LatestValue<Delivery>()
    private var lastTrackedState: PetState?
    private var trackingGeneration: UInt64 = 0
    private var lastTrackedAt: TimeInterval = 0
    private var positionFailedAt: TimeInterval?
    private var metricsStarted: TimeInterval = 0
    private var readCount = 0
    private var readTotal: Double = 0
    private var readMax: Double = 0
    private var measuredHz: Double = 0
    private var measuredReadMs: Double = 0
    private var measuredReadMaxMs: Double = 0
    private var scanDuration: Double = 0
    private var timer: DispatchSourceTimer?
    private var pid: pid_t = 0
    private var application: AXUIElement?
    private var target: AXUIElement?
    private var targetWindow: AXUIElement?
    private var targetWindowID: Int?
    private var occupiedAtScan: CGRect?
    private var petAtScan: CGRect?
    private struct OccupiedElement {
        let element: AXUIElement
        // nil denotes an actual control/image/text; wrappers require visible
        // descendant content so their retained layout height cannot add gaps.
        let contents: [AXUIElement]?
    }
    private struct MeasuredElement {
        let element: AXUIElement
        let role: String
        let bounds: CGRect
        let ancestors: [AXUIElement]
        let isContent: Bool
    }
    private var occupiedElements: [OccupiedElement] = []
    private var recovery = MonitorRecovery()
    private var screenWindowCount = 0
    private var axWindowCount = 0
    private var activationPID: pid_t = 0
    private var manualActivationError = AXError.success
    private var chromiumActivationError = AXError.success
    private var activationFinished = false
    private var lastScan = Date.distantPast
    private var scanState = PetState(phase: "等待宠物显示")

    func start() {
        cacheLock.lock()
        guard !running else { cacheLock.unlock(); return }
        running = true; generation &+= 1; input = nil
        cadence.reset(); fastTracking = false
        cacheLock.unlock()
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: TrackingCadence.idleInterval, leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.poll() }
        timer = source
        source.resume()
    }

    func stop() {
        cacheLock.lock(); running = false; generation &+= 1; input = nil; cadence.reset(); fastTracking = false; cacheLock.unlock()
        queue.async { self.timer?.cancel(); self.timer = nil; self.clear() }
        trackingQueue.async { self.trackingTimer?.cancel(); self.trackingTimer = nil; self.lastTrackedState = nil }
    }

    func rescan() {
        cacheLock.lock(); generation &+= 1; input = nil; cadence.reset(); fastTracking = false; cacheLock.unlock()
        trackingQueue.async { self.trackingTimer?.cancel(); self.trackingTimer = nil }
        queue.async { self.clear(); self.poll() }
    }

    func refresh() { queue.async { self.poll() } }

    /// Called only after the mouse press has been verified against the actual
    /// pet. Mouse input wakes tracking; positions still come from the pet so
    /// screen constraints cannot make the component follow the pointer alone.
    func dragActivity(released: Bool) {
        cacheLock.lock()
        guard running, input?.target != nil else { cacheLock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if released { cadence.released(at: now) } else { cadence.moved(at: now) }
        let shouldStart = !fastTracking
        let epoch = generation
        fastTracking = true
        cacheLock.unlock()
        guard shouldStart else { return }
        trackingQueue.async {
            self.cacheLock.lock()
            let valid = self.running && self.generation == epoch && self.fastTracking
            self.cacheLock.unlock()
            guard valid, self.trackingTimer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.trackingQueue)
            source.schedule(deadline: .now() + TrackingCadence.frameInterval,
                            repeating: TrackingCadence.frameInterval, leeway: .microseconds(500))
            source.setEventHandler { [weak self] in self?.fastTick(generation: epoch) }
            self.trackingTimer = source
            source.resume()
            self.trackPosition(fast: true)
        }
    }

    func cancelDragActivity() {
        cacheLock.lock(); cadence.reset(); cacheLock.unlock()
    }

    private func fastTick(generation epoch: UInt64) {
        cacheLock.lock()
        guard generation == epoch else { cacheLock.unlock(); return }
        let active = running && input?.target != nil && cadence.isFast(at: ProcessInfo.processInfo.systemUptime)
        if !active { fastTracking = false }
        cacheLock.unlock()
        guard active else {
            trackingTimer?.cancel(); trackingTimer = nil
            // Refresh visibility and occupied content once after motion stops.
            queue.async { self.poll() }
            return
        }
        trackPosition(fast: true)
    }

    private func poll() {
        cacheLock.lock()
        inspectionGeneration = generation
        let active = running
        let moving = fastTracking
        cacheLock.unlock()
        guard active else { return }
        guard AXIsProcessTrusted() else { clear(); publish(.permission); return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter({ !$0.isTerminated }).max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else {
            clear(); publish(PetState(phase: "Codex 未运行")); return
        }
        if app.processIdentifier != pid {
            clear()
            pid = app.processIdentifier
            recovery.observe(processID: pid)
        }
        guard Date() >= recovery.retryAt else { return }
        if recovery.needsConnection {
            application = AXUIElementCreateApplication(pid)
            if let application {
                AXUIElementSetMessagingTimeout(application, 0.25)
                activateAccessibility(application)
            }
            recovery.connected()
            lastScan = .distantPast
        }
        let entries = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }
        screenWindowCount = entries.count
        if target == nil || (!moving && Date().timeIntervalSince(lastScan) >= TrackingCadence.idleInterval) {
            let started = ProcessInfo.processInfo.systemUptime
            let discovered = discover(entries: entries)
            scanDuration = (ProcessInfo.processInfo.systemUptime - started) * 1000
            lastScan = Date()
            guard discovered else { return }
        }
        guard let target, let window = targetWindow, let windowID = targetWindowID,
              let entry = entries.first(where: { $0[kCGWindowNumber as String] as? Int == windowID }),
              bool(window, kAXMinimizedAttribute) != true,
              let rect = frame(target), validPetFrame(rect),
              let windowRect = cgFrame(entry), windowRect.intersects(rect),
              PetIdentity.matches(role: string(target, kAXRoleAttribute), identifier: string(target, kAXIdentifierAttribute), labels: labels(target)) else {
            var state = scanState
            state.rect = nil
            state.occupiedRect = nil
            publish(state)
            return
        }
        // Cached containers and their semantic contents track reflow without
        // reading text or walking the complete tree on each visibility check.
        let occupied: CGRect
        if moving, let bounds = occupiedAtScan, let pet = petAtScan {
            // Keep a consistent pet-relative layout while dragging, rather
            // than mixing positions read at different moments in the gesture.
            occupied = bounds.offsetBy(dx: rect.minX - pet.minX, dy: rect.minY - pet.minY)
        } else {
            let frames = occupiedElements.compactMap(occupiedFrame)
            occupied = frames.isEmpty ? rect : Placement.occupiedBounds(pet: rect, elements: frames)
            occupiedAtScan = occupied; petAtScan = rect
        }
        publish(PetState(phase: "正在跟随宠物", rect: rect, occupiedRect: occupied, layer: entry[kCGWindowLayer as String] as? Int ?? 3,
                         scannedNodes: scanState.scannedNodes, candidateCount: 1, windowCount: entries.count))
    }

    private func activateAccessibility(_ application: AXUIElement) {
        if activationPID != pid {
            activationPID = pid
            activationFinished = false
            manualActivationError = .success
            chromiumActivationError = .success
        }
        guard !activationFinished else { return }
        // Request the native application role first (Chromium's normal AT
        // detection), then negotiate the engine-specific activation attribute.
        _ = value(application, kAXRoleAttribute)
        if manualActivationError != .attributeUnsupported && manualActivationError != .notImplemented {
            manualActivationError = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if manualActivationError == .success { activationFinished = true; return }
        guard manualActivationError == .attributeUnsupported || manualActivationError == .notImplemented else { return }

        // The current Codex host embeds Chromium, not Electron. Chromium uses
        // this attribute, with asynchronous activation. Only use it when the
        // application exposes it; never toggle off or repeatedly send successful
        // activation requests (which would restart Chromium's debounce timer).
        let attribute = "AXEnhancedUserInterface" as CFString
        if (value(application, attribute as String) as? Bool) == true { activationFinished = true; return }
        var settable = DarwinBoolean(false)
        chromiumActivationError = AXUIElementIsAttributeSettable(application, attribute, &settable)
        guard chromiumActivationError == .success, settable.boolValue else { return }
        chromiumActivationError = AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue)
        activationFinished = chromiumActivationError == .success
    }

    @discardableResult private func discover(entries: [[String: Any]]) -> Bool {
        guard let application else { return false }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
        guard error == .success, let windows = raw as? [AXUIElement] else {
            resetTarget()
            recovery.failed(at: Date())
            self.application = nil
            publish(PetState(phase: "正在恢复宠物检测，稍后自动重试", axError: error.rawValue))
            return false
        }
        axWindowCount = windows.count
        if windows.isEmpty && !entries.isEmpty {
            resetTarget()
            recovery.failed(at: Date())
            self.application = nil
            publish(PetState(phase: "等待 Codex 初始化宠物检测"))
            return false
        }
        var roots: [(AXUIElement, [String: Any])] = []
        for window in windows {
            guard bool(window, kAXMinimizedAttribute) != true, let rect = frame(window) else { continue }
            let matches = entries.filter { entry in
                guard let other = cgFrame(entry) else { return false }
                return abs(other.minX - rect.minX) < 3 && abs(other.minY - rect.minY) < 3 && abs(other.width - rect.width) < 3 && abs(other.height - rect.height) < 3
            }
            if let entry = matches.max(by: { ($0[kCGWindowLayer as String] as? Int ?? 0) < ($1[kCGWindowLayer as String] as? Int ?? 0) }) {
                roots.append((window, entry))
            }
        }
        roots.sort { ($0.1[kCGWindowLayer as String] as? Int ?? 0) > ($1.1[kCGWindowLayer as String] as? Int ?? 0) }
        var found: [(AXUIElement, AXUIElement, Int)] = []
        var contents: [Int: [MeasuredElement]] = [:]
        var scanned = 0
        let deadline = Date().addingTimeInterval(0.35)
        var incomplete = false
        var sawWebContent = false
        let hasFloatingWindow = entries.contains { ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
        for (window, entry) in roots {
            // Mascots belong to a floating overlay. A normal main window is never an anchor.
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let title = string(window, kAXTitleAttribute).lowercased()
            guard layer > 0 || ["codex pet", "pet overlay", "宠物", "虛擬寵物"].contains(title) else { continue }
            var nodes: [(AXUIElement, Int, [AXUIElement])] = [(window, 0, [])]
            var seen: Set<AXUIElement> = []
            var cursor = 0
            while cursor < nodes.count, scanned < 2200, Date() < deadline {
                let (element, depth, ancestors) = nodes[cursor]
                cursor += 1
                guard seen.insert(element).inserted else { continue }
                scanned += 1
                guard bool(element, "AXHidden") != true else { continue }
                let role = string(element, kAXRoleAttribute)
                if role == "AXWebArea" { sawWebContent = true }
                let isPet = PetIdentity.matches(role: role, identifier: string(element, kAXIdentifierAttribute), labels: labels(element))
                let isContent = isPet || ["AXButton", "AXStaticText", "AXImage", "AXTextField", "AXSlider", "AXCheckBox", "AXDisclosureTriangle"].contains(role)
                if isContent || ["AXGroup", "AXList", "AXScrollArea", "AXLayoutArea", "AXToolbar"].contains(role),
                   let bounds = frame(element), let id = entry[kCGWindowNumber as String] as? Int {
                    contents[id, default: []].append(MeasuredElement(element: element, role: role, bounds: bounds, ancestors: ancestors, isContent: isContent))
                }
                if isPet,
                   let rect = frame(element), validPetFrame(rect), let id = entry[kCGWindowNumber as String] as? Int {
                    found.append((element, window, id))
                    continue
                }
                if !["AXStaticText", "AXTextArea", "AXTextField", "AXMenu", "AXMenuBar"].contains(role) {
                    let children = value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    // The real task-card branch extends beyond 20 levels.
                    // A depth/child limit must signal an incomplete scan,
                    // never turn unvisited content into an "empty" wrapper.
                    if depth >= 40 {
                        if !children.isEmpty { incomplete = true }
                    } else {
                        if children.count > 500 { incomplete = true }
                        nodes.append(contentsOf: children.prefix(500).map { ($0, depth + 1, ancestors + [element]) })
                    }
                }
            }
            if cursor < nodes.count { incomplete = true }
        }
        let usable = !incomplete && (!hasFloatingWindow || sawWebContent || !found.isEmpty)
        recovery.inspected(usable: usable, at: Date())
        if !usable {
            resetTarget()
            self.application = nil
            publish(PetState(phase: "正在等待宠物检测结构就绪，稍后自动重试", scannedNodes: scanned, candidateCount: found.count, windowCount: roots.count))
            return false
        }
        // Ambiguity is safer than displaying beside the wrong image or a settings preview.
        if !incomplete, found.count == 1, let match = found.first {
            target = match.0; targetWindow = match.1; targetWindowID = match.2
            petAtScan = frame(match.0)
            let measured = contents[match.2] ?? []
            let leaves = measured.filter(\.isContent)
            let geometries: [(OccupiedElement, CGRect)] = measured.compactMap { item in
                if item.isContent { return (OccupiedElement(element: item.element, contents: nil), item.bounds) }
                let descendants = leaves.filter { $0.ancestors.contains(item.element) }
                guard let bounds = Placement.contentBounds(container: item.bounds, contents: descendants.map(\.bounds)) else { return nil }
                return (OccupiedElement(element: item.element, contents: descendants.map(\.element)), bounds)
            }
            occupiedAtScan = petAtScan.map { Placement.occupiedBounds(pet: $0, elements: geometries.map { $0.1 }) }
            var outer: [(OccupiedElement, CGRect)] = []
            for item in geometries.sorted(by: { $0.1.width * $0.1.height > $1.1.width * $1.1.height }) {
                guard let occupied = occupiedAtScan, occupied.contains(item.1),
                      !outer.contains(where: { $0.1.insetBy(dx: -1, dy: -1).contains(item.1) }) else { continue }
                outer.append(item)
            }
            occupiedElements = outer.prefix(12).map { $0.0 }
            if let pet = petAtScan {
                let indices = Dictionary(uniqueKeysWithValues: measured.enumerated().map { ($0.element.element, $0.offset) })
                func fields(_ rect: CGRect) -> [String: Double] {
                    ["x": rect.minX - pet.minX, "y": rect.minY - pet.minY, "width": rect.width, "height": rect.height]
                }
                onGeometry?(Array(measured.prefix(100).enumerated().map { index, item in
                    var row: [String: Any] = ["node": index, "role": item.role, "bounds": fields(item.bounds),
                                              "depth": item.ancestors.count,
                                              "content": item.isContent, "pet": item.element == match.0,
                                              "parent": item.ancestors.reversed().compactMap { indices[$0] }.first ?? -1,
                                              "selected": occupiedElements.contains { $0.element == item.element }]
                    if let effective = geometries.first(where: { $0.0.element == item.element })?.1 { row["effective"] = fields(effective) }
                    return row
                }))
            }
            for item in occupiedElements {
                AXUIElementSetMessagingTimeout(item.element, 0.015)
                for element in item.contents ?? [] { AXUIElementSetMessagingTimeout(element, 0.015) }
            }
            AXUIElementSetMessagingTimeout(match.0, 0.012)
        } else {
            resetTarget()
        }
        scanState = PetState(phase: incomplete ? "宠物检测尚未完成，稍后自动重试" : found.count > 1 ? "检测到多个宠物候选，暂停跟随" : "等待宠物显示",
                             scannedNodes: scanned, candidateCount: found.count, windowCount: roots.count)
        return true
    }

    private func resetTarget() { target = nil; targetWindow = nil; targetWindowID = nil; occupiedAtScan = nil; petAtScan = nil; occupiedElements = [] }
    private func occupiedFrame(_ item: OccupiedElement) -> CGRect? {
        guard bool(item.element, "AXHidden") != true, let bounds = frame(item.element) else { return nil }
        guard let contents = item.contents else { return bounds }
        let frames = contents.filter { bool($0, "AXHidden") != true }.compactMap(frame)
        return Placement.contentBounds(container: bounds, contents: frames)
    }
    private func clear() { pid = 0; application = nil; resetTarget(); recovery = MonitorRecovery(); screenWindowCount = 0; axWindowCount = 0; scanState = PetState(phase: "等待宠物显示"); lastScan = .distantPast }
    private func validPetFrame(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width >= 12 && rect.height >= 12 && rect.width <= 512 && rect.height <= 512
    }
    private func publish(_ value: PetState) {
        var state = value
        state.processID = pid
        state.petWindowID = state.rect == nil ? nil : targetWindowID
        state.screenWindowCount = screenWindowCount
        state.axWindowCount = axWindowCount
        state.manualActivationError = manualActivationError.rawValue
        state.chromiumActivationError = chromiumActivationError.rawValue
        state.scanMs = scanDuration
        cacheLock.lock()
        guard running, generation == inspectionGeneration else { cacheLock.unlock(); return }
        input = Input(state: state, target: state.rect == nil ? nil : target,
                      observedAt: ProcessInfo.processInfo.systemUptime)
        let needsIdleDelivery = !fastTracking || state.rect == nil
        cacheLock.unlock()
        // Idle frames reuse the position already read by poll(), avoiding a
        // second position request or a continuously running 60 Hz timer.
        if needsIdleDelivery { trackingQueue.async { self.trackPosition(fast: false) } }
    }

    private func trackPosition(fast: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        cacheLock.lock(); let sample = input; let active = running; let epoch = generation; cacheLock.unlock()
        guard active else { return }
        if trackingGeneration != epoch {
            trackingGeneration = epoch
            lastTrackedState = nil; positionFailedAt = nil
            metricsStarted = 0; readCount = 0; readTotal = 0; readMax = 0
            measuredHz = 0; measuredReadMs = 0; measuredReadMaxMs = 0
        }
        let mode = fast ? "fast" : "idle"
        if lastTrackedState?.followingMode != mode {
            metricsStarted = now; readCount = 0; readTotal = 0; readMax = 0
            measuredHz = 0; measuredReadMs = 0; measuredReadMaxMs = 0
        }
        var state = sample?.state ?? PetState(phase: "正在重新检测宠物")
        if let sample, TrackingCadence.isFresh(observedAt: sample.observedAt, now: now),
           let element = sample.target, let anchor = sample.state.rect {
            let started = ProcessInfo.processInfo.systemUptime
            let point = fast ? position(element) : anchor.origin
            let duration = (ProcessInfo.processInfo.systemUptime - started) * 1000
            if metricsStarted == 0 { metricsStarted = started }
            readCount += 1; readTotal += duration; readMax = max(readMax, duration)
            if now - metricsStarted >= 2 {
                measuredHz = Double(readCount) / (now - metricsStarted)
                measuredReadMs = readTotal / Double(readCount)
                measuredReadMaxMs = readMax
                metricsStarted = now; readCount = 0; readTotal = 0; readMax = 0
            }
            if let point, point.x.isFinite, point.y.isFinite {
                positionFailedAt = nil
                let dx = point.x - anchor.minX, dy = point.y - anchor.minY
                state.rect = anchor.offsetBy(dx: dx, dy: dy)
                state.occupiedRect = sample.state.occupiedRect?.offsetBy(dx: dx, dy: dy)
            } else {
                if positionFailedAt == nil { positionFailedAt = now }
                if now - (positionFailedAt ?? now) < 0.1, let previous = lastTrackedState, previous.processID == state.processID {
                    state.rect = previous.rect; state.occupiedRect = previous.occupiedRect
                } else { state.rect = nil; state.occupiedRect = nil; state.phase = "暂时无法读取宠物位置" }
            }
        } else if state.rect != nil {
            state.rect = nil; state.occupiedRect = nil; state.phase = "正在确认宠物可见性"
        }
        state.trackingHz = measuredHz
        state.followingMode = mode
        state.positionReadMs = measuredReadMs
        state.positionReadMaxMs = measuredReadMaxMs
        guard lastTrackedState?.phase != state.phase || lastTrackedState?.rect != state.rect ||
              lastTrackedState?.occupiedRect != state.occupiedRect || lastTrackedState?.processID != state.processID || lastTrackedState?.petWindowID != state.petWindowID ||
              lastTrackedState?.followingMode != state.followingMode || now - lastTrackedAt >= 1 else { return }
        lastTrackedState = state; lastTrackedAt = now
        if delivery.offer(Delivery(state: state, generation: epoch, sampledAt: now)) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let item = self.delivery.take() else { return }
                self.cacheLock.lock(); let valid = self.running && self.generation == item.generation; self.cacheLock.unlock()
                if valid {
                    var delivered = item.state
                    delivered.deliveryDelayMs = (ProcessInfo.processInfo.systemUptime - item.sampledAt) * 1000
                    self.onChange?(delivered)
                }
            }
        }
    }

    private func position(_ element: AXUIElement) -> CGPoint? {
        guard let raw = value(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }
    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool? { value(element, attribute) as? Bool }
    private func labels(_ element: AXUIElement) -> [String] { [string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute)] }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
    private func cgFrame(_ entry: [String: Any]) -> CGRect? {
        guard let dict = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }
}
