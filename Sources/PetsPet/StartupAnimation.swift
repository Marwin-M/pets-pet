import AppKit
import AVKit
import WebKit
import SwiftUI
import PetsPetCore

final class StartupPlayerHost: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct StartupPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> StartupPlayerHost {
        let view = StartupPlayerHost(frame: .zero)
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ nsView: StartupPlayerHost, context: Context) { nsView.playerLayer.player = player }
}

private struct StartupHTMLView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct StartupBackdropView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.identifier = NSUserInterfaceItemIdentifier("petspetStartupBackdrop")
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // Startup panels do not take focus; their backdrop must still use the active effect.
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct StartupView: View {
    let image: NSImage?
    let player: AVPlayer?
    let preview: Bool
    let fallback: Bool
    var html: StartupHTMLPlayer? = nil
    // A value snapshot makes WebKit readiness visible to SwiftUI's change detection.
    var htmlReady = false
    var onEndPreview: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                StartupBackdropView()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                if let html {
                    StartupHTMLView(webView: html.webView)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                    if !htmlReady {
                        ProgressView().progressViewStyle(.circular).controlSize(.large)
                    }
                } else if let player {
                    StartupPlayerView(player: player)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    VStack(spacing: 18) {
                        ProgressView().progressViewStyle(.circular).controlSize(.large)
                        Text(preview ? "动画素材暂不可用" : "正在打开 Codex…").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottom) {
                if preview || fallback {
                    Text(fallback ? "动画素材暂不可用，请更换素材或重试" :
                            image != nil ? "静态图片预览 · 点击结束预览关闭" : "开场预览 · 播放一遍后结束")
                        .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule()).padding(20)
                }
            }
            .overlay(alignment: .topTrailing) {
                if preview {
                    Button("结束预览") { onEndPreview?() }
                        .buttonStyle(.bordered).padding(20)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(html == nil ? 0.08 : 0)))
        }
    }
}

/// Startup is mouse-transparent; preview accepts only its native controls, never HTML input.
@MainActor final class StartupAnimationController {
    static let frameKey = "lastCodexMainWindowFrame"
    static let fadeDuration: TimeInterval = 0.8
    private var panel: NSPanel?
    private var theme: StartupTheme = .light
    private(set) var player: AVPlayer?
    private var html: StartupHTMLPlayer?
    private(set) var readyForLaunch = true
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var playbackEndObserver: NSObjectProtocol?
    private(set) var isPreviewing = false
    private var generation = 0
    private var lastRecordedFrame: CGRect?

    static func videoPlayer(url: URL) -> AVPlayer {
        let video = AVPlayer(url: url)
        video.isMuted = true
        video.actionAtItemEnd = .pause
        return video
    }

    func recordWindowFrame() {
        guard let frame = CodexStartupEnvironment.mainWindowFrame(), frame != lastRecordedFrame else { return }
        lastRecordedFrame = frame
        UserDefaults.standard.set(["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height], forKey: Self.frameKey)
    }

    private func preferredFrame() -> CGRect {
        let saved = UserDefaults.standard.dictionary(forKey: Self.frameKey) as? [String: Double]
        let previous = saved.flatMap { values -> CGRect? in
            guard let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"] else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        let current = CodexStartupEnvironment.mainWindowFrame()
        let screens = NSScreen.screens.map(\.visibleFrame)
        let preferred = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })?.visibleFrame
        return StartupLayout.frame(previous: current ?? previous, screens: screens, preferred: preferred)
    }

    func matchCurrentWindow() {
        recordWindowFrame()
        panel?.setFrame(preferredFrame(), display: true)
    }

    func show(url: URL?, preview: Bool = false, theme: StartupTheme = .light) {
        dismissImmediately()
        self.theme = theme
        isPreviewing = preview
        let current = generation
        var image: NSImage?
        var fallback = false
        if let url = url ?? StartupMediaStore.defaultURL(for: theme) {
            if url.pathExtension.lowercased() == "png" {
                if (try? StartupMediaStore.validateImage(url)) != nil { image = NSImage(contentsOf: url) }
                fallback = image == nil
            } else if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                do {
                    let page = StartupHTMLPlayer(document: try StartupHTMLDocument.read(url))
                    page.webView.appearance = theme.appearance
                    html = page; readyForLaunch = false
                    page.onReady = { [weak self, weak page] in
                        guard let self, self.generation == current, self.panel != nil else { return }
                        self.readyForLaunch = true
                        self.present(image: nil, preview: preview, fallback: false)
                        if preview && page?.completed == true { self.finish() }
                    }
                    page.onComplete = { [weak self, weak page] in
                        guard let self, self.generation == current, preview, page?.ready == true else { return }
                        self.finish()
                    }
                    page.onFailure = { [weak self] in self?.useFallback(generation: current, preview: preview) }
                } catch { fallback = true }
            } else if FileManager.default.isReadableFile(atPath: url.path), ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
                let video = Self.videoPlayer(url: url)
                player = video
                if preview, let item = video.currentItem {
                    playbackEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.generation == current else { return }
                            self.finish()
                        }
                    }
                }
                playerObservation = video.observe(\.status, options: [.new]) { [weak self] player, _ in
                    guard player.status == .failed else { return }
                    Task { @MainActor in self?.useFallback(generation: current, preview: preview) }
                }
                itemObservation = video.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in self?.useFallback(generation: current, preview: preview) }
                }
            } else { fallback = true }
        }
        present(image: image, preview: preview, fallback: fallback)
        html?.start()
        player?.play()
    }

    private func present(image: NSImage?, preview: Bool, fallback: Bool) {
        let frame = panel?.frame ?? preferredFrame()
        let window = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.appearance = theme.appearance
        let view = StartupView(image: image, player: player, preview: preview, fallback: fallback,
                               html: html, htmlReady: html?.ready == true, onEndPreview: { [weak self] in self?.finish() })
        if let host = window.contentView as? NSHostingView<StartupView> { host.rootView = view }
        else { window.contentView = NSHostingView(rootView: view) }
        window.setFrame(frame, display: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = html == nil
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = !preview
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.title = "Pet’s Pet 开场动画"
        panel = window
        window.orderFrontRegardless()
    }

    private func useFallback(generation current: Int, preview: Bool) {
        guard current == generation, panel != nil else { return }
        stopPlayback()
        present(image: nil, preview: preview, fallback: true)
    }

    func finish() {
        isPreviewing = false
        generation += 1
        guard let window = panel else { stopPlayback(); return }
        panel = nil
        // Retain the last decoded video frame through the fade; clearing it first causes a black flash.
        let fadingPlayer = player, fadingHTML = html
        playerObservation = nil; itemObservation = nil
        removePlaybackEndObserver()
        player = nil; html = nil; readyForLaunch = true
        fadingPlayer?.pause()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.fadeDuration
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
                fadingPlayer?.replaceCurrentItem(with: nil); fadingHTML?.stop()
            }
        }
    }

    func dismissImmediately() {
        generation += 1
        isPreviewing = false
        panel?.orderOut(nil); panel = nil
        stopPlayback()
    }

    private func stopPlayback() {
        removePlaybackEndObserver()
        playerObservation = nil; itemObservation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        html?.stop(); html = nil; readyForLaunch = true
    }

    private func removePlaybackEndObserver() {
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackEndObserver = nil
    }
}
