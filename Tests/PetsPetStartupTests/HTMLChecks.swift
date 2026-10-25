import AppKit
import WebKit
import SwiftUI

@main struct HTMLChecks {
    @MainActor static var phase = "initialization"
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { print("FAIL HTML checks [\(phase)]: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func runChecks() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) throws {
            assertions += 1
            guard value else { throw NSError(domain: "HTMLChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ message: String, seconds: TimeInterval = 15, condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(condition(), message)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/PetsPet/DefaultStartup.html")
        let document = try StartupHTMLDocument.read(source)
        let player = StartupHTMLPlayer(document: document)
        phase = "supplied HTML loading and completion"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: StartupView(image: nil, player: nil, preview: false, fallback: false, html: player))
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // WebKit suspends RAF in an invisible window. Keep just one point inside the display,
        // with no shadow or input, so the real renderer runs without presenting a preview window.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 1, y: screen.visibleFrame.maxY - 1))
        }
        window.orderFrontRegardless()
        var failed = false
        player.onReady = { host.rootView = StartupView(image: nil, player: nil, preview: false, fallback: false, html: player, htmlReady: player.ready) }
        player.onFailure = { failed = true; print("HTML failure: \(player.failureReason ?? "unknown")") }
        player.start()
        try await wait("provided HTML renders before timeout") { player.ready || failed }
        try check(player.ready && !failed, "the supplied HTML and embedded WebP load in the actual WebKit renderer")
        try check(!player.webView.configuration.websiteDataStore.isPersistent, "HTML gets an ephemeral browser store")
        try check(player.webView.underPageBackgroundColor.alphaComponent == 0, "transparent page background is retained")
        let before = ProcessInfo.processInfo.systemUptime
        try await wait("10-second animation completes naturally", seconds: 14) { player.completed || failed }
        try check(player.completed && !failed && ProcessInfo.processInfo.systemUptime - before >= 8,
                  "completion is the artwork's real ten-second event, not an early native timer")
        let finalFrame = try await player.webView.evaluateJavaScript("document.querySelector('canvas').toDataURL()") as! String
        try await Task.sleep(nanoseconds: 150_000_000)
        let heldFrame = try await player.webView.evaluateJavaScript("document.querySelector('canvas').toDataURL()") as! String
        try check(finalFrame == heldFrame && !player.stopped, "completed HTML holds the same last frame without dismissing or replaying")
        let rafFrozen = try await player.webView.evaluateJavaScript("requestAnimationFrame(() => {}) === 0") as! Bool
        try check(rafFrozen, "completed animation schedules no additional RAF frames")

        for (name, size) in [("normal", NSSize(width: 960, height: 600)),
                             ("ultrawide", NSSize(width: 1680, height: 480)),
                             ("portrait", NSSize(width: 480, height: 800))] {
            phase = "\(name) viewport"
            window.setContentSize(size)
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 1, y: screen.visibleFrame.maxY - 1))
            }
            host.layoutSubtreeIfNeeded()
            let resizeDeadline = Date().addingTimeInterval(2)
            var sized = false
            repeat {
                let viewport = try await player.webView.evaluateJavaScript("({width:innerWidth,height:innerHeight})") as! [String: Double]
                sized = host.frame.size == size && player.webView.frame.size == size &&
                    abs(viewport["width"]! - size.width) < 1 && abs(viewport["height"]! - size.height) < 1
                if !sized { try await Task.sleep(nanoseconds: 20_000_000) }
            } while !sized && Date() < resizeDeadline
            try check(sized, "\(name) viewport resize is delivered before measuring the artwork")
            let circles = try await player.webView.evaluateJavaScript("""
                (() => {
                  const proto = CanvasRenderingContext2D.prototype, calls = [];
                  const original = {arc:proto.arc,ellipse:proto.ellipse,createRadialGradient:proto.createRadialGradient};
                  for (const method of Object.keys(original)) {
                    proto[method] = function(...args) {
                      if (this.canvas.id === 'c') {
                        const m = this.getTransform(), x = Math.hypot(m.a,m.b), y = Math.hypot(m.c,m.d);
                        calls.push(Math.abs(x-y)<1e-6 && Math.abs(m.a*m.c+m.b*m.d)<1e-6 &&
                          (method !== 'ellipse' || Math.abs(args[2]-args[3])<1e-6));
                      }
                      return original[method].apply(this,args);
                    };
                  }
                  try { window.seek(0.9); window.seek(3.7); }
                  finally { for(const method of Object.keys(original)) proto[method]=original[method]; window.seek(10); }
                  return {count:calls.length,round:calls.every(Boolean)};
                })()
                """) as! [String: Any]
            try check((circles["count"] as! Int) > 4 && circles["round"] as! Bool,
                      "\(name) renders expanding rings and halo gradients as circles during both intro and idle motion")
            let report = try await player.webView.evaluateJavaScript("""
                dispatchEvent(new Event('resize'));
                (() => {
                  const c = document.querySelector('canvas'), rect = c.getBoundingClientRect();
                  const context = c.getContext('2d'), transform = context.getTransform();
                  const pixels = context.getImageData(0,0,c.width,c.height).data;
                  let left = 0, right = 0;
                  for (let y=0; y<c.height; y+=8) for(let x=0; x<Math.ceil(c.width*.15); x+=8) {
                    if (pixels[(y*c.width+x)*4+3] > 8) left++;
                    if (pixels[(y*c.width+c.width-1-x)*4+3] > 8) right++;
                  }
                  return {width:rect.width,height:rect.height,viewportWidth:innerWidth,viewportHeight:innerHeight,
                    uniform:Math.abs(transform.a-transform.d)<.000001,left,right};
                })()
                """) as! [String: Any]
            try check(abs((report["width"] as! Double) - (report["viewportWidth"] as! Double)) < 1 &&
                      abs((report["height"] as! Double) - (report["viewportHeight"] as! Double)) < 1,
                      "\(name) keeps the canvas at the full actual viewport")
            try check(report["uniform"] as! Bool, "\(name) preserves the subject's uniform scale")
            try check(abs((report["viewportWidth"] as! Double) - size.width) < 1 && abs((report["viewportHeight"] as! Double) - size.height) < 1,
                      "\(name) uses the requested real viewport size (got \(report["viewportWidth"]!), \(report["viewportHeight"]!))")
            if name == "ultrawide" {
                try check((report["left"] as! Int) > 10 && (report["right"] as! Int) > 10,
                          "ultrawide effects extend into both outer margins")
            }
            let image = try await player.webView.takeSnapshot(configuration: nil)
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            if name == "normal" {
                try check(bitmap.colorAt(x: 1, y: 1)!.alphaComponent < 0.99, "transparent HTML remains transparent in the native WebKit snapshot")
            }
            if CommandLine.arguments.contains("--images") {
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(".build/startup-html-\(name).png"))
            }
        }
        phase = "network isolation"
        let blocked = try await player.webView.callAsyncJavaScript("""
            try { await fetch('https://example.invalid/splash-check'); return false; } catch (_) { return true; }
            """, arguments: [:], in: nil, contentWorld: .page) as! Bool
        try check(blocked, "CSP blocks outgoing network requests in the real renderer")
        let cookies = await player.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        try check(cookies.isEmpty, "HTML has no account or browser cookies")
        player.stop()
        try check(player.stopped && player.webView.superview == nil, "stopping detaches and invalidates the HTML renderer")
        phase = "dark artwork playback and layout"
        let darkSource = root.appendingPathComponent("Sources/PetsPet/DefaultStartupDark.html")
        let darkPlayer = StartupHTMLPlayer(document: try StartupHTMLDocument.read(darkSource))
        window.appearance = NSAppearance(named: .darkAqua)
        darkPlayer.webView.appearance = window.appearance
        window.contentView = darkPlayer.webView
        window.setContentSize(NSSize(width: 960, height: 600))
        var darkFailed = false
        darkPlayer.onFailure = { darkFailed = true }
        darkPlayer.start()
        try await wait("night artwork renders its embedded character") { darkPlayer.ready || darkFailed }
        try check(darkPlayer.ready && !darkFailed, "night artwork loads in actual isolated WebKit")
        let darkStarted = ProcessInfo.processInfo.systemUptime
        let mediaDark = try await darkPlayer.webView.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as! Bool
        try check(mediaDark, "custom HTML receives the chosen dark appearance")
        try await wait("night animation plays its real ten seconds", seconds: 14) { darkPlayer.completed || darkFailed }
        try check(darkPlayer.completed && !darkFailed && ProcessInfo.processInfo.systemUptime - darkStarted >= 8,
                  "night artwork completes naturally without an early timeout")
        let darkFinal = try await darkPlayer.webView.evaluateJavaScript("document.querySelector('canvas').toDataURL()") as! String
        try await Task.sleep(nanoseconds: 120_000_000)
        let darkHeld = try await darkPlayer.webView.evaluateJavaScript("document.querySelector('canvas').toDataURL()") as! String
        try check(darkFinal == darkHeld, "night animation freezes its last frame")
        for (name, size) in [("dark", NSSize(width: 960, height: 600)), ("dark-ultrawide", NSSize(width: 1680, height: 480)),
                             ("dark-portrait", NSSize(width: 480, height: 800))] {
            window.setContentSize(size)
            try await wait("night viewport resizes") { darkPlayer.webView.frame.size == size }
            // A finished animation deliberately stops RAF; force its resize handler before measuring.
            let report = try await darkPlayer.webView.evaluateJavaScript("""
                (() => {
                  dispatchEvent(new Event('resize')); window.seek(3.7);
                  const c=document.querySelector('canvas'),ctx=c.getContext('2d'),m=ctx.getTransform();
                  const pixel=ctx.getImageData(0,0,1,1).data;
                  return {width:innerWidth,height:innerHeight,uniform:Math.abs(m.a-m.d)<1e-6,
                    dark:pixel[0]<60&&pixel[1]<60&&pixel[2]<80&&pixel[3]===255};
                })()
                """) as! [String: Any]
            try check(abs((report["width"] as! Double)-size.width)<1 && abs((report["height"] as! Double)-size.height)<1,
                      "\(name) canvas follows its real viewport")
            try check(report["uniform"] as! Bool && report["dark"] as! Bool, "\(name) keeps uniform scale and the dark backdrop")
            if CommandLine.arguments.contains("--images") {
                let image = try await darkPlayer.webView.takeSnapshot(configuration: nil)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(".build/startup-html-\(name).png"))
            }
        }
        darkPlayer.stop()
        phase = "script error fallback"
        let broken = StartupHTMLPlayer(document: StartupHTMLDocument(data: Data("<html><body><script>throw new Error('invalid animation')</script></body></html>".utf8)))
        window.contentView = broken.webView
        var rejected = false
        broken.onFailure = { rejected = true }
        broken.start()
        try await wait("script errors trigger recoverable failure", seconds: 6) { rejected }
        try check(broken.stopped && !broken.ready, "a broken page closes its renderer so the native loading fallback can continue")
        phase = "client readiness fixture"
        let readinessPage = StartupHTMLPlayer(document: StartupHTMLDocument(data: Data("<html><body><nav data-sidebar-navigation-root>Navigation</nav><main></main></body></html>".utf8)))
        window.contentView = readinessPage.webView
        readinessPage.webView.setFrameSize(NSSize(width: 960, height: 600))
        readinessPage.start()
        try await wait("readiness test page loads") { readinessPage.ready }
        let sidebarScript = try String(contentsOf: root.appendingPathComponent("Sources/PetsPetSidebar/Sidebar.js"), encoding: .utf8)
        func clientReady() async throws -> Bool {
            let result = try await readinessPage.webView.callAsyncJavaScript("return await \(sidebarScript) ({tokens:false,projects:false,quota:null})", arguments: [:], in: nil, contentWorld: .page) as! [String: Any]
            return result["clientReady"] as? Bool == true
        }
        let shellReady = try await clientReady()
        try check(!shellReady, "ready document and navigation without an editor remain a loading shell")
        _ = try await readinessPage.webView.evaluateJavaScript("document.querySelector('main').innerHTML='<textarea></textarea>'")
        let editorReady = try await clientReady()
        try check(editorReady, "main interface becomes ready when navigation and usable editor are rendered")
        _ = try await readinessPage.webView.evaluateJavaScript("document.querySelector('textarea').disabled=true")
        let disabledReady = try await clientReady()
        try check(!disabledReady, "disabled editor is not considered fully loaded")
        _ = try await readinessPage.webView.evaluateJavaScript("document.querySelector('textarea').disabled=false;document.querySelector('main').setAttribute('aria-busy','true')")
        let busyReady = try await clientReady()
        try check(!busyReady, "main interface loading marker prevents premature dismissal")
        _ = try await readinessPage.webView.evaluateJavaScript("document.querySelector('main').removeAttribute('aria-busy');document.querySelector('nav').hidden=true")
        let hiddenReady = try await clientReady()
        try check(!hiddenReady, "hidden shell controls do not count as interactive navigation")
        readinessPage.stop()
        window.close()
        phase = "native panel presentation"
        try await presentationChecks(check: check, wait: wait, source: source)
        print("HTML checks passed: \(assertions) assertions (actual WebKit, supplied 10s animation, final frame, ultrawide/portrait layout and outbound-request policy; no Codex launch).")
    }

    @MainActor static func presentationChecks(check: (Bool, String) throws -> Void,
        wait: (String, TimeInterval, () -> Bool) async throws -> Void, source: URL) async throws {
        let animation = StartupAnimationController()
        defer { animation.dismissImmediately() }
        // Exercise the product's actual panel and hosting updates, without forcing a WebKit frame.
        func panel() -> NSWindow? { NSApp.windows.first { $0.title == "Pet’s Pet 开场动画" && $0.isVisible } }
        func keepAtEdge(_ window: NSWindow) {
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 1, y: screen.visibleFrame.minY))
            }
        }
        func backdrops(in view: NSView) -> [NSVisualEffectView] {
            var result = view.subviews.flatMap { backdrops(in: $0) }
            if let effect = view as? NSVisualEffectView,
               effect.identifier?.rawValue == "petspetStartupBackdrop" { result.append(effect) }
            return result
        }
        func loadingIndicators(in view: NSView) -> [NSProgressIndicator] {
            var result = view.subviews.flatMap { loadingIndicators(in: $0) }
            if let indicator = view as? NSProgressIndicator, !indicator.isHiddenOrHasHiddenAncestor { result.append(indicator) }
            return result
        }
        func waitForFade() async throws {
            try await wait("preview backdrop and artwork finish fading together", 2, { panel() == nil })
        }
        for theme in StartupTheme.allCases {
            // Verify the real nil-custom path finds the matching bundled asset and pins the backdrop's appearance.
            animation.show(url: nil, preview: true, theme: theme)
            let themedWindow = panel()!
            keepAtEdge(themedWindow)
            try await wait("themed default reaches its first frame", 6, { animation.readyForLaunch })
            let themedHost = themedWindow.contentView as! NSHostingView<StartupView>
            try check(themedHost.rootView.htmlReady, "\(theme) default removes its loading indicator")
            let page = themedHost.rootView.html!.webView
            let title = try await page.evaluateJavaScript("document.title") as! String
            try check(title.contains("Divine") == (theme == .dark), "\(theme) selects the corresponding bundled animation")
            let matches = try await page.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches") as! Bool
            try check(matches == (theme == .dark) && themedWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (theme == .dark ? .darkAqua : .aqua),
                      "\(theme) preview pins both HTML and native backdrop to the selected appearance")
            animation.dismissImmediately()
        }
        animation.show(url: source, preview: true)
        let preview = panel()!
        keepAtEdge(preview)
        try await wait("real preview panel loads the supplied HTML", 6, { animation.readyForLaunch })
        try await Task.sleep(nanoseconds: 200_000_000)
        let host = preview.contentView as! NSHostingView<StartupView>
        try check(host.rootView.htmlReady, "ready value invalidates the native SwiftUI loading mask")
        host.layoutSubtreeIfNeeded()
        let effects = backdrops(in: host)
        try check(effects.count == 1 && effects[0].blendingMode == .behindWindow &&
                  effects[0].state == .active && effects[0].material == .underWindowBackground,
                  "whole native presentation has one active system backdrop that blurs other windows without focusing them")
        try check(effects[0].bounds.size == host.bounds.size && !preview.isOpaque && preview.backgroundColor?.alphaComponent == 0,
                  "backdrop covers the transparent animation panel rather than blurring the HTML artwork")
        try check(!host.rootView.html!.webView.isDescendant(of: effects[0]),
                  "HTML artwork stays outside the system material and keeps its own sharp renderer")
        try check(loadingIndicators(in: host).isEmpty, "native loading indicator disappears when HTML is rendered")
        try check(!preview.ignoresMouseEvents && host.rootView.onEndPreview != nil,
                  "preview exposes a clickable native end control")
        try await wait("default preview ends when its actual ten-second artwork completes", 12, { !animation.isPreviewing })
        try check(!backdrops(in: host).isEmpty, "native blur remains attached through the preview's closing transition")
        try await waitForFade()
        try check(!preview.isVisible, "default preview closes after one play instead of waiting fifteen seconds")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PetsPetPreviewChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let quick = directory.appendingPathComponent("quick.html")
        try Data("<html><body><meta name='petspet-duration' content='0.4'><p>Single play</p></body></html>".utf8).write(to: quick)
        animation.show(url: quick, preview: true)
        keepAtEdge(panel()!)
        try await wait("custom declared duration ends preview", 3, { !animation.isPreviewing })
        try await waitForFade()
        animation.show(url: source, preview: true)
        let manual = panel()!
        keepAtEdge(manual)
        (manual.contentView as! NSHostingView<StartupView>).rootView.onEndPreview?()
        try check(!animation.isPreviewing, "manual end works even while HTML is still loading")
        try await waitForFade()
        try check(!manual.isVisible && animation.readyForLaunch, "manual end disposes renderer and late readiness cannot reopen preview")

        let immediate = directory.appendingPathComponent("immediate.html")
        try Data("<html><body><script>dispatchEvent(new CustomEvent('splash:done'))</script></body></html>".utf8).write(to: immediate)
        animation.show(url: immediate, preview: true)
        keepAtEdge(panel()!)
        try await wait("completion before first frame still ends preview after readiness", 3, { !animation.isPreviewing })
        try await waitForFade()

        let png = directory.appendingPathComponent("static.png")
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try image.representation(using: .png, properties: [:])!.write(to: png)
        animation.show(url: png, preview: true)
        let still = panel()!
        keepAtEdge(still)
        try check(animation.isPreviewing && (still.contentView as! NSHostingView<StartupView>).rootView.image != nil,
                  "PNG preview displays the imported image with manual ending")
        (still.contentView as! NSHostingView<StartupView>).rootView.onEndPreview?()
        try check(!animation.isPreviewing, "static PNG has no invented playback duration and can end manually")
        try await waitForFade()

        let invalid = directory.appendingPathComponent("missing.html")
        animation.show(url: invalid, preview: true)
        let fallback = panel()!
        keepAtEdge(fallback)
        try check((fallback.contentView as! NSHostingView<StartupView>).rootView.fallback,
                  "unreadable HTML provides a recoverable preview failure")
        (fallback.contentView as! NSHostingView<StartupView>).rootView.onEndPreview?()
        try check(!animation.isPreviewing, "failed preview remains manually dismissible")
        try await waitForFade()

        animation.show(url: quick)
        let startup = panel()!
        keepAtEdge(startup)
        try await wait("startup HTML reaches its final frame", 3, { (startup.contentView as? NSHostingView<StartupView>)?.rootView.html?.completed == true })
        try check(startup.isVisible && startup.ignoresMouseEvents && !animation.isPreviewing,
                  "startup holds its last frame and remains mouse-transparent after HTML completion")
        try check(backdrops(in: startup.contentView!).count == 1,
                  "startup keeps the system blur after animation completes, while waiting for the client")
        let transitionStart = ProcessInfo.processInfo.systemUptime
        animation.finish()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try await Task.sleep(nanoseconds: 250_000_000)
            try check(startup.isVisible,
                      "artwork and blur are still fading together after the previous 0.2-second duration")
        }
        try await waitForFade()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try check(ProcessInfo.processInfo.systemUptime - transitionStart >= 0.7,
                      "native fade lasts approximately the requested 0.8 seconds")
        }
    }
}
