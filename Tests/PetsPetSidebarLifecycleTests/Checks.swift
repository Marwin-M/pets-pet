import Foundation
import PetsPetSidebar

private var assertions = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1
    guard value() else { throw NSError(domain: "SidebarLifecycleChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct SidebarLifecycleChecks {
    @MainActor static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(condition(), message)
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetsPetLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let portFile = root.appendingPathComponent("port")
        let offline = portFile.appendingPathExtension("offline")
        let requests = portFile.appendingPathExtension("requests")
        func requestCount() -> Int { Int((try? String(contentsOf: requests, encoding: .utf8)) ?? "") ?? 0 }
        try Data().write(to: offline)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PetsPetSidebarTests/fixture.py")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() }; server.waitUntilExit() }
        try await waitUntil("isolated server starts") { FileManager.default.fileExists(atPath: portFile.path) }
        let port = Int(try String(contentsOf: portFile, encoding: .utf8))!
        let suite = "PetsPetLifecycle-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = SidebarController(preferences: preferences, discovery: SidebarDiscovery(port: port), refreshInterval: 40_000_000)

        try check(controller.startupArguments.isEmpty, "startup never enables page debugging without saved consent")
        preferences.set(true, forKey: SidebarController.startupConnectionKey)
        try check(controller.startupArguments == SidebarController.localConnectionArguments, "saved consent enables loopback-only launch arguments")
        controller.toggleStartupConnection()
        try check(!controller.startupConnectionAllowed && controller.startupArguments.isEmpty, "revoking startup consent clears arguments without opening Codex")

        controller.start()
        try await waitUntil("startup failure is reported") { controller.needsConnection }
        try check(!controller.connected && !controller.opening, "a failed probe never launches a restart workflow")
        let first = requestCount()
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(first == 1 && requestCount() == first, "startup failure stops instead of periodically probing")

        controller.clientDidChange()
        try await waitUntil("lifecycle event makes one new probe") { requestCount() == first + 1 }
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(requestCount() == first + 1, "lifecycle failure does not start a retry timer")

        try FileManager.default.removeItem(at: offline)
        controller.clientDidChange()
        try await waitUntil("available endpoint connects") { controller.connected }
        let connectedAt = requestCount()
        try await waitUntil("connected data continues refreshing") { requestCount() >= connectedAt + 2 }
        try Data().write(to: offline)
        try await waitUntil("transport loss is reported") { !controller.connected && controller.needsConnection }
        let disconnectedAt = requestCount()
        try await Task.sleep(nanoseconds: 250_000_000)
        try check(requestCount() == disconnectedAt, "transport loss stops refresh and does not retry")

        controller.setPaused(true)
        try await waitUntil("sleep clears connection state") { controller.status == "侧栏：已暂停" }
        try check(!controller.connected && !controller.needsConnection, "paused state has no active connection")
        try FileManager.default.removeItem(at: offline)
        let pausedAt = requestCount()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(requestCount() == pausedAt, "sleep performs no discovery")
        controller.setPaused(false)
        try await waitUntil("wake can attach to an available endpoint once") { controller.connected }

        controller.setTokens(false)
        controller.setProjects(false)
        try await waitUntil("disabling both features cleans up") { controller.status == "侧栏：Pet’s Pet 显示已关闭" }
        let disabledAt = requestCount()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(requestCount() == disabledAt, "disabled features perform no discovery")
        try check(!preferences.bool(forKey: "sidebarTokensEnabled") && !preferences.bool(forKey: "sidebarProjectsEnabled"), "feature choices remain saved")

        preferences.set(true, forKey: SidebarController.startupConnectionKey)
        try check(controller.startupArguments.isEmpty, "disabled sidebar features do not request a debugging endpoint despite saved consent")

        controller.quotaProvider = { ["light": "data:image/png;base64,aA==", "dark": "data:image/png;base64,aA==", "label": "quota fixture"] }
        controller.setQuotaEnabled(true)
        try await waitUntil("fixed quota connects with both existing sidebar features off") { controller.connected && controller.quotaStatus.contains("固定在侧栏底部") }
        try check(controller.hasEnabledFeatures && !controller.tokensEnabled && !controller.projectsEnabled, "fixed quota independently owns connection demand")
        let options = try JSONSerialization.jsonObject(with: Data(contentsOf: portFile.appendingPathExtension("options"))) as! [String: Bool]
        try check(options["quota"] == true && options["tokens"] == false && options["projects"] == false, "fixed quota is sent without re-enabling the other features")
        controller.setPaused(true)
        try await waitUntil("fixed quota pauses with sleep") { !controller.connected && controller.status == "侧栏：已暂停" }
        controller.setPaused(false)
        try await waitUntil("fixed quota resumes without a pet") { controller.connected }
        try Data().write(to: offline)
        try await waitUntil("fixed quota detects transport loss") { !controller.connected && controller.needsConnection }
        let quotaDisconnectedAt = requestCount()
        controller.refreshQuota()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(requestCount() == quotaDisconnectedAt, "quota data updates do not retry or restart an offline client")
        controller.setQuotaEnabled(false)
        try await waitUntil("leaving fixed mode cleans up quota-only connection") { controller.status == "侧栏：Pet’s Pet 显示已关闭" }
        try FileManager.default.removeItem(at: offline)

        // Simulate an authorized cold launch: the endpoint can appear after the process notification.
        try Data().write(to: offline)
        controller.setTokens(true)
        try await waitUntil("initial cold-start probe fails before endpoint exists") { controller.needsConnection }
        controller.prepareForClientLaunch()
        controller.clientDidChange()
        let beforeReady = requestCount()
        try await waitUntil("authorized startup owns bounded readiness retries") { requestCount() >= beforeReady + 2 }
        let unready = portFile.appendingPathExtension("unready")
        try Data().write(to: unready)
        try FileManager.default.removeItem(at: offline)
        try await waitUntil("delayed endpoint restores saved sidebar features") { controller.connected }
        try check(!controller.clientReady, "transport connection alone does not claim a loaded main interface")
        try FileManager.default.removeItem(at: unready)
        try await waitUntil("client readiness follows delayed interface hydration") { controller.clientReady }
        controller.finishClientLaunch(success: true)
        try Data().write(to: offline)
        try await waitUntil("startup connection still stops after later transport loss") { !controller.connected }
        let afterStartupLoss = requestCount()
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(requestCount() == afterStartupLoss, "startup does not become an unlimited reconnect service")
        try FileManager.default.removeItem(at: offline)

        controller.setTokens(true)
        try await waitUntil("explicitly enabling a feature can connect") { controller.connected }
        await controller.shutdown()
        let stoppedAt = requestCount()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(!controller.connected && requestCount() == stoppedAt, "shutdown stops all connection work")

        // A click on manual connected launch grants this launch only, without changing future cold-start consent.
        preferences.set(false, forKey: SidebarController.startupConnectionKey)
        try Data().write(to: offline)
        let manual = SidebarController(preferences: preferences, discovery: SidebarDiscovery(port: port), refreshInterval: 40_000_000)
        manual.start()
        try await waitUntil("manual launch begins with an offline client") { manual.needsConnection }
        manual.prepareForClientLaunch(connect: true)
        manual.clientDidChange()
        let manualBeforeReady = requestCount()
        try await waitUntil("explicit manual launch owns its bounded connection wait") { requestCount() >= manualBeforeReady + 2 }
        try check(!manual.startupConnectionAllowed && manual.startupArguments.isEmpty,
                  "manual launch does not grant consent to future automatic launches")
        try FileManager.default.removeItem(at: offline)
        try await waitUntil("manual launched endpoint restores enabled sidebar features") { manual.connected && manual.clientReady }
        await manual.shutdown()
        print("Sidebar lifecycle checks passed: \(assertions) assertions (real controller, isolated HTTP/WebSocket; no Codex launch or quit).")
    }
}
