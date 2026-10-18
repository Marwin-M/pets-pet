import AppKit
import PetsPetSidebar

/// Owns Pet's Pet sidebar elements, independently of pet detection.
@MainActor final class SidebarController {
    var onChange: (() -> Void)?
    private(set) var tokensEnabled: Bool
    private(set) var projectsEnabled: Bool
    private(set) var quotaEnabled = false
    var quotaProvider: (() -> [String: Any]?)?
    private(set) var quotaStatus = "侧栏底部：等待定位" { didSet { if oldValue != quotaStatus { onChange?() } } }
    var hasEnabledFeatures: Bool { tokensEnabled || projectsEnabled || quotaEnabled }
    private(set) var status = "侧栏：等待连接" { didSet { if oldValue != status { onChange?() } } }
    private(set) var needsConnection = false { didSet { if oldValue != needsConnection { onChange?() } } }
    private(set) var tokenStatus = "" { didSet { if oldValue != tokenStatus { onChange?() } } }
    private(set) var connected = false { didSet { if oldValue != connected { onChange?() } } }
    private(set) var opening = false { didSet { onChange?() } }
    private let preferences: UserDefaults
    private let discovery: SidebarDiscovery
    private let refreshInterval: UInt64
    private let usage = LocalUsageReader()
    private lazy var usageDetails = UsageDetailsReader(home: usage.home)
    private let sizes = ProjectSizeScanner()
    private var script: String?
    private var sessions: [String: SidebarCDPConnection] = [:]
    private var task: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    private var revision = 0
    private var paused = false

    init(preferences: UserDefaults = .standard, discovery: SidebarDiscovery = SidebarDiscovery(),
         refreshInterval: UInt64 = 5_000_000_000) {
        self.preferences = preferences
        self.discovery = discovery
        self.refreshInterval = refreshInterval
        tokensEnabled = preferences.object(forKey: "sidebarTokensEnabled") as? Bool ?? true
        projectsEnabled = preferences.object(forKey: "sidebarProjectsEnabled") as? Bool ?? true
    }

    func start() { script = try? SidebarScript.load(); restart() }
    func setQuotaEnabled(_ enabled: Bool) {
        guard quotaEnabled != enabled else { return }
        quotaEnabled = enabled
        if !hasEnabledFeatures { openingTask?.cancel() }
        if script != nil { restart() }
    }
    func refreshQuota() {
        // Model refreshes must not turn an offline connection into a retry loop.
        if quotaEnabled && connected && !paused { restart() }
    }
    func setTokens(_ enabled: Bool) {
        tokensEnabled = enabled; preferences.set(enabled, forKey: "sidebarTokensEnabled")
        if !hasEnabledFeatures { openingTask?.cancel() }
        restart()
    }
    func setProjects(_ enabled: Bool) {
        projectsEnabled = enabled; preferences.set(enabled, forKey: "sidebarProjectsEnabled")
        if !hasEnabledFeatures { openingTask?.cancel() }
        restart()
    }
    func setPaused(_ value: Bool) {
        paused = value
        if value { openingTask?.cancel() }
        restart()
    }

    private func restart(resetConnections: Bool = false, connectionDeadline: Date? = nil) {
        revision += 1
        let current = revision, previous = task
        previous?.cancel()
        if !projectsEnabled || paused { sizes.cancel() }
        task = Task { [weak self] in
            await previous?.value
            guard let self, self.revision == current, !Task.isCancelled else { return }
            if resetConnections {
                await self.cleanup()
                guard self.revision == current, !Task.isCancelled else { return }
            }
            if self.paused || !self.hasEnabledFeatures {
                await self.cleanup()
                self.needsConnection = false
                self.status = self.paused ? "侧栏：已暂停" : "侧栏：Pet’s Pet 显示已关闭"
                self.tokenStatus = ""
                return
            }
            guard self.script != nil else { self.status = "侧栏：资源缺失，请重新安装 Pet's Pet"; return }
            var deadline = connectionDeadline
            repeat {
                await self.tick()
                guard !Task.isCancelled, self.revision == current else { break }
                if self.connected {
                    // Only refresh live data while connected. A transport loss
                    // stops the loop instead of polling a closed port forever.
                    deadline = nil
                    do { try await Task.sleep(nanoseconds: self.refreshInterval) } catch { break }
                } else if let deadline, Date() < deadline {
                    // A bounded readiness wait belongs only to a user-confirmed
                    // launch; it is not an automatic reconnect service.
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                } else { break }
            } while !Task.isCancelled && self.revision == current
        }
    }

    private func tick() async {
        do {
            let targets = try await discovery.targets()
            needsConnection = false
            try Task.checkCancellation()
            let live = Set(targets.map(\.id))
            for id in Array(sessions.keys) where !live.contains(id) { await sessions.removeValue(forKey: id)?.close() }
            var requests: [(SidebarCDPConnection, [String: Any])] = []
            for target in targets {
                try Task.checkCancellation()
                do {
                    let connection: SidebarCDPConnection
                    if let existing = sessions[target.id] { connection = existing }
                    else { connection = try await discovery.connect(target); sessions[target.id] = connection }
                    let options: [String: Any] = ["tokens": tokensEnabled, "projects": projectsEnabled,
                                                  "quota": quotaEnabled ? quotaProvider?() ?? NSNull() : NSNull()]
                    let requested = try await connection.evaluate("\(script!) (\(try SidebarScript.json(options)))")
                    requests.append((connection, requested))
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    await sessions.removeValue(forKey: target.id)?.close()
                }
            }
            guard !requests.isEmpty else {
                connected = false
                needsConnection = true
                status = opening ? "侧栏：正在等待 Codex 连接就绪…" : targets.isEmpty ? "侧栏：未找到主窗口，可手动启用连接" : "侧栏：连接失败，请手动启用连接"
                tokenStatus = ""; sizes.cancel(); return
            }
            try Task.checkCancellation()
            let ids = Array(Set(requests.flatMap { $0.1["ids"] as? [String] ?? [] }))
            if quotaEnabled {
                let mounted = requests.filter { $0.1["quotaMounted"] as? Bool == true }.count
                quotaStatus = mounted > 0 ? "固定在侧栏底部（\(mounted) 个窗口）" : "侧栏底部：等待侧栏展开或定位，暂未显示"
            }
            let reader = usage
            let usageRecords: [String: LocalUsageRecord]?
            do { usageRecords = tokensEnabled && !ids.isEmpty ? try await Task.detached(priority: .utility) { try reader.records(ids) }.value : [:] }
            catch { usageRecords = nil }
            let totals = usageRecords?.mapValues(\.total)
            let detailReader = usageDetails
            let details = await Task.detached(priority: .utility) {
                await detailReader.read(usageRecords ?? [:]).mapValues(\.fields)
            }.value
            try Task.checkCancellation()
            var projects: [String: LocalProject] = [:]
            for (_, request) in requests {
                for raw in (request["projects"] as? [[String: Any]] ?? []).prefix(200) {
                    guard let id = raw["id"] as? String else { continue }
                    projects[id] = LocalProject(id: id, roots: raw["roots"] as? [String] ?? []) ?? LocalProject(id: id, roots: [])
                }
            }
            let projectValues = sizes.snapshot(Array(projects.values))
            let checked = Date().timeIntervalSince1970 * 1000
            var delivered = 0
            for (connection, _) in requests {
                try Task.checkCancellation()
                let snapshot: [String: Any] = [
                    "tokens": ["ok": totals != nil, "totals": totals ?? [:], "details": details, "checkedAt": checked],
                    "projects": ["ok": true, "sizes": projectValues, "checkedAt": checked]
                ]
                do {
                    _ = try await connection.evaluate("window.__petsPetSidebar?.update(\(try SidebarScript.json(snapshot)))")
                    delivered += 1
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    await connection.close()
                    for id in sessions.keys.filter({ sessions[$0] === connection }) { sessions.removeValue(forKey: id) }
                }
            }
            try Task.checkCancellation()
            connected = delivered > 0
            needsConnection = !connected
            status = connected ? "侧栏：已连接（\(delivered) 个窗口）" : opening ? "侧栏：正在等待 Codex 连接就绪…" : "侧栏：连接中断，请手动启用连接"
            tokenStatus = totals == nil ? "对话用量暂不可读，正在自动重试" : ""
        } catch {
            if Task.isCancelled { return }
            connected = false
            needsConnection = true
            status = opening ? "侧栏：正在等待 Codex 连接就绪…" : "侧栏：未连接，请手动启用连接（开关选择已保存）"
            tokenStatus = ""
            sizes.cancel()
            // Old page elements expire by lease if the renderer cannot be reached.
            for connection in sessions.values { await connection.close() }
            sessions.removeAll()
        }
    }

    private func cleanup() async {
        sizes.cancel()
        let connections = Array(sessions.values)
        sessions.removeAll(); connected = false
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask {
                    _ = try? await connection.evaluate("window.__petsPetSidebar?.destroy()")
                    await connection.close()
                }
            }
        }
    }

    func shutdown() async {
        revision += 1; paused = true; task?.cancel()
        openingTask?.cancel()
        await openingTask?.value
        openingTask = nil
        await task?.value
        await cleanup()
        task = nil
    }

    /// Lifecycle events permit a single probe, never a recurring disconnected poll.
    func clientDidChange() {
        guard !opening else { return }
        restart(resetConnections: true)
    }

    /// Only this explicit menu action may ask Codex to quit and reopen.
    func enableConnection() {
        guard !opening, !connected, !paused, hasEnabledFeatures, script != nil else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        guard let appURL = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              Bundle(url: appURL)?.bundleIdentifier == "com.openai.codex" else {
            status = "侧栏：未找到 Codex，请先安装客户端"; return
        }
        let alert = NSAlert()
        alert.messageText = "启用侧栏连接"
        alert.informativeText = running == nil
            ? "将打开 Codex，并启用仅限本机的页面调试连接，用于在侧栏显示数据。"
            : "需要正常退出并重新打开 Codex，以启用仅限本机的页面调试连接。请先保存工作并等待当前任务结束。若 Codex 拒绝退出，将取消本次操作。"
        alert.addButton(withTitle: running == nil ? "打开并连接" : "重新打开并连接")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        task?.cancel()
        opening = true; status = "侧栏：正在启用连接…"
        openingTask = Task { [weak self] in
            guard let self else { return }
            var waitingForEndpoint = false
            defer {
                self.opening = false
                if waitingForEndpoint && !self.connected && !self.paused && !Task.isCancelled {
                    self.status = "侧栏：连接未就绪，请手动重试"
                }
            }
            do {
                try Task.checkCancellation()
                if let running, !running.isTerminated {
                    guard running.terminate() else { self.status = "侧栏：Codex 未退出，已取消连接操作"; return }
                    let deadline = Date().addingTimeInterval(20)
                    while !running.isTerminated && Date() < deadline {
                        try await Task.sleep(nanoseconds: 200_000_000)
                    }
                    guard running.isTerminated else { self.status = "侧栏：Codex 未退出，已取消连接操作"; return }
                }
                try Task.checkCancellation()
                guard !self.paused else { return }
                // Reuse an instance the user already reopened; never create a competitor.
                if NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty {
                    let config = NSWorkspace.OpenConfiguration()
                    config.arguments = ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=39222"]
                    config.activates = true
                    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                }
                try Task.checkCancellation()
                let deadline = Date().addingTimeInterval(20)
                waitingForEndpoint = true
                self.restart(resetConnections: true, connectionDeadline: deadline)
                // Keep lifecycle notifications from replacing this bounded
                // startup wait with a premature one-shot probe.
                while !self.connected && Date() < deadline {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            } catch {
                if !Task.isCancelled { self.status = "侧栏：未能打开 Codex，请手动重试" }
            }
        }
    }
}
