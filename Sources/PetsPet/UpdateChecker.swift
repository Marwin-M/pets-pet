import Foundation
import PetsPetCore

enum UpdateNotice {
    case available(LatestRelease), upToDate, failed(String)
}

enum UpdateCheckError: LocalizedError {
    case currentVersionUnavailable, buildMetadataUnavailable
    var errorDescription: String? {
        switch self {
        case .currentVersionUnavailable: return "无法读取当前应用的版本或构建号，请从完整安装包运行。"
        case .buildMetadataUnavailable: return "公开版本号相同，但发布页尚未提供有效构建清单，暂时无法确认是否有同版本修订。"
        }
    }
}

/// Reads release metadata only. Downloads and installation remain user actions.
@MainActor final class UpdateChecker {
    static let lastCheckKey = "lastUpdateCheck"
    static let lastFailureKey = "lastFailedUpdateCheck"
    static let notifiedVersionKey = "notifiedUpdateVersion"
    private let session: URLSession
    private let preferences: UserDefaults
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var pendingNotice: UpdateNotice?
    private(set) var checking = false
    private(set) var available: LatestRelease?
    let currentVersion: String
    let currentBuild: Int?

    init(session: URLSession = .shared, preferences: UserDefaults = .standard,
         currentVersion: String? = nil, currentBuild: String? = nil, now: @escaping () -> Date = Date.init) {
        self.session = session; self.preferences = preferences; self.now = now
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.currentBuild = Int(currentBuild ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    var currentDescription: String { currentBuild.map { "\(currentVersion)（构建 \($0)）" } ?? currentVersion }
    var isDue: Bool {
        !checking && UpdateCheckSchedule.isDue(lastCheck: preferences.object(forKey: Self.lastCheckKey) as? Date,
                                               lastFailure: preferences.object(forKey: Self.lastFailureKey) as? Date, at: now())
    }

    func check(manual: Bool = false, completion: @escaping (Result<LatestRelease?, Error>) -> Void) {
        guard !checking else { return }
        checking = true
        task = Task { [weak self] in
            guard let self else { return }
            let result: Result<LatestRelease?, Error>
            do {
                guard let current = AppVersion(currentVersion), let currentBuild, currentBuild > 0 else {
                    throw UpdateCheckError.currentVersionUnavailable
                }
                var release = try LatestRelease(json: await data(at: LatestRelease.endpoint))
                if release.version == current {
                    guard let url = release.manifestURL else { throw UpdateCheckError.buildMetadataUnavailable }
                    release = try release.includingBuild(from: await data(at: url))
                }
                result = .success(release.isNewer(than: currentVersion, currentBuild: currentBuild) ? release : nil)
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            checking = false; task = nil
            switch result {
            case .success(let release):
                preferences.set(now(), forKey: Self.lastCheckKey)
                preferences.removeObject(forKey: Self.lastFailureKey)
                available = release
                if let release {
                    if manual || shouldNotify(release) { pendingNotice = .available(release) }
                } else {
                    pendingNotice = manual ? .upToDate : nil
                }
            case .failure(let error):
                preferences.set(now(), forKey: Self.lastFailureKey)
                if manual { pendingNotice = .failed(error.localizedDescription) }
            }
            completion(result)
        }
    }

    private func data(at url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PetsPet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 2_000_000 else { throw URLError(.badServerResponse) }
        return data
    }

    func shouldNotify(_ release: LatestRelease) -> Bool {
        preferences.string(forKey: Self.notifiedVersionKey) != release.notificationKey
    }

    /// Do not consume or mark a notice while locked, starting, or another UI is open.
    func takeNotice(ready: Bool) -> UpdateNotice? {
        guard ready, let notice = pendingNotice else { return nil }
        pendingNotice = nil
        if case .available(let release) = notice {
            preferences.set(release.notificationKey, forKey: Self.notifiedVersionKey)
        }
        return notice
    }

    func cancel() {
        task?.cancel(); task = nil; checking = false
    }
}
