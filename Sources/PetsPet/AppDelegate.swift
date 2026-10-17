import AppKit
import ApplicationServices
import SwiftUI
import PetsPetCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = DisplayModel()
    private let monitor = PetMonitor()
    private let petClicks = PetClickMonitor()
    private let quota = QuotaClient()
    private let sidebar = SidebarController()
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
    private var componentEnabled = true
    private var componentMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.marwin.petspet")
        if peers.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { NSApp.terminate(nil); return }
        do { store = try SupportStore() }
        catch { showStorageError(); return }
        model.appearance = AppearancePreference(savedValue: UserDefaults.standard.string(forKey: "appearance"))
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
        sidebar.start()
        monitor.onChange = { [weak self] in self?.receive($0) }
        monitor.onGeometry = { [weak geometryStore = store] in geometryStore?.recordGeometry($0) }
        petClicks.onClick = { [weak self] in self?.toggleComponent() }
        petClicks.onDecision = { [weak self] decision in
            self?.store?.record(["event": "petClick", "decision": decision], event: true)
        }
        petClicks.onDrag = { [weak self] released in
            guard let self, self.componentEnabled, !self.suspended else { return }
            self.monitor.dragActivity(released: released)
        }
        petClicks.start()
        monitor.start()
        fetch()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.now = Date()
                if !self.suspended && self.state.rect != nil && Date().timeIntervalSince(self.lastFetch) >= 60 { self.fetch() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexChanged(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(codexChanged(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if !AXIsProcessTrusted() { showSetup() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { await sidebar.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { petClicks.stop(); monitor.stop(); quota.stop(); clock?.invalidate(); overlay?.hide() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSetup(); return true }

    private func receive(_ next: PetState) {
        guard !suspended else { return }
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
        statusItem.button?.toolTip = "Pet's Pet — \(state.phase)\n\(sidebar.status)"
    }

    private func updateOverlay() -> CGRect? {
        guard componentEnabled, !suspended else { overlay.hide(); return nil }
        return overlay.update(state)
    }

    @objc private func toggleComponentFromMenu() {
        petClicks.cancelPendingClick()
        toggleComponent()
    }

    private func toggleComponent() {
        componentEnabled.toggle()
        if componentEnabled {
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
        guard !fetching else { return }
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
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !fetching && (model.snapshot == nil || model.snapshot?.isFresh(at: Date()) == false || model.snapshot?.resetCredits?.needsRefresh(at: Date()) == true) { fetch() }
        menu.removeAllItems()
        label("Pet's Pet · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")", in: menu, secondary: true)
        label(state.phase, in: menu, secondary: true)
        menu.addItem(.separator())
        item("显示额度组件", #selector(toggleComponentFromMenu), in: menu)
        componentMenuItem = menu.items.last
        componentMenuItem?.state = componentEnabled ? .on : .off
        menu.addItem(.separator())
        item(sidebar.needsConnection && sidebar.tokensEnabled ? "显示对话用量色块（待连接）" : "显示对话用量色块", #selector(toggleSidebarTokens), in: menu)
        menu.items.last?.state = sidebar.tokensEnabled ? .on : .off
        item(sidebar.needsConnection && sidebar.projectsEnabled ? "显示项目文件夹大小（待连接）" : "显示项目文件夹大小", #selector(toggleProjectSizes), in: menu)
        menu.items.last?.state = sidebar.projectsEnabled ? .on : .off
        label(sidebar.status, in: menu, secondary: true)
        if !sidebar.tokenStatus.isEmpty { label(sidebar.tokenStatus, in: menu, secondary: true) }
        item("启用侧栏连接…", #selector(enableSidebarConnection), in: menu)
        menu.items.last?.isEnabled = !sidebar.opening && !sidebar.connected && (sidebar.tokensEnabled || sidebar.projectsEnabled)
        menu.addItem(.separator())
        if model.loading { label("正在读取额度…", in: menu, secondary: true) }
        if let error = model.error { label(error, in: menu) }
        for row in QuotaMenu.rows(snapshot: model.error == nil ? model.snapshot : nil, at: Date()) { label(row, in: menu) }
        if let fetched = model.snapshot?.fetchedAt {
            let formatter = DateFormatter(); formatter.timeStyle = .medium
            label("额度更新于 \(formatter.string(from: fetched))", in: menu, secondary: true)
        }
        menu.addItem(.separator())
        item("立即刷新额度", #selector(fetch), in: menu)
        menu.items.last?.isEnabled = !fetching
        let appearance = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for choice in AppearancePreference.allCases {
            let option = NSMenuItem(title: choice.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = choice.rawValue
            option.state = choice == model.appearance ? .on : .off
            choices.addItem(option)
        }
        appearance.submenu = choices
        menu.addItem(appearance)
        menu.addItem(.separator())
        item("权限与检测状态…", #selector(showSetup), in: menu)
        item("重新检测宠物", #selector(rescan), in: menu)
        item("打开本地诊断文件夹", #selector(openDiagnostics), in: menu)
        menu.addItem(.separator())
        item("退出 Pet's Pet", #selector(quit), in: menu, key: "q")
    }
    @objc private func toggleSidebarTokens() { sidebar.setTokens(!sidebar.tokensEnabled) }
    @objc private func toggleProjectSizes() { sidebar.setProjects(!sidebar.projectsEnabled) }
    @objc private func enableSidebarConnection() { sidebar.enableConnection() }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AppearancePreference(rawValue: raw) else { return }
        model.appearance = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "appearance")
        applyAppearance()
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
        monitor.rescan()
        sidebar.clientDidChange()
    }
    private func label(_ title: String, in menu: NSMenu, secondary: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        // Explicit semantic colors keep read-only information legible without
        // turning it into a clickable action. The system still draws the menu.
        let color = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor.withAlphaComponent(0.82)
        item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color])
        menu.addItem(item)
    }
    private func item(_ title: String, _ action: Selector, in menu: NSMenu, key: String = "") { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item) }
    @objc private func rescan() {
        state.rect = nil; state.occupiedRect = nil
        petClicks.updateTarget(processID: 0, windowID: nil, rect: nil)
        overlay.hide()
        monitor.rescan()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openDiagnostics() { if let store { NSWorkspace.shared.open(store.directory) } }
    @objc private func sleep() {
        suspended = true
        sidebar.setPaused(true)
        state.rect = nil; state.occupiedRect = nil
        petClicks.stop(); monitor.stop(); overlay.hide()
    }
    @objc private func wake() { suspended = false; sidebar.setPaused(false); petClicks.start(); monitor.stop(); monitor.rescan(); monitor.start(); fetch() }

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
        alert.runModal(); NSApp.terminate(nil)
    }
}
