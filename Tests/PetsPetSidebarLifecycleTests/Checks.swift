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

        controller.setTokens(true)
        try await waitUntil("explicitly enabling a feature can connect") { controller.connected }
        await controller.shutdown()
        let stoppedAt = requestCount()
        try await Task.sleep(nanoseconds: 200_000_000)
        try check(!controller.connected && requestCount() == stoppedAt, "shutdown stops all connection work")
        print("Sidebar lifecycle checks passed: \(assertions) assertions (real controller, isolated HTTP/WebSocket; no Codex launch or quit).")
    }
}
