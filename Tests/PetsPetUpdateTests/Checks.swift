import Foundation
import PetsPetCore

private var assertions = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1
    guard value() else { throw NSError(domain: "UpdateChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private final class UpdateProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, Data)?)?
    static var received: [URL] = []
    static func use(_ handler: @escaping (URLRequest) throws -> (Int, Data)?) {
        lock.lock(); self.handler = handler; received = []; lock.unlock()
    }
    static var requests: [URL] { lock.lock(); defer { lock.unlock() }; return received }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.received.append(request.url!); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            guard let (status, data) = try handler(request) else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct UpdateChecks {
    @MainActor static func run(_ checker: UpdateChecker, manual: Bool = false) async -> Result<LatestRelease?, Error> {
        await withCheckedContinuation { continuation in checker.check(manual: manual) { continuation.resume(returning: $0) } }
    }
    static func release(_ tag: String = "v1.8.0", manifest: Bool = false) throws -> Data {
        var payload: [String: Any] = ["tag_name": tag, "name": "Update check fixture", "draft": false,
                                      "prerelease": false, "html_url": "https://github.com/Marwin-M/pets-pet/releases/tag/\(tag)"]
        if manifest {
            payload["assets"] = [["name": "manifest.json", "browser_download_url":
                "https://github.com/Marwin-M/pets-pet/releases/download/\(tag)/manifest.json"]]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
    static func manifest(_ build: String, version: String = "1.7.1", identity: String = "com.marwin.petspet") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version, "build": build, "bundleIdentifier": identity])
    }

    @MainActor static func main() async throws {
        let suite = "PetsPetUpdateChecks-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ version: String = "1.7.1", _ build: String = "27") -> UpdateChecker {
            UpdateChecker(session: session, preferences: preferences, currentVersion: version, currentBuild: build, now: { now })
        }
        let newer = try release()
        UpdateProtocol.use { request in
            try check(request.url == LatestRelease.endpoint, "only the release metadata endpoint is requested")
            try check(request.value(forHTTPHeaderField: "Authorization") == nil, "public checks need no credentials")
            return (200, newer)
        }
        let checker = make()
        try check(checker.isDue, "first check is due")
        guard case .success(let release?) = await run(checker) else { throw URLError(.cannotParseResponse) }
        try check(release.version.description == "1.8.0", "newer public version detected without a manifest")
        try check(checker.available == release && !checker.checking && !checker.isDue, "successful state and daily schedule")
        try check(checker.takeNotice(ready: false) == nil, "locked or starting UI defers the notice")
        try check(checker.shouldNotify(release), "deferred notice is not marked as shown")
        guard case .available(let notice)? = checker.takeNotice(ready: true) else { throw URLError(.unknown) }
        try check(notice == release && !checker.shouldNotify(release), "resume consumes and marks the notice")
        try check(checker.takeNotice(ready: true) == nil, "resume does not show a duplicate notice")
        _ = await run(checker)
        try check(checker.takeNotice(ready: true) == nil, "background check does not repeat a shown version")
        _ = await run(checker, manual: true)
        try check(checker.takeNotice(ready: false) == nil, "manual result also survives a lock")
        guard case .available? = checker.takeNotice(ready: true) else { throw URLError(.unknown) }

        let same = try Self.release("v1.7.1", manifest: true)
        let build28 = try manifest("28")
        UpdateProtocol.use { request in (200, request.url == LatestRelease.endpoint ? same : build28) }
        guard case .success(let revision?) = await run(checker) else { throw URLError(.cannotParseResponse) }
        try check(UpdateProtocol.requests.count == 2, "same version reads the existing manifest asset")
        try check(revision.build == 28 && revision.isNewer(than: "1.7.1", currentBuild: 27), "build 27 to 28 is an update")
        try check(revision.notificationKey == "1.7.1+28" && revision.displayVersion.contains("28"), "notice identifies the exact build")
        try check(checker.takeNotice(ready: false) == nil && checker.shouldNotify(revision), "same-version notice remains pending")
        _ = checker.takeNotice(ready: true)
        let build29 = try manifest("29")
        UpdateProtocol.use { request in (200, request.url == LatestRelease.endpoint ? same : build29) }
        guard case .success(let nextRevision?) = await run(checker) else { throw URLError(.cannotParseResponse) }
        try check(checker.shouldNotify(nextRevision), "a later revision can notify separately")
        _ = checker.takeNotice(ready: true)
        let current = make("1.7.1", "29")
        guard case .success(nil) = await run(current, manual: true) else { throw URLError(.unknown) }
        guard case .upToDate? = current.takeNotice(ready: true) else { throw URLError(.unknown) }
        try check(current.available == nil, "equal build is up to date")
        UpdateProtocol.use { request in (200, request.url == LatestRelease.endpoint ? same : build28) }
        guard case .success(nil) = await run(current) else { throw URLError(.unknown) }
        try check(current.takeNotice(ready: true) == nil, "older build never offers a downgrade")

        preferences.removePersistentDomain(forName: suite)
        UpdateProtocol.use { _ in throw URLError(.notConnectedToInternet) }
        let offline = make()
        guard case .failure = await run(offline) else { throw URLError(.unknown) }
        try check(!offline.checking && !offline.isDue, "offline failure exits loading and backs off")
        try check(preferences.object(forKey: UpdateChecker.lastCheckKey) == nil, "failure does not mark a successful daily check")
        try check(preferences.object(forKey: UpdateChecker.lastFailureKey) as? Date == now, "failure time is persisted")
        now.addTimeInterval(899)
        try check(!offline.isDue && !make().isDue, "failure backoff survives restart")
        now.addTimeInterval(1)
        try check(offline.isDue, "offline check retries after fifteen minutes")
        UpdateProtocol.use { _ in (200, newer) }
        _ = await run(offline)
        try check(preferences.object(forKey: UpdateChecker.lastFailureKey) == nil, "successful recovery clears failure backoff")
        try check(!offline.isDue, "successful recovery resumes daily interval")

        UpdateProtocol.use { _ in (503, Data()) }
        guard case .failure = await run(offline, manual: true) else { throw URLError(.unknown) }
        guard case .failed? = offline.takeNotice(ready: true) else { throw URLError(.unknown) }
        try check(!offline.checking, "HTTP failure has a manual result and exits loading")
        UpdateProtocol.use { _ in (200, Data("{}".utf8)) }
        guard case .failure = await run(offline) else { throw URLError(.unknown) }
        try check(!offline.checking, "malformed payload exits loading")
        let sameWithoutManifest = try Self.release("v1.7.1")
        UpdateProtocol.use { _ in (200, sameWithoutManifest) }
        guard case .failure(let missing) = await run(offline, manual: true) else { throw URLError(.unknown) }
        try check(missing is UpdateCheckError, "missing build metadata cannot falsely report up to date")
        let wrongBuild = try manifest("28", identity: "com.someone.else")
        UpdateProtocol.use { request in (200, request.url == LatestRelease.endpoint ? same : wrongBuild) }
        guard case .failure = await run(offline) else { throw URLError(.unknown) }
        try check(!offline.checking, "mismatched manifest is rejected")
        UpdateProtocol.use { _ in (200, newer) }
        guard case .failure = await run(make("invalid", "27")) else { throw URLError(.unknown) }
        try check(UpdateProtocol.requests.isEmpty, "invalid installed metadata does not produce a false latest result")
        guard case .success(nil) = await run(make("1.9.0", "30")) else { throw URLError(.unknown) }
        try check(UpdateProtocol.requests.count == 1, "a locally newer version needs no older manifest")

        preferences.removePersistentDomain(forName: suite)
        UpdateProtocol.use { _ in nil }
        let cancelled = make()
        var completions = 0
        cancelled.check { _ in completions += 1 }
        cancelled.check { _ in completions += 1 }
        let deadline = Date().addingTimeInterval(2)
        while UpdateProtocol.requests.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(cancelled.checking && UpdateProtocol.requests.count == 1, "concurrent requests are suppressed")
        cancelled.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(!cancelled.checking && completions == 0, "termination cancels without reporting a stale result")
        try check(preferences.object(forKey: UpdateChecker.lastCheckKey) == nil && preferences.object(forKey: UpdateChecker.lastFailureKey) == nil,
                  "cancellation writes no schedule state")
        print("Update checks passed: \(assertions) assertions; isolated HTTP, preferences and clock; no real client changes.")
    }
}
