import Foundation

/// Dotted numeric release version. A leading "v" (GitHub tags) is accepted;
/// missing trailing parts count as zero, so 1.7 == 1.7.0.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func == (left: AppVersion, right: AppVersion) -> Bool { compare(left, right) == 0 }
    public static func < (left: AppVersion, right: AppVersion) -> Bool { compare(left, right) < 0 }
    private static func compare(_ left: AppVersion, _ right: AppVersion) -> Int {
        for index in 0..<max(left.parts.count, right.parts.count) {
            let a = index < left.parts.count ? left.parts[index] : 0
            let b = index < right.parts.count ? right.parts[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

/// The published GitHub release that the update check compares against.
/// Only the release page is used; nothing is downloaded automatically.
public struct LatestRelease: Equatable {
    public let version: AppVersion
    public let title: String
    public let page: URL
    public let build: Int?
    public let manifestURL: URL?

    public var displayVersion: String { build.map { "\(version)（构建 \($0)）" } ?? version.description }
    public var notificationKey: String { build.map { "\(version)+\($0)" } ?? version.description }

    public static let repository = URL(string: "https://github.com/Marwin-M/pets-pet")!
    public static let endpoint = URL(string: "https://api.github.com/repos/Marwin-M/pets-pet/releases/latest")!

    /// Rejects drafts, prereleases and pages outside the project repository.
    public init(json data: Data) throws {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Payload: Decodable {
            let tag_name: String; let name: String?; let html_url: String
            let draft: Bool?; let prerelease: Bool?; let assets: [Asset]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true, let version = AppVersion(payload.tag_name),
              let page = URL(string: payload.html_url), page.scheme == "https", page.host == "github.com",
              page.path.hasPrefix(Self.repository.path + "/releases/") else { throw CocoaError(.coderInvalidValue) }
        self.version = version
        self.title = payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tag_name
        self.page = page
        self.build = nil
        self.manifestURL = payload.assets?.first(where: { $0.name == "manifest.json" }).flatMap { asset in
            guard let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
                  url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
                  url.path == Self.repository.path + "/releases/download/\(payload.tag_name)/manifest.json" else { return nil }
            return url
        }
    }

    private init(version: AppVersion, title: String, page: URL, build: Int, manifestURL: URL?) {
        self.version = version; self.title = title; self.page = page
        self.build = build; self.manifestURL = manifestURL
    }

    /// Uses the same version/build/identity fields written by Scripts/release.py.
    public func includingBuild(from data: Data) throws -> LatestRelease {
        struct Manifest: Decodable { let version: String; let build: String; let bundleIdentifier: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard AppVersion(manifest.version) == version, manifest.bundleIdentifier == "com.marwin.petspet",
              !manifest.build.isEmpty, manifest.build.allSatisfy({ $0.isASCII && $0.isNumber }),
              let build = Int(manifest.build), build > 0 else { throw CocoaError(.coderInvalidValue) }
        return LatestRelease(version: version, title: title, page: page, build: build, manifestURL: manifestURL)
    }

    public func isNewer(than current: String, currentBuild: Int? = nil) -> Bool {
        guard let current = AppVersion(current) else { return false }
        if version != current { return version > current }
        guard let build, let currentBuild else { return false }
        return build > currentBuild
    }
}

public enum UpdateCheckSchedule {
    public static let interval: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 15 * 60
    /// Successful checks wait a day. Failures retry after a short, bounded backoff.
    public static func isDue(lastCheck: Date?, lastFailure: Date? = nil, at now: Date) -> Bool {
        if let lastFailure, lastCheck == nil || lastFailure >= lastCheck! {
            let elapsed = now.timeIntervalSince(lastFailure)
            return elapsed >= retryInterval || elapsed < 0
        }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }
}

public enum FeedbackLink {
    /// A new GitHub issue prefilled with the app and system versions only;
    /// no diagnostics, account or conversation data.
    public static func newIssue(appVersion: String, systemVersion: String) -> URL {
        var components = URLComponents(url: LatestRelease.repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: "\n\n---\nPet's Pet \(appVersion) · macOS \(systemVersion)")]
        return components.url!
    }
}
