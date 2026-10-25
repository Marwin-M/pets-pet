import AppKit
import ApplicationServices
import PetsPetCore

/// These seams also let lifecycle checks exercise the real coordinator without opening or quitting Codex.
@MainActor struct CodexStartupEnvironment {
    var isRunning: () -> Bool
    var applicationURL: () -> URL?
    var open: (URL, [String]) async throws -> Void
    var hasMainWindow: () -> Bool
    var isInterfaceReady: () async -> Bool = { false }

    static var live: Self {
        Self(isRunning: { !applications.isEmpty }, applicationURL: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
                .flatMap { Bundle(url: $0)?.bundleIdentifier == "com.openai.codex" ? $0 : nil }
        }, open: { url, arguments in
            // The user may have opened Codex while the splash was being drawn.
            guard applications.isEmpty else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = arguments
            config.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        }, hasMainWindow: { mainWindowFrame() != nil }, isInterfaceReady: { await accessibleInterfaceReady() })
    }

    static func accessibleInterfaceReady() async -> Bool {
        guard AXIsProcessTrusted(), let app = applications.first else { return false }
        let pid = app.processIdentifier
        return await Task.detached(priority: .userInitiated) { CodexAccessibleReadiness.check(pid: pid) }.value
    }

    static func mainWindowFrame() -> CGRect? {
        let pids = Set(applications.map(\.processIdentifier))
        guard !pids.isEmpty, let primary = NSScreen.screens.first else { return nil }
        // Window bounds remain available without screen recording or accessibility permission.
        // The list is front to back. Ignore pet panels, menus, minimized windows and helper processes.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), StartupLayout.valid(rect),
                  rect.width >= 300, rect.height >= 200 else { continue }
            return CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    private static var applications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
    }
}

private enum CodexAccessibleReadiness {
    static func check(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var raw: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
        }
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        var remaining = 600
        for window in windows {
            guard value(window, kAXMinimizedAttribute) as? Bool != true,
                  let rawSize = value(window, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { continue }
            var size = CGSize.zero
            guard AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width >= 300, size.height >= 200 else { continue }
            var nodes = [window], sawWebArea = false, sawEditor = false
            while let node = nodes.popLast(), remaining > 0, ProcessInfo.processInfo.systemUptime < deadline {
                remaining -= 1
                if value(node, "AXHidden") as? Bool == true { continue }
                let role = value(node, kAXRoleAttribute) as? String
                if role == "AXWebArea" { sawWebArea = true }
                if role == kAXTextAreaRole && value(node, kAXEnabledAttribute) as? Bool == true { sawEditor = true }
                if sawWebArea && sawEditor { return true }
                if let children = value(node, kAXChildrenAttribute) as? [AXUIElement] { nodes.append(contentsOf: children.reversed()) }
            }
        }
        return false
    }
}

@MainActor final class CodexStartupController {
    static let autoLaunchKey = "automaticallyLaunchCodex"
    static let animationKey = "startupAnimationEnabled"
    var onPresent: (() -> Void)?
    var onFinish: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onWillLaunch: (() -> [String])?
    var onWindowReady: (() -> Void)?
    var presentationReady: () -> Bool = { true }
    var interfaceReady: (() async -> Bool)?
    private(set) var isStarting = false
    var canStart: Bool { !isStarting && !environment.isRunning() }
    private var openingTask: Task<Void, Never>?
    private var waitingTask: Task<Void, Never>?
    private var generation = 0
    private let environment: CodexStartupEnvironment
    private let timeout: TimeInterval
    private let minimumDisplay: TimeInterval
    private let presentationDelay: UInt64
    private let pollInterval: UInt64

    init(environment: CodexStartupEnvironment? = nil, timeout: TimeInterval = 30,
         minimumDisplay: TimeInterval = 0.8, presentationDelay: UInt64 = 150_000_000,
         pollInterval: UInt64 = 100_000_000) {
        self.environment = environment ?? .live; self.timeout = timeout; self.minimumDisplay = minimumDisplay
        self.presentationDelay = presentationDelay; self.pollInterval = pollInterval
    }

    func start(enabled: Bool, animated: Bool, launchPreparation: (() -> [String])? = nil) {
        guard enabled, canStart else { return }
        guard let url = environment.applicationURL() else {
            onError?("未找到 Codex。请先安装 Codex Desktop，然后重新打开 Pet’s Pet。")
            return
        }
        // Resolve first-use connection consent before showing the noninteractive splash.
        isStarting = true
        generation += 1
        let current = generation
        let arguments = (launchPreparation ?? onWillLaunch)?() ?? []
        guard isStarting, generation == current else { return }
        let started = ProcessInfo.processInfo.systemUptime
        onPresent?()
        openingTask = Task { [weak self] in
            guard let self else { return }
            do {
                if animated { try await Task.sleep(nanoseconds: self.presentationDelay) }
                while animated && !self.presentationReady() {
                    try await Task.sleep(nanoseconds: self.pollInterval)
                }
                try Task.checkCancellation()
                try await self.environment.open(url, arguments)
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                self.finish(error: "未能打开 Codex。请检查应用是否仍在原来的位置，再通过重新打开 Pet’s Pet 重试。")
            }
        }
        waitingTask = Task { [weak self] in
            var observedProcess = false
            while !Task.isCancelled {
                guard let self, self.generation == current, self.isStarting else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let running = self.environment.isRunning()
                if running { observedProcess = true }
                if running && self.environment.hasMainWindow() && (!animated || self.presentationReady() && elapsed >= self.minimumDisplay) {
                    let ready = await (self.interfaceReady ?? self.environment.isInterfaceReady)()
                    guard !Task.isCancelled, self.generation == current, self.isStarting else { return }
                    if ready {
                        self.onWindowReady?()
                        self.finish(); return
                    }
                }
                if observedProcess && !running {
                    self.finish(error: "Codex 在启动完成前已退出。请尝试手动打开 Codex，确认它能正常运行。")
                    return
                }
                if elapsed >= self.timeout {
                    self.finish(error: "暂未确认 Codex 主界面加载完成，已结束开场动画。客户端若仍在加载可以继续等待；也可检查辅助功能权限或侧栏连接。稍后组件会按原设置显示。")
                    return
                }
                do { try await Task.sleep(nanoseconds: self.pollInterval) } catch { return }
            }
        }
    }

    func cancel() { if isStarting { finish(cancelled: true) } }

    private func finish(error: String? = nil, cancelled: Bool = false) {
        guard isStarting else { return }
        isStarting = false; generation += 1
        openingTask?.cancel(); openingTask = nil
        waitingTask?.cancel(); waitingTask = nil
        onFinish?(error == nil && !cancelled)
        if let error { onError?(error) }
    }
}
