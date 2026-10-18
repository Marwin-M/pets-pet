import Foundation
import Darwin
import SQLite3
import JavaScriptCore
import PetsPetSidebar

private var assertions = 0
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw NSError(domain: "SidebarChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func rejects(_ work: () throws -> Void, _ message: String) throws {
    assertions += 1
    do { try work() } catch { return }
    throw NSError(domain: "SidebarChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}
private func database(_ file: URL, sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw SidebarError.database }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SidebarError.database }
}

@main struct Checks {
    @MainActor static func quotaAlignment() throws {
        // Execute the production geometry function in the system JS engine;
        // this does not open a browser or assert that DOM integration was tested.
        let source = try SidebarScript.load()
        let start = source.range(of: "  function validQuotaPayload(")!.lowerBound
        let end = source.range(of: "\n  function paintQuota()")!.lowerBound
        let context = JSContext()!
        context.evaluateScript(String(source[start..<end]))
        let function = context.objectForKeyedSubscript("quotaBottomOffset")!
        let validPayload = context.objectForKeyedSubscript("validQuotaPayload")!
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Previews/Assets")
        for name in ["current", "pro", "loading", "error"] {
            let light = "data:image/png;base64," + (try Data(contentsOf: assets.appendingPathComponent("position-\(name).png"))).base64EncodedString()
            let dark = "data:image/png;base64," + (try Data(contentsOf: assets.appendingPathComponent("position-\(name)-dark.png"))).base64EncodedString()
            try check(validPayload.call(withArguments: [["light": light, "dark": dark, "label": "review"]])!.toBool(), "\(name) preview's actual images pass production validation")
        }
        let oversized = "data:image/png;base64," + (try Data(contentsOf: assets.appendingPathComponent("current.png"))).base64EncodedString()
        try check(!validPayload.call(withArguments: [["light": oversized, "dark": oversized, "label": "review"]])!.toBool(), "original 3× preview images reproduce the size rejection")
        for bad in ["https://example.com/image.png", "data:text/html;base64,aA==", "data:image/png;base64,<bad>"] {
            try check(!validPayload.call(withArguments: [["light": bad, "dark": bad, "label": "review"]])!.toBool(), "invalid or external images stay rejected")
        }
        for (root, avatar, expected) in [(477.0, 465.0, 4.0), (540, 528, 4), (-100, -112, 4), (477.5, 465.25, 4.25), (500, 492, 0), (500, 412, 80)] {
            let result = function.call(withArguments: [root, avatar])!
            try check(!result.isNull && result.toDouble() == expected, "body offset tracks avatar at \(root)/\(avatar)")
            try check(root - result.toDouble() - 8 == avatar, "visible body bottom, not transparent PNG edge, aligns")
        }
        for (root, avatar) in [(500.0, 493.0), (500, 411), (.infinity, 480), (500, .nan)] {
            try check(function.call(withArguments: [root, avatar])!.isNull, "unusable or invalid avatar geometry stays hidden")
        }
        try check(context.exception == nil, "production geometry executes without JavaScript errors")
    }

    @MainActor static func main() async throws {
        try quotaAlignment()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetsPetSidebarChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        assertions += try await DailyUsageChecks.run(root: root)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let ids = (0..<6).map { _ in UUID().uuidString.lowercased() }
        let db = home.appendingPathComponent("state_5.sqlite")
        try database(db, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, tokens_used);" +
                     "INSERT INTO threads VALUES ('\(ids[0])',2015400),('\(ids[1])',0),('\(ids[2])',-1),('\(ids[3])',NULL),('\(ids[4])','123'),('\(ids[5])',9007199254740992);")
        let reader = LocalUsageReader(home: home)
        let values = try reader.read(ids + [ids[0].uppercased(), "x' OR 1=1--"])
        try check(values == [ids[0]: 2015400, ids[1]: 0], "real integer counts including zero; invalid/unknown counts excluded")
        let unchanged = try Data(contentsOf: db)
        _ = try reader.read(ids)
        try check(try Data(contentsOf: db) == unchanged, "reader does not alter database")
        try check(try reader.read([UUID().uuidString]).isEmpty, "missing thread is not zero")
        let newer = home.appendingPathComponent("state_10.sqlite")
        try database(newer, sql: "CREATE TABLE threads (id TEXT, tokens_used INTEGER); INSERT INTO threads VALUES ('\(ids[0])',42);")
        try check(try reader.read(ids)[ids[0]] == 42, "numeric newest schema wins")
        try database(newer, sql: "DROP TABLE threads")
        try rejects({ _ = try reader.read(ids) }, "broken new schema must not show old totals")
        let missing = LocalUsageReader(home: root.appendingPathComponent("absent"))
        try rejects({ _ = try missing.read(ids) }, "missing database is an error")
        try check(!FileManager.default.fileExists(atPath: missing.home.path), "missing database is never created")

        try check(LocalProject(id: "p", roots: ["relative"]) == nil, "relative root rejected")
        try check(LocalProject(id: "p", roots: ["/tmp/a\0b"]) == nil, "NUL rejected")
        try check(LocalProject(id: "p", roots: Array(repeating: "/tmp", count: 9)) == nil, "no partial multi-root measurement")
        try check(LocalProject.uniqueRoots(["/tmp/a", "/tmp/ab", "/tmp/a/sub", "/tmp/a"]) == ["/tmp/a", "/tmp/ab"], "deduplicate nested roots with path boundary")
        let folder = root.appendingPathComponent("folder with ' quotes")
        let child = folder.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 32768).write(to: child.appendingPathComponent(".hidden-file"))
        let bytes = try ProjectDiskUsage.measure([folder.path])
        try check(bytes == 32768, "logical bytes include hidden files, excluding directory allocation")
        try check(try ProjectDiskUsage.measure([folder.path, child.path]) == bytes, "nested root not double counted")
        try rejects({ _ = try ProjectDiskUsage.measure([folder.path, root.appendingPathComponent("deleted").path]) }, "incomplete multi-root results rejected")
        try rejects({ _ = try ProjectDiskUsage.measure([folder.path], cancelled: { true }) }, "cancelled scans stop")
        try rejects({ _ = try ProjectDiskUsage.measure([folder.path], timeout: 0) }, "timeout is not zero bytes")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        try check(try ProjectDiskUsage.measure([alias.path, folder.path]) == bytes, "symlink alias counted once")
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try check(try ProjectDiskUsage.measure([empty.path]) == 0, "empty folder has zero logical bytes")
        let hardlink = child.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: child.appendingPathComponent(".hidden-file"), to: hardlink)
        try check(try ProjectDiskUsage.measure([folder.path]) == bytes * 2, "hard links counted per entry as in Finder")
        let external = root.appendingPathComponent("external")
        try Data(repeating: 66, count: 10000).write(to: external)
        let link = child.appendingPathComponent("外部链接")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../external")
        let broken = child.appendingPathComponent("broken")
        try FileManager.default.createSymbolicLink(atPath: broken.path, withDestinationPath: "missing")
        let loop = child.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: "..")
        try check(try ProjectDiskUsage.measure([folder.path]) == bytes * 2 + 14 + 7 + 2, "symlinks count own bytes; targets, broken links and cycles are not followed")
        let sparse = empty.appendingPathComponent("sparse")
        try Data().write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 10_000_000)
        try handle.close()
        try check(try ProjectDiskUsage.measure([empty.path]) == 10_000_000, "sparse files use logical length rather than disk blocks")
        try check(try ProjectDiskUsage.measure([folder.path, empty.path]) == bytes * 2 + 23 + 10_000_000, "distinct project roots are summed completely")
        let denied = root.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data([1]).write(to: denied.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        try rejects({ _ = try ProjectDiskUsage.measure([folder.path, denied.path]) }, "permission failure never returns a partial total")
        var checks = 0
        try rejects({ _ = try ProjectDiskUsage.measure([folder.path], cancelled: { checks += 1; return checks > 2 }) }, "cancellation during traversal stops without returning partial bytes")
        // Restore the original fixture before exercising its asynchronous cache.
        for item in [hardlink, link, broken, loop] { try FileManager.default.removeItem(at: item) }
        let scanner = ProjectSizeScanner()
        let project = LocalProject(id: "p", roots: [folder.path])!
        let initial = scanner.snapshot([project])
        try check((initial["p"] as? [String: Any])?["state"] as? String == "pending", "scan begins pending")
        var final: [String: Any] = [:]
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            final = scanner.snapshot([project])["p"] as? [String: Any] ?? [:]
            if final["state"] as? String == "ready" { break }
        }
        try check(final["bytes"] as? Int64 == bytes, "scan completes with actual logical size")
        try check((scanner.snapshot([project], at: Date().addingTimeInterval(301))["p"] as? [String: Any])?["stale"] as? Bool == true, "expired cache is marked refreshing")
        scanner.cancel()
        let moved = LocalProject(id: "p", roots: [root.appendingPathComponent("moved").path])!
        let changed = scanner.snapshot([moved])["p"] as? [String: Any]
        try check(changed?["state"] as? String == "pending", "changed path never inherits old size")
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if (scanner.snapshot([moved])["p"] as? [String: Any])?["state"] as? String == "error" { break }
        }
        try check((scanner.snapshot([moved])["p"] as? [String: Any])?["state"] as? String == "error", "missing directory yields explicit error")
        scanner.cancel()

        let discovery = SidebarDiscovery()
        try check(discovery.allows(URL(string: "ws://127.0.0.1:39222/devtools/page/test")!), "loopback websocket accepted")
        for raw in ["ws://example.com:39222/", "ws://127.0.0.1:9999/", "wss://127.0.0.1:39222/", "ws://user@127.0.0.1:39222/"] {
            try check(!discovery.allows(URL(string: raw)!), "reject untrusted socket: \(raw)")
        }
        let script = try SidebarScript.load()
        try check(script.contains("__petsPetSidebar"), "packaged production UI resource loads")
        try await breakdownChecks(home)
        try await protocolChecks(root)
        print("Sidebar checks passed: \(assertions) assertions (database, token breakdown, disk usage, cache, endpoint policy, real HTTP/WebSocket protocol).")
    }

    static func breakdownChecks(_ home: URL) async throws {
        let area = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let file = area.appendingPathComponent("usage.jsonl")
        func event(_ input: Any, _ cached: Any, _ output: Any, _ total: Any) throws -> Data {
            var bytes = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output, "total_tokens": total]]]])
            bytes.append(10); return bytes
        }
        let reader = UsageDetailsReader(home: home)
        let record = ["thread": LocalUsageRecord(total: 200, rollout: file.path)]
        var bytes = try event(80, 20, 20, 100)
        bytes.append(try event(150, 60, 50, 200))
        try bytes.write(to: file)
        let first = await reader.read(record)
        try check(first["thread"] == TokenBreakdown(input: 150, cached: 60, output: 50, total: 200), "latest cumulative detail used, not a sum of cumulative events")
        try check(first["thread"]?.uncached == 90, "uncached input subtracts cache once")
        let cached = await reader.read(record, byteBudget: 0)
        try check(cached == first, "unchanged usage files need no additional reads")
        let mismatch = await reader.read(["thread": LocalUsageRecord(total: 300, rollout: file.path)])
        try check(mismatch.isEmpty, "new total does not mix with old breakdown")
        bytes.append(Data("{\"type\":\"event_msg\",\"payload\":".utf8))
        try bytes.write(to: file)
        let partial = await reader.read(record)
        try check(partial == first, "unfinished append ignored")
        bytes = try event(210, 80, 90, 300)
        try bytes.write(to: file)
        let appended = await reader.read(["thread": LocalUsageRecord(total: 300, rollout: file.path)])
        try check(appended["thread"]?.output == 90, "modified files invalidate detail cache")
        let invalidCases: [[Any]] = [[150, 151, 50, 200], [150, 60, 50, 201], [true, 0, 199, 200], [150, -1, 50, 200], [150.5, 60, 49.5, 200]]
        for fields in invalidCases {
            var invalid = try event(150, 60, 50, 200)
            invalid.append(try event(fields[0], fields[1], fields[2], fields[3]))
            try invalid.write(to: file)
            let found = await reader.read(record)
            try check(found.isEmpty, "invalid latest counters must not expose old breakdown")
        }
        let longFile = area.appendingPathComponent("bounded.jsonl")
        var longBytes = try event(150, 60, 50, 200)
        longBytes.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": String(repeating: "x", count: 200000)]))
        longBytes.append(10)
        try longBytes.write(to: longFile)
        let longRecord = ["long": LocalUsageRecord(total: 200, rollout: longFile.path)]
        let limited = await reader.read(longRecord, byteBudget: 65536)
        try check(limited.isEmpty, "tail-read budget is enforced")
        let retried = await reader.read(longRecord)
        try check(retried["long"]?.cached == 60, "a budget-limited read can retry across a long tool-output line")
        let outside = home.deletingLastPathComponent().appendingPathComponent("outside.jsonl")
        try event(150, 60, 50, 200).write(to: outside)
        let disallowed = await reader.read(["outside": LocalUsageRecord(total: 200, rollout: outside.path)])
        try check(disallowed.isEmpty, "records cannot read outside local statistics directories")
        let link = area.appendingPathComponent("outside-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let linked = await reader.read(["linked": LocalUsageRecord(total: 200, rollout: link.path)])
        try check(linked.isEmpty, "symlinks cannot escape the permitted statistics directories")
        let archivedArea = home.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archivedArea, withIntermediateDirectories: true)
        let archivedFile = archivedArea.appendingPathComponent("archived.jsonl")
        try event(150, 60, 50, 200).write(to: archivedFile)
        let archived = await reader.read(["archived": LocalUsageRecord(total: 200, rollout: archivedFile.path)])
        try check(archived["archived"]?.input == 150, "archived local records supported")
        let none = await reader.read(["missing": LocalUsageRecord(total: 200, rollout: nil)])
        try check(none.isEmpty, "missing detail remains unknown, not zero")
    }

    @MainActor static func protocolChecks(_ root: URL) async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture.py")
        let portFile = root.appendingPathComponent("port")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: portFile.path) || !server.isRunning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = Int(try String(contentsOf: portFile))!
        let discovery = SidebarDiscovery(port: port)
        let targets = try await discovery.targets()
        try check(targets.count == 1 && targets[0].id == "main", "HTTP discovery filters overlay and web pages")
        let connection = try await discovery.connect(targets[0], timeout: 0.3)
        let value = try await connection.evaluate("echo")
        try check(value["ok"] as? Bool == true, "RPC evaluation returns value")
        async let slow = connection.evaluate("slow")
        async let fast = connection.evaluate("echo")
        let pair = try await (slow, fast)
        try check(pair.0["ok"] as? Bool == true && pair.1["ok"] as? Bool == true, "out-of-order replies correlate by request id")
        for expression in ["timeout", "exception", "rpc-error"] {
            var failed = false
            do { _ = try await connection.evaluate(expression) } catch { failed = true }
            try check(failed, "\(expression) propagates error")
        }
        let request = Task { try await connection.evaluate("timeout") }
        try await Task.sleep(nanoseconds: 20_000_000)
        request.cancel()
        var cancelled = false
        do { _ = try await request.value } catch { cancelled = true }
        try check(cancelled, "pending requests respond to cancellation")
        await connection.close()
        var closed = false
        do { _ = try await connection.evaluate("echo") } catch { closed = true }
        try check(closed, "closed connections reject work")
        let reopened = try await discovery.connect(targets[0], timeout: 0.3)
        let recovered = try await reopened.evaluate("echo")
        try check(recovered["ok"] as? Bool == true, "new connection recovers")
        await reopened.close()
    }
}
