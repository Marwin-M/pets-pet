import AppKit
import AVFoundation
import ImageIO

struct StartupMedia: Codable, Equatable {
    let filename: String
    let originalName: String
}

enum StartupMediaError: LocalizedError {
    case unsupported, invalidImage, invalidVideo, invalidHTML, tooLarge
    var errorDescription: String? {
        switch self {
        case .unsupported: return "请选择 .html、.mov、.mp4 或 .png 文件。"
        case .invalidImage: return "无法读取这张 PNG，请检查文件是否完整。"
        case .invalidVideo: return "这个视频无法播放，请使用本机支持的视频编码重新导出。"
        case .invalidHTML: return "无法读取 HTML。请使用 UTF-8 编码的单文件 HTML，图片、字体和脚本需内嵌，不支持外部文件或在线资源。"
        case .tooLarge: return "素材过大。请选择不超过 200 MB、图片不超过 4096 × 4096 的素材。"
        }
    }
}

/// Imports a private copy before committing the selection. A failed import leaves the old asset intact.
@MainActor final class StartupMediaStore {
    static let selectionKey = "startupMedia"
    private let directory: URL
    private let preferences: UserDefaults
    private(set) var selection: StartupMedia?
    var url: URL? { selection.flatMap { safeURL($0.filename) } }
    var title: String { selection?.originalName ?? "默认动画" }
    static var defaultURL: URL? {
        if let url = Bundle.main.url(forResource: "DefaultStartup", withExtension: "html") { return url }
        let containers = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        return containers.map { $0.appendingPathComponent("PetsPet_PetsPet.bundle/DefaultStartup.html") }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    init(directory: URL, preferences: UserDefaults = .standard) {
        self.directory = directory.appendingPathComponent("StartupMedia", isDirectory: true)
        self.preferences = preferences
        selection = preferences.data(forKey: Self.selectionKey).flatMap { try? JSONDecoder().decode(StartupMedia.self, from: $0) }
        if let selection, safeURL(selection.filename) == nil {
            self.selection = nil
            preferences.removeObject(forKey: Self.selectionKey)
        }
    }

    private func safeURL(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent, !name.hasPrefix("."),
              ["mov", "mp4", "png", "html", "htm"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
        return directory.appendingPathComponent(name)
    }

    func importFile(_ source: URL) async throws {
        let ext = source.pathExtension.lowercased()
        guard ["mov", "mp4", "png", "html", "htm"].contains(ext) else { throw StartupMediaError.unsupported }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw StartupMediaError.unsupported }
        guard let size = values.fileSize, size > 0 else { throw StartupMediaError.unsupported }
        guard size <= 200 * 1024 * 1024 else { throw StartupMediaError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(UUID().uuidString + "." + ext)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        // Copy on a utility thread: a large file on an external disk must not freeze the menu.
        try await Task.detached(priority: .utility) {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }.value
        try Task.checkCancellation()
        let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard copiedSize > 0, copiedSize <= 200 * 1024 * 1024 else { throw StartupMediaError.tooLarge }
        if ext == "png" {
            try Self.validateImage(destination)
        } else if ["html", "htm"].contains(ext) {
            _ = try StartupHTMLDocument.read(destination)
        } else {
            let asset = AVURLAsset(url: destination)
            guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw StartupMediaError.invalidVideo
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw StartupMediaError.invalidVideo }
        }
        try Task.checkCancellation()
        let next = StartupMedia(filename: destination.lastPathComponent, originalName: source.lastPathComponent)
        let data = try JSONEncoder().encode(next)
        let previous = url
        preferences.set(data, forKey: Self.selectionKey)
        selection = next
        committed = true
        if let previous { try? FileManager.default.removeItem(at: previous) }
    }

    static func validateImage(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw StartupMediaError.invalidImage }
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw StartupMediaError.tooLarge }
        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw StartupMediaError.invalidImage }
    }

    func reset() {
        let previous = url
        selection = nil
        preferences.removeObject(forKey: Self.selectionKey)
        if let previous { try? FileManager.default.removeItem(at: previous) }
    }
}
