import AppKit
import WebKit

struct StartupHTMLDocument {
    let data: Data
    static let scheme = "petspet-splash"
    static let url = URL(string: "petspet-splash://animation/index.html")!
    // Single-file animations have no network, filesystem, frame, worker, form or native-app access.
    static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 200 * 1024 * 1024 else { throw StartupMediaError.tooLarge }
        let data = try Data(contentsOf: url)
        guard let html = String(data: data, encoding: .utf8),
              html.range(of: "<html", options: .caseInsensitive) != nil,
              html.range(of: "<body", options: .caseInsensitive) != nil,
              !html.contains("\0") else { throw StartupMediaError.invalidHTML }
        return Self(data: data)
    }
}

private final class SplashSchemeHandler: NSObject, WKURLSchemeHandler {
    let document: StartupHTMLDocument
    init(document: StartupHTMLDocument) { self.document = document }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard urlSchemeTask.request.url == StartupHTMLDocument.url else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let response = HTTPURLResponse(url: StartupHTMLDocument.url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": StartupHTMLDocument.policy,
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"
        ])!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(document.data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

private final class SplashMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: StartupHTMLPlayer?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { owner?.receive(message) }
    }
}

/// Owns one ephemeral WebKit page. Completion freezes the artwork; only the native launch flow dismisses it.
@MainActor final class StartupHTMLPlayer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?
    var onComplete: (() -> Void)?
    private(set) var ready = false
    private(set) var completed = false
    private(set) var stopped = false
    private(set) var failureReason: String?
    private var timeoutTask: Task<Void, Never>?
    private let proxy: SplashMessageHandler

    init(document: StartupHTMLDocument) {
        let handler = SplashMessageHandler()
        proxy = handler
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.setURLSchemeHandler(SplashSchemeHandler(document: document), forURLScheme: StartupHTMLDocument.scheme)
        config.userContentController.addUserScript(WKUserScript(source: Self.lifecycleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: Self.bootstrap, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(handler, name: "petspetSplash")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        proxy.owner = self
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
        // macOS WebKit's public under-page color alone still paints a white canvas.
        // Guard its longstanding compatibility setter; unsupported systems retain the safe background.
        if webView.responds(to: NSSelectorFromString("setDrawsBackground:")) || webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.allowsBackForwardNavigationGestures = false
    }

    func start() {
        guard !stopped else { return }
        webView.load(URLRequest(url: StartupHTMLDocument.url))
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            guard let self, !self.ready, !self.stopped else { return }
            self.fail("HTML 首帧等待超时")
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame,
              webView.url == StartupHTMLDocument.url,
              let value = message.body as? String else { return }
        switch value {
        case "ready":
            guard !ready else { return }
            ready = true; timeoutTask?.cancel(); timeoutTask = nil; onReady?()
        case "complete":
            guard !completed else { return }
            completed = true; onComplete?()
        case let error where error.hasPrefix("error:"): fail(String(error.prefix(300)))
        default: break
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timeoutTask?.cancel(); timeoutTask = nil
        onReady = nil; onFailure = nil; onComplete = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "petspetSplash")
        webView.configuration.userContentController.removeAllUserScripts()
        // Navigate away to end RAF, timers and decoding rather than retaining a hidden page.
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
    }

    private func fail(_ reason: String = "HTML 动画加载失败") {
        guard !stopped else { return }
        failureReason = reason
        let callback = onFailure
        stop(); callback?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(!navigationAction.shouldPerformDownload && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url == StartupHTMLDocument.url ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("WebKit \((error as NSError).domain) \((error as NSError).code)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("WebKit \((error as NSError).domain) \((error as NSError).code)") }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("HTML 内容进程已退出") }

    private static let lifecycleScript = #"""
    (() => {
      const post = event => window.webkit.messageHandlers.petspetSplash.postMessage(event);
      addEventListener('error', event => post('error:' + (event.message || '资源加载失败')), true);
      addEventListener('unhandledrejection', event => post('error:' + String(event.reason)));
      const raf = requestAnimationFrame.bind(window), cancel = cancelAnimationFrame.bind(window);
      const pending = new Set(); let complete = false;
      window.requestAnimationFrame = callback => {
        if (complete) return 0;
        const id = raf(time => { pending.delete(id); if (!complete) callback(time); });
        pending.add(id); return id;
      };
      addEventListener('splash:done', () => {
        if (complete) return;
        complete = true;
        pending.forEach(cancel); pending.clear();
        document.getAnimations().forEach(animation => animation.pause());
        document.querySelectorAll('audio,video').forEach(media => media.pause());
        post('complete');
      });
      // Readiness callbacks must still run if a static page signals completion immediately.
      window.__petsPetFrameReady = () => raf(() => raf(() => post('ready')));
    })();
    """#

    private static let bootstrap = #"""
    (() => {
      const post = event => window.webkit.messageHandlers.petspetSplash.postMessage(event);
      const body = document.body, root = document.documentElement;
      const declared = (document.querySelector('meta[name="petspet-design-size"]')?.content || '').match(/^(\d+)\s*[x×,]\s*(\d+)$/);
      const set = (node, key, value) => node.style.setProperty(key, value, 'important');
      set(root, 'overflow', 'hidden'); set(root, 'width', '100%'); set(root, 'height', '100%');
      set(body, 'margin', '0');
      set(body, 'overflow', 'hidden');
      // Responsive artwork owns its layout. Only explicitly fixed-size artwork is scaled and cropped.
      if (declared) {
        const width = Number(declared[1]), height = Number(declared[2]);
        if (!(width > 0 && height > 0 && width <= 16384 && height <= 16384)) { post('error:无效设计尺寸'); return; }
        set(body, 'position', 'absolute'); set(body, 'width', width + 'px'); set(body, 'height', height + 'px');
        set(body, 'left', '50%'); set(body, 'top', '50%'); set(body, 'transform-origin', 'center center');
        const resize = () => set(body, 'transform', `translate(-50%, -50%) scale(${Math.max(innerWidth / width, innerHeight / height)})`);
        resize(); addEventListener('resize', resize);
      }
      Promise.resolve(window.ready).then(() => Promise.all([...document.images].map(image => image.decode())))
        .then(() => window.__petsPetFrameReady())
        .catch(error => post('error:' + String(error)));
      const duration = Number(document.querySelector('meta[name="petspet-duration"]')?.content);
      if (Number.isFinite(duration) && duration > 0) setTimeout(() => dispatchEvent(new CustomEvent('splash:done')), duration * 1000);
    })();
    """#
}
