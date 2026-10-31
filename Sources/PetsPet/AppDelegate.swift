import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers
import PetsPetCore
import PetsPetSidebar

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = DisplayModel()
    private let monitor = PetMonitor()
    private let petClicks = PetClickMonitor()
    private let quota = QuotaClient()
    private let dailyUsageReader = LocalDailyUsageReader()
    private var dailyUsageTask: Task<Void, Never>?
    private var dailyUsage: DailyTokenUsageSnapshot?
    private var dailyLoading = false
    private var lastDailyAttempt = Date.distantPast
    private let sidebar = SidebarController()
    private let sidebarQuota = SidebarQuotaRenderer()
    private var componentPosition = ComponentPosition.followPet
    private let startup = CodexStartupController()
    private let termination = ApplicationTerminationController()
    private let updates = UpdateChecker()
    private lazy var clientLifecycle = CodexClientLifecycle(isClientRunning: { CodexStartupEnvironment.live.isRunning() },
                                                           quit: { [weak self] in self?.termination.request() })
    private let startupAnimation = StartupAnimationController()
    private var startupMedia: StartupMediaStore?
    private var mediaImportTask: Task<Void, Never>?
    private var store: SupportStore?
    private var overlay: OverlayController!
    private var statusItem: NSStatusItem!
    private var setupWindow: NSWindow?
    private var setupStatus: NSTextField?
    private var clock: Timer?
    private var state = PetState.permission
    private var lastFetch = Date.distantPast
    private var lastLog = Date.distantPast
    private var lastPhase = ""
    private var lastFollowingMode = ""
    private var lastRect: CGRect?
    private var lastOccupiedRect: CGRect?
    private var lastDiagnostics = Date.distantPast
    private var lastConnection: [Int32] = []
    private var fetching = false
    private var suspended = false
    private var userSessionActive = true
    private var componentEnabled = true
    private var componentMenuItem: NSMenuItem?
    private weak var openMenu: NSMenu?
    private var dataMenuItems: [NSMenuItem] = []
    private var updatedMenuItem: NSMenuItem?
    private var dataStatusItem: NSMenuItem?
    private var refreshMenuItem: NSMenuItem?
    private var connectionMenuItem: NSMenuItem?
    private var connectionStatusItem: NSMenuItem?
    private var connectionTokenItem: NSMenuItem?
    private var enableConnectionItem: NSMenuItem?
    private var launchClientItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.marwin.petspet")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { termination.request(); return }
        do {
            let support = try SupportStore()
            store = support
            startupMedia = StartupMediaStore(directory: support.directory)
        }
        catch { showStorageError(); return }
        componentEnabled = UserDefaults.standard.object(forKey: "componentEnabled") as? Bool ?? true
        model.appearance = AppearancePreference(savedValue: UserDefaults.standard.string(forKey: "appearance"))
        model.contentMode = QuotaDisplayMode(savedValue: UserDefaults.standard.string(forKey: QuotaDisplayMode.defaultsKey))
        componentPosition = ComponentPosition(savedValue: UserDefaults.standard.string(forKey: ComponentPosition.defaultsKey))
        applyAppearance()
        overlay = OverlayController(model: model)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        icon?.size = NSSize(width: 22, height: 22)
        icon?.isTemplate = true
        icon?.accessibilityDescription = "Pet's Pet"
        statusItem.button?.image = icon ?? NSImage(systemSymbolName: "pawprint", accessibilityDescription: "Pet's Pet")
        statusItem.button?.toolTip = "Pet's Pet — 等待宠物"
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        sidebar.onChange = { [weak self] in self?.updateStatusHint() }
        sidebar.quotaProvider = { [weak self] in
            guard let self, self.componentEnabled, !self.suspended, self.componentPosition == .sidebarBottom else { return nil }
            return self.sidebarQuota.payload(for: self.model)
        }
        sidebar.setQuotaEnabled(componentPosition == .sidebarBottom && componentEnabled)
        sidebar.start()
        monitor.onChange = { [weak self] in self?.receive($0) }
        monitor.onGeometry = { [weak geometryStore = store] in geometryStore?.recordGeometry($0) }
        petClicks.onClick = { [weak self] in
            guard let self, self.componentPosition == .followPet else { return }
            self.toggleComponent()
        }
        petClicks.onDecision = { [weak self] decision in
            self?.store?.record(["event": "petClick", "decision": decision], event: true)
        }
        petClicks.onDrag = { [weak self] released in
            guard let self, self.componentPosition == .followPet, self.componentEnabled, !self.suspended else { return }
            self.monitor.dragActivity(released: released)
        }
        if componentPosition == .followPet { petClicks.start(); monitor.start() }
        fetch()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.now = Date()
                if !self.suspended { self.startupAnimation.recordWindowFrame() }
                self.presentPendingUpdateIfReady()
                if !self.suspended && !self.startup.isStarting && self.updates.isDue { self.checkForUpdates(manual: false) }
                if !self.suspended && (self.state.rect != nil || self.componentPosition == .sidebarBottom && self.componentEnabled) && Date().timeIntervalSince(self.lastFetch) >= 60 { self.fetch() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep(_:)), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake(_:)), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        configureStartup()
        beginStartup()
        if !startup.isStarting && componentPosition == .followPet && !AXIsProcessTrusted() { showSetup() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        suspended = true
        updates.cancel()
        clientLifecycle.cancel()
        startup.cancel(); startupAnimation.dismissImmediately(); mediaImportTask?.cancel()
        termination.beginCleanup { [sidebar] in await sidebar.shutdown() }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { petClicks.stop(); monitor.stop(); quota.stop(); dailyUsageTask?.cancel(); clock?.invalidate(); overlay?.hide() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { beginStartup(); return true }

    private var autoLaunchEnabled: Bool { UserDefaults.standard.object(forKey: CodexStartupController.autoLaunchKey) as? Bool ?? true }
    private var startupAnimationEnabled: Bool { UserDefaults.standard.object(forKey: CodexStartupController.animationKey) as? Bool ?? true }

    private func configureStartup() {
        startup.presentationReady = { [weak self] in self?.startupAnimation.readyForLaunch ?? true }
        startup.interfaceReady = { [weak self] in
            if let self, self.sidebar.connected { return self.sidebar.clientReady }
            return await CodexStartupEnvironment.accessibleInterfaceReady()
        }
        startup.onWillLaunch = { [weak self] in
            guard let self else { return [] }
            self.sidebar.authorizeStartupIfNeeded()
            self.sidebar.prepareForClientLaunch()
            return self.sidebar.startupArguments
        }
        startup.onPresent = { [weak self] in
            guard let self else { return }
            self.overlay.hide()
            self.sidebar.setQuotaEnabled(false)
            self.startupAnimation.dismissImmediately()
            if self.startupAnimationEnabled { self.showStartupAnimation(theme: self.startupTheme) }
        }
        startup.onFinish = { [weak self] success in
            guard let self else { return }
            self.startupAnimation.finish()
            self.sidebar.finishClientLaunch(success: success)
            guard !self.suspended else { return }
            self.sidebar.setQuotaEnabled(self.componentPosition == .sidebarBottom && self.componentEnabled)
            if self.componentPosition == .followPet {
                self.monitor.refresh()
                if success && !AXIsProcessTrusted() { self.showSetup() }
            }
            self.updateStatusHint()
        }
        startup.onWindowReady = { [weak self] in self?.startupAnimation.matchCurrentWindow() }
        startup.onError = { [weak self] message in self?.showStartupError(message) }
    }

    private func beginStartup() { startup.start(enabled: autoLaunchEnabled && !suspended, animated: startupAnimationEnabled) }

    private var canLaunchClient: Bool { !suspended && !sidebar.opening && startup.canStart }

    @objc private func launchClient() {
        guard canLaunchClient else { return }
        clientLifecycle.cancel()
        startup.start(enabled: true, animated: startupAnimationEnabled, launchPreparation: { [weak self] in
            self?.sidebar.prepareForClientLaunch(connect: true)
            return SidebarController.localConnectionArguments
        })
        updateOpenConnectionMenu()
    }

    @objc private func toggleAutoLaunch() {
        UserDefaults.standard.set(!autoLaunchEnabled, forKey: CodexStartupController.autoLaunchKey)
    }
    @objc private func toggleQuitWithClient() {
        clientLifecycle.setQuitWithClient(!clientLifecycle.quitWithClient)
    }
    @objc private func toggleStartupAnimation() {
        UserDefaults.standard.set(!startupAnimationEnabled, forKey: CodexStartupController.animationKey)
        if !startupAnimationEnabled { startupAnimation.dismissImmediately() }
    }
    @objc private func toggleStartupConnection() { sidebar.toggleStartupConnection() }
    private var startupTheme: StartupTheme {
        StartupTheme.resolve(model.appearance, systemDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    private func showStartupAnimation(theme: StartupTheme, preview: Bool = false) {
        startupAnimation.show(url: startupMedia?.url(for: theme), preview: preview, theme: theme)
    }
    @objc private func previewStartupAnimation(_ sender: NSMenuItem) {
        guard !startup.isStarting, !startupAnimation.isPreviewing, mediaImportTask == nil else { return }
        let theme = (sender.representedObject as? String).flatMap(StartupTheme.init(rawValue:)) ?? startupTheme
        showStartupAnimation(theme: theme, preview: true)
    }
    @objc private func endStartupPreview() {
        guard startupAnimation.isPreviewing else { return }
        startupAnimation.finish()
    }
    @objc private func resetStartupMedia(_ sender: NSMenuItem) {
        guard mediaImportTask == nil, !startup.isStarting,
              let raw = sender.representedObject as? String, let theme = StartupTheme(rawValue: raw) else { return }
        startupAnimation.dismissImmediately()
        startupMedia?.reset(for: theme)
    }
    @objc private func chooseStartupMedia(_ sender: NSMenuItem) {
        guard mediaImportTask == nil, !startup.isStarting, let startupMedia,
              let raw = sender.representedObject as? String, let theme = StartupTheme(rawValue: raw) else { return }
        let picker = NSOpenPanel()
        picker.title = "选择\(theme.title)启动动画"
        picker.message = "支持单文件 HTML、MOV、MP4 和 PNG。等比铺满、居中裁切。动画播放一次后停在末帧，Codex 就绪后结束。HTML 的图片和脚本需内嵌，可发送 splash:done 结束事件或声明 petspet-duration 秒数。上限 200 MB，PNG 不超过 4096 × 4096。"
        picker.allowedContentTypes = [.html, .quickTimeMovie, .mpeg4Movie, .png]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }
        mediaImportTask = Task { [weak self] in
            defer { self?.mediaImportTask = nil }
            do {
                try await startupMedia.importFile(url, for: theme)
                guard !Task.isCancelled, let self, !self.suspended, !self.startup.isStarting else { return }
                self.showStartupAnimation(theme: theme, preview: true)
            } catch {
                if !Task.isCancelled { self?.showStartupError("未能导入开场素材：\(error.localizedDescription)") }
            }
        }
    }
    private func showStartupError(_ message: String) {
        guard !suspended else { return }
        let alert = NSAlert()
        alert.messageText = "Pet’s Pet 启动设置"
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func receive(_ next: PetState) {
        guard !suspended, componentPosition == .followPet else { return }
        let wasVisible = state.rect != nil
        let phaseChanged = state.phase != next.phase
        state = next
        petClicks.updateTarget(processID: next.processID, windowID: next.petWindowID, rect: next.rect)
        let panelFrame = updateOverlay()
        if phaseChanged {
            updateStatusHint()
            setupStatus?.stringValue = next.phase
        }
        if !wasVisible && next.rect != nil && Date().timeIntervalSince(lastFetch) >= 10 { fetch() }
        let connection: [Int32] = [next.processID, next.axError, next.manualActivationError, next.chromiumActivationError, Int32(next.screenWindowCount), Int32(next.axWindowCount)]
        let event = next.phase != lastPhase || next.followingMode != lastFollowingMode || connection != lastConnection || (next.rect != lastRect || next.occupiedRect != lastOccupiedRect) && Date().timeIntervalSince(lastLog) >= 0.25
        if event || Date().timeIntervalSince(lastDiagnostics) >= 10 {
            var record: [String: Any] = ["state": next.phase, "accessibility": AXIsProcessTrusted(), "visible": panelFrame != nil,
                                       "scannedNodes": next.scannedNodes, "candidateCount": next.candidateCount, "windowCount": next.windowCount, "axError": next.axError,
                                       "quotaState": model.loading ? "loading" : model.error == nil ? "available" : "unavailable",
                                       "processID": next.processID, "screenWindowCount": next.screenWindowCount, "axWindowCount": next.axWindowCount,
                                       "manualActivationError": next.manualActivationError, "chromiumActivationError": next.chromiumActivationError,
                                       "componentEnabled": componentEnabled,
                                       "componentPosition": componentPosition.rawValue,
                                       "sidebarTokensEnabled": sidebar.tokensEnabled,
                                       "sidebarProjectsEnabled": sidebar.projectsEnabled,
                                       "sidebarConnected": sidebar.connected,
                                       "followingMode": next.followingMode, "deliveryDelayMs": next.deliveryDelayMs,
                                       "trackingHz": next.trackingHz, "positionReadMs": next.positionReadMs,
                                       "positionReadMaxMs": next.positionReadMaxMs, "scanMs": next.scanMs]
            if let rect = next.rect { record["pet"] = rectFields(rect) }
            if let bounds = next.occupiedRect { record["occupied"] = rectFields(bounds) }
            if let panelFrame { record["panel"] = rectFields(panelFrame) }
            store?.record(record, event: event)
            lastDiagnostics = Date()
            if event { lastLog = Date(); lastPhase = next.phase; lastFollowingMode = next.followingMode; lastRect = next.rect; lastOccupiedRect = next.occupiedRect; lastConnection = connection }
        }
    }
    private func rectFields(_ rect: CGRect) -> [String: Double] { ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height] }

    private func updateStatusHint() {
        statusItem.button?.toolTip = "Pet's Pet — \(componentPhase)\n\(sidebar.status)"
        updateOpenConnectionMenu()
    }

    private func updateOverlay() -> CGRect? {
        guard componentPosition == .followPet, componentEnabled, !suspended, !startup.isStarting else { overlay.hide(); return nil }
        return overlay.update(state)
    }

    @objc private func toggleComponentFromMenu() {
        petClicks.cancelPendingClick()
        toggleComponent()
    }

    private func toggleComponent() {
        componentEnabled.toggle()
        UserDefaults.standard.set(componentEnabled, forKey: "componentEnabled")
        sidebar.setQuotaEnabled(componentPosition == .sidebarBottom && componentEnabled && !startup.isStarting)
        if componentEnabled && componentPosition == .followPet {
            // Hidden components use 1 Hz tracking too. Confirm their current
            // position before showing, rather than flashing last second's frame.
            state.rect = nil; state.occupiedRect = nil
            monitor.refresh()
        } else { monitor.cancelDragActivity() }
        componentMenuItem?.state = componentEnabled ? .on : .off
        _ = updateOverlay()
        store?.record(["event": "componentVisibility", "componentEnabled": componentEnabled], event: true)
    }

    @objc private func fetch() {
        if !fetching {
            fetching = true
            lastFetch = Date()
            model.loading = true
            quota.refresh { [weak self] result in
                guard let self else { return }
                self.fetching = false
                self.model.loading = false
                switch result {
                case .success(let snapshot): self.model.snapshot = snapshot; self.model.error = nil
                case .failure(let error): self.model.snapshot = nil; self.model.error = error.localizedDescription
                }
                self.store?.record(["event": "quota", "available": self.model.error == nil], event: true)
                self.updateOpenDataMenu()
                self.sidebar.refreshQuota()
            }
        }
        if !dailyLoading {
            dailyLoading = true
            lastDailyAttempt = Date()
            dailyUsageTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.dailyUsageReader.read()
                    guard !Task.isCancelled else { return }
                    self.dailyUsage = DailyTokenUsageSnapshot(dayStart: result.dayStart, dayEnd: result.dayEnd,
                        timeZoneIdentifier: result.timeZoneIdentifier, input: result.usage.input,
                        cached: result.usage.cached, output: result.usage.output,
                        isComplete: result.isComplete, fetchedAt: result.fetchedAt)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.dailyUsage = nil
                }
                self.dailyLoading = false
                self.updateOpenDataMenu()
            }
        }
        updateOpenDataMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let now = Date()
        let quotaNeedsRefresh = model.snapshot == nil || model.snapshot?.isFresh(at: now) == false || model.snapshot?.resetCredits?.needsRefresh(at: now) == true
        let dailyNeedsRefresh = (dailyUsage == nil || dailyUsage?.isFresh(at: now) == false) && now.timeIntervalSince(lastDailyAttempt) >= 60
        if (!fetching && quotaNeedsRefresh) || (!dailyLoading && dailyNeedsRefresh) { fetch() }
        menu.removeAllItems()
        openMenu = menu
        label("Pet's Pet · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", in: menu, secondary: true, prominent: true)
        label(componentPhase, in: menu, secondary: true, prominent: true)
        menu.addItem(.separator())
        dataMenuItems = (0..<5).map { _ in label("", in: menu, prominent: true) }
        updatedMenuItem = label("", in: menu, secondary: true, prominent: true)
        dataStatusItem = label("", in: menu, secondary: true, prominent: true)
        item("立即刷新", #selector(fetch), in: menu)
        refreshMenuItem = menu.items.last
        menu.addItem(.separator())

        let display = submenu("显示设置", in: menu)
        item("显示额度组件", #selector(toggleComponentFromMenu), in: display)
        componentMenuItem = display.items.last
        componentMenuItem?.state = componentEnabled ? .on : .off
        let positions = submenu("显示位置", in: display)
        for choice in ComponentPosition.allCases {
            let option = NSMenuItem(title: choice.title, action: #selector(selectPosition(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = choice.rawValue
            option.state = choice == componentPosition ? .on : .off
            positions.addItem(option)
        }
        let contentChoices = submenu("组件内容", in: display)
        for choice in QuotaDisplayMode.allCases {
            let option = NSMenuItem(title: choice.title, action: #selector(selectContentMode(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = choice.rawValue
            option.state = choice == model.contentMode ? .on : .off
            contentChoices.addItem(option)
        }
        let choices = submenu("外观", in: display)
        for choice in AppearancePreference.allCases {
            let option = NSMenuItem(title: choice.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = choice.rawValue
            option.state = choice == model.appearance ? .on : .off
            choices.addItem(option)
        }
        display.addItem(.separator())
        item("显示对话用量色块", #selector(toggleSidebarTokens), in: display)
        display.items.last?.state = sidebar.tokensEnabled ? .on : .off
        item("显示项目文件夹大小", #selector(toggleProjectSizes), in: display)
        display.items.last?.state = sidebar.projectsEnabled ? .on : .off

        let connection = submenu("侧栏连接", in: menu)
        connectionMenuItem = menu.items.last
        connectionStatusItem = label("", in: connection, secondary: true)
        connectionTokenItem = label("", in: connection, secondary: true)
        connection.addItem(.separator())
        item("启用侧栏连接…", #selector(enableSidebarConnection), in: connection)
        enableConnectionItem = connection.items.last

        let launch = submenu("启动设置", in: menu)
        item("启动 ChatGPT", #selector(launchClient), in: launch)
        launchClientItem = launch.items.last
        launch.addItem(.separator())
        item("打开 Pet’s Pet 时启动 Codex", #selector(toggleAutoLaunch), in: launch)
        launch.items.last?.state = autoLaunchEnabled ? .on : .off
        item("ChatGPT 退出时退出 Pet’s Pet", #selector(toggleQuitWithClient), in: launch)
        launch.items.last?.state = clientLifecycle.quitWithClient ? .on : .off
        launch.items.last?.toolTip = "ChatGPT 退出时自动退出 Pet’s Pet；只关闭窗口不触发。退出 Pet’s Pet 不会关闭 ChatGPT。"
        item("显示启动动画", #selector(toggleStartupAnimation), in: launch)
        launch.items.last?.state = startupAnimationEnabled ? .on : .off
        item("启动时恢复侧栏连接…", #selector(toggleStartupConnection), in: launch)
        launch.items.last?.state = sidebar.startupConnectionAllowed ? .on : .off
        launch.addItem(.separator())
        label(mediaImportTask == nil ? "当前外观：\(startupTheme.title)" : "正在导入素材…", in: launch, secondary: true)
        for theme in StartupTheme.allCases {
            let group = submenu("\(theme.title)动画", in: launch)
            label("当前素材：\(startupMedia?.title(for: theme) ?? "默认动画")", in: group, secondary: true)
            item("选择\(theme.title)动画…", #selector(chooseStartupMedia(_:)), in: group)
            group.items.last?.representedObject = theme.rawValue
            group.items.last?.isEnabled = mediaImportTask == nil && !startup.isStarting
            item("预览\(theme.title)动画（播放一遍）", #selector(previewStartupAnimation(_:)), in: group)
            group.items.last?.representedObject = theme.rawValue
            group.items.last?.isEnabled = mediaImportTask == nil && !startup.isStarting && !startupAnimation.isPreviewing
            item("恢复默认\(theme.title)动画", #selector(resetStartupMedia(_:)), in: group)
            group.items.last?.representedObject = theme.rawValue
            group.items.last?.isEnabled = mediaImportTask == nil && !startup.isStarting && startupMedia?.selection(for: theme) != nil
        }
        item(startupAnimation.isPreviewing ? "结束预览" : "预览当前外观动画（播放一遍）",
             startupAnimation.isPreviewing ? #selector(endStartupPreview) : #selector(previewStartupAnimation(_:)), in: launch)
        launch.items.last?.isEnabled = mediaImportTask == nil && !startup.isStarting

        let tools = submenu("工具与诊断", in: menu)
        item("权限与检测状态…", #selector(showSetup), in: tools)
        item("重新检测宠物", #selector(rescan), in: tools)
        item("打开本地诊断文件夹", #selector(openDiagnostics), in: tools)
        menu.addItem(.separator())
        if let release = updates.available {
            item("发现更新 \(release.displayVersion)…", #selector(openReleasePage), in: menu)
        }
        item(updates.checking ? "正在检查更新…" : "检查更新…", #selector(checkForUpdatesFromMenu), in: menu)
        menu.items.last?.isEnabled = !updates.checking
        item("反馈问题…", #selector(reportIssue), in: menu)
        menu.items.last?.toolTip = "在浏览器中打开 GitHub Issues，附带应用和系统版本号"
        menu.addItem(.separator())
        item("退出 Pet's Pet", #selector(quit), in: menu, key: "q")
        updateOpenDataMenu()
        updateOpenConnectionMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        openMenu = nil
        dataMenuItems = []
        updatedMenuItem = nil; dataStatusItem = nil; refreshMenuItem = nil
        connectionMenuItem = nil; connectionStatusItem = nil; connectionTokenItem = nil; enableConnectionItem = nil
        componentMenuItem = nil; launchClientItem = nil
    }

    private func updateOpenDataMenu() {
        guard openMenu != nil else { return }
        let now = Date()
        let rows = QuotaMenu.rows(snapshot: model.error == nil ? model.snapshot : nil, mode: model.contentMode.resolved(for: model.snapshot), dailyUsage: dailyUsage, dailyLoading: dailyLoading, at: now)
        for (item, row) in zip(dataMenuItems, rows) { setLabel(row, on: item, prominent: true) }
        dataMenuItems[2].toolTip = DailyTokenUsageMenu(snapshot: dailyUsage, loading: dailyLoading, at: now).toolTip
        let formatter = DateFormatter(); formatter.timeStyle = .medium
        let dates = [model.snapshot?.fetchedAt, dailyUsage?.fetchedAt].compactMap { $0 }
        let updated = dates.min().map { formatter.string(from: $0) } ?? "--"
        if let item = updatedMenuItem {
            setLabel("数据更新于：\(updated)", on: item, secondary: true, prominent: true)
            item.toolTip = "额度：\(model.snapshot.map { formatter.string(from: $0.fetchedAt) } ?? "暂不可用")\n每日 Token：\(dailyUsage.map { formatter.string(from: $0.fetchedAt) } ?? "暂不可用")"
        }
        if let item = dataStatusItem {
            let status = model.error ?? (fetching ? "正在读取额度…" : "")
            setLabel(status, on: item, secondary: true, prominent: true)
            item.isHidden = status.isEmpty
        }
        refreshMenuItem?.isEnabled = !fetching && !dailyLoading
    }

    private func updateOpenConnectionMenu() {
        guard openMenu != nil else { return }
        connectionMenuItem?.title = "侧栏连接（\(sidebar.connected ? "已连接" : "未连接")）"
        if let item = connectionStatusItem { setLabel(sidebar.status, on: item, secondary: true) }
        if let item = connectionTokenItem {
            setLabel(sidebar.tokenStatus, on: item, secondary: true)
            item.isHidden = sidebar.tokenStatus.isEmpty
        }
        enableConnectionItem?.isEnabled = !startup.isStarting && !sidebar.opening && !sidebar.connected && sidebar.hasEnabledFeatures
        launchClientItem?.isEnabled = canLaunchClient
    }

    private func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(); child.autoenablesItems = false
        item.submenu = child
        menu.addItem(item)
        return child
    }
    @objc private func toggleSidebarTokens() { sidebar.setTokens(!sidebar.tokensEnabled) }
    @objc private func toggleProjectSizes() { sidebar.setProjects(!sidebar.projectsEnabled) }
    @objc private func enableSidebarConnection() { sidebar.enableConnection() }

    private var componentPhase: String {
        if startup.isStarting { return "正在打开 Codex…" }
        guard componentPosition == .sidebarBottom else { return state.phase }
        if !componentEnabled { return "侧栏底部组件已隐藏" }
        if !sidebar.connected { return "侧栏底部：等待侧栏连接" }
        return sidebar.quotaStatus
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = ComponentPosition(rawValue: raw), choice != componentPosition else { return }
        componentPosition = choice
        UserDefaults.standard.set(choice.rawValue, forKey: ComponentPosition.defaultsKey)
        petClicks.cancelPendingClick(); monitor.cancelDragActivity()
        overlay.hide()
        sidebar.setQuotaEnabled(choice == .sidebarBottom && componentEnabled && !startup.isStarting)
        state.rect = nil; state.occupiedRect = nil
        if choice == .followPet && !suspended { petClicks.start(); monitor.start(); monitor.refresh() }
        else { petClicks.stop(); monitor.stop() }
        store?.record(["event": "componentPosition", "position": choice.rawValue], event: true)
        updateStatusHint()
    }

    @objc private func selectContentMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = QuotaDisplayMode(rawValue: raw) else { return }
        model.contentMode = choice
        UserDefaults.standard.set(choice.rawValue, forKey: QuotaDisplayMode.defaultsKey)
        sidebar.refreshQuota()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AppearancePreference(rawValue: raw) else { return }
        model.appearance = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "appearance")
        applyAppearance()
        sidebar.refreshQuota()
    }
    private func applyAppearance() {
        switch model.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    @objc private func codexChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.openai.codex" else { return }
        overlay.hide()
        state.rect = nil; state.occupiedRect = nil
        petClicks.updateTarget(processID: 0, windowID: nil, rect: nil)
        if componentPosition == .followPet { monitor.rescan() }
        sidebar.clientDidChange()
        updateOpenConnectionMenu()
        if notification.name == NSWorkspace.didTerminateApplicationNotification {
            clientLifecycle.clientDidTerminate(bundleIdentifier: app.bundleIdentifier, processID: app.processIdentifier,
                                               restartingProcessID: sidebar.restartingClientProcessID)
        }
    }
    @discardableResult private func label(_ title: String, in menu: NSMenu, secondary: Bool = false, prominent: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        setLabel(title, on: item, secondary: secondary, prominent: prominent)
        menu.addItem(item)
        return item
    }
    private func setLabel(_ title: String, on item: NSMenuItem, secondary: Bool = false, prominent: Bool = false) {
        item.title = title
        // Explicit semantic colors keep read-only information legible without
        // turning it into a clickable action. The system still draws the menu.
        let color: NSColor
        if prominent {
            color = NSColor.labelColor.withAlphaComponent(secondary ? 0.88 : 1)
        } else {
            color = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor.withAlphaComponent(0.82)
        }
        item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color])
    }
    private func item(_ title: String, _ action: Selector, in menu: NSMenu, key: String = "") { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item) }
    @objc private func rescan() {
        state.rect = nil; state.occupiedRect = nil
        petClicks.updateTarget(processID: 0, windowID: nil, rect: nil)
        overlay.hide()
        if componentPosition == .followPet { monitor.rescan() }
    }
    @objc private func quit() { termination.request() }
    @objc private func openDiagnostics() { if let store { NSWorkspace.shared.open(store.directory) } }

    @objc private func checkForUpdatesFromMenu() { checkForUpdates(manual: true) }
    private func checkForUpdates(manual: Bool) {
        updates.check(manual: manual) { [weak self] _ in self?.presentPendingUpdateIfReady() }
    }
    private func presentPendingUpdateIfReady() {
        let ready = !suspended && userSessionActive && !startup.isStarting && !startupAnimation.isPreviewing && openMenu == nil && NSApp.modalWindow == nil
        guard let notice = updates.takeNotice(ready: ready) else { return }
        switch notice {
        case .available(let release): self.showUpdateAvailable(release)
        case .upToDate:
            showUpdateMessage("未发现可用更新", "当前版本 \(updates.currentDescription)。未发现更高版本或更新构建。")
        case .failed(let message):
            showUpdateMessage("暂时无法检查更新", "\(message)\n可稍后重试，或到 GitHub 发布页查看。")
        }
    }
    private func showUpdateAvailable(_ release: LatestRelease) {
        let alert = NSAlert()
        alert.messageText = "发现更新 \(release.displayVersion)"
        alert.informativeText = "当前版本 \(updates.currentDescription)。\n\(release.title)\n\n可前往下载页查看更新内容并手动下载、安装。"
        alert.addButton(withTitle: "前往下载页")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }
    private func showUpdateMessage(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func openReleasePage() { if let page = updates.available?.page { NSWorkspace.shared.open(page) } }
    @objc private func reportIssue() {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        NSWorkspace.shared.open(FeedbackLink.newIssue(appVersion: updates.currentDescription,
                                                      systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"))
    }
    @objc private func sleep(_ notification: Notification) {
        if notification.name == NSWorkspace.sessionDidResignActiveNotification { userSessionActive = false }
        suspended = true
        startup.cancel(); startupAnimation.dismissImmediately()
        dailyUsageTask?.cancel(); dailyLoading = false
        sidebar.setPaused(true)
        state.rect = nil; state.occupiedRect = nil
        petClicks.stop(); monitor.stop(); overlay.hide()
    }
    @objc private func wake(_ notification: Notification) {
        if notification.name == NSWorkspace.sessionDidBecomeActiveNotification { userSessionActive = true }
        suspended = false
        sidebar.setQuotaEnabled(componentPosition == .sidebarBottom && componentEnabled)
        sidebar.setPaused(false)
        if componentPosition == .followPet { petClicks.start(); monitor.stop(); monitor.rescan(); monitor.start() }
        fetch()
        presentPendingUpdateIfReady()
    }

    @objc private func showSetup() {
        if setupWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 305), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pet's Pet"
            window.isReleasedWhenClosed = false
            let heading = NSTextField(labelWithString: "宠物去哪，Pet's Pet 就去哪。")
            heading.font = .systemFont(ofSize: 21, weight: .semibold)
            let explanation = NSTextField(wrappingLabelWithString: "请在系统设置中允许 Pet's Pet 使用辅助功能，以读取宠物的位置和显示状态。组件不抢焦点，鼠标可以直接穿透。\n\n授权后，请在 Codex 中显示宠物。额度通过 Codex 自带的官方服务读取；不会发起模型任务。")
            explanation.font = .systemFont(ofSize: 13)
            let status = NSTextField(labelWithString: state.phase)
            status.font = .systemFont(ofSize: 12, weight: .medium)
            setupStatus = status
            let button = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAccessibility))
            button.bezelStyle = .rounded
            let done = NSButton(title: "完成", target: self, action: #selector(closeSetup)); done.bezelStyle = .rounded
            let buttons = NSStackView(views: [button, done]); buttons.orientation = .horizontal; buttons.spacing = 12
            let stack = NSStackView(views: [heading, explanation, status, buttons])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(stack)
            if let content = window.contentView { NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)]) }
            window.center()
            setupWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func closeSetup() { setupWindow?.close() }
    @objc private func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    private func showStorageError() {
        let alert = NSAlert(); alert.messageText = "无法创建 Pet's Pet 数据目录"
        alert.informativeText = "请检查 ~/Library/Application Support/PetsPet/ 的访问权限后重新打开。"
        alert.runModal(); termination.request()
    }
}
