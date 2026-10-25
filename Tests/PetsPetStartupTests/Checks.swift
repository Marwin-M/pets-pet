import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import PetsPetCore

private var assertions = 0
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    assertions += 1
    guard value() else { throw NSError(domain: "StartupChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@MainActor private final class LaunchFixture {
    var running = false
    var ready = false
    var interactive = true
    var installed = true
    var fail = false
    var opens = 0
    var events: [String] = []
    var arguments: [String] = []
    var environment: CodexStartupEnvironment {
        CodexStartupEnvironment(isRunning: { self.running }, applicationURL: {
            self.installed ? URL(fileURLWithPath: "/isolated/Codex.app") : nil
        }, open: { _, arguments in
            self.opens += 1; self.arguments = arguments; self.events.append("open")
            if self.fail { throw NSError(domain: "LaunchFixture", code: 1) }
            self.running = true
        }, hasMainWindow: { self.ready }, isInterfaceReady: { self.interactive })
    }
    func controller(timeout: TimeInterval = 1, minimumDisplay: TimeInterval = 0) -> CodexStartupController {
        let controller = CodexStartupController(environment: environment, timeout: timeout,
                                              minimumDisplay: minimumDisplay, presentationDelay: 10_000_000,
                                              pollInterval: 5_000_000)
        controller.onPresent = { self.events.append("present") }
        controller.onWindowReady = { self.events.append("window") }
        controller.onFinish = { self.events.append($0 ? "restore" : "cancel") }
        controller.onError = { _ in self.events.append("error") }
        controller.onWillLaunch = { ["authorized-loopback"] }
        return controller
    }
}

@main struct StartupChecks {
    @MainActor static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(condition(), message)
    }

    @MainActor static func lifecycle() async throws {
        let cold = LaunchFixture(), coordinator = cold.controller(minimumDisplay: 0.07)
        coordinator.start(enabled: true, animated: true)
        coordinator.start(enabled: true, animated: true)
        try check(coordinator.isStarting && cold.events == ["present"], "splash precedes launch and repeated starts coalesce")
        try await waitUntil("launch called once") { cold.opens == 1 }
        try check(cold.arguments == ["authorized-loopback"], "only authorized arguments reach launcher")
        try await Task.sleep(nanoseconds: 15_000_000)
        try check(coordinator.isStarting, "a running process alone is not a ready window")
        cold.ready = true
        try await Task.sleep(nanoseconds: 10_000_000)
        try check(coordinator.isStarting, "short starts preserve the minimum animation interval")
        try await waitUntil("ready window restores widget") { !coordinator.isStarting }
        try check(cold.events == ["present", "open", "window", "restore"], "ready window is aligned before restore, exactly once")
        coordinator.start(enabled: true, animated: true)
        try check(cold.opens == 1 && cold.events.count == 4, "already running Codex neither replays animation nor relaunches")
        cold.running = false
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(cold.opens == 1, "later Codex exit never automatically relaunches it")

        let disabled = LaunchFixture(), disabledController = disabled.controller()
        disabledController.start(enabled: false, animated: true)
        try check(disabled.events.isEmpty && !disabledController.isStarting, "auto launch can be disabled")

        let plain = LaunchFixture(), plainController = plain.controller()
        plain.ready = true
        plainController.start(enabled: true, animated: false)
        try await waitUntil("disabled animation still opens Codex") { !plainController.isStarting }
        try check(plain.opens == 1 && plain.events.last == "restore", "launch and animation are separate preferences")

        let missing = LaunchFixture(); missing.installed = false
        let missingController = missing.controller()
        missingController.start(enabled: true, animated: true)
        try check(missing.events == ["error"] && !missingController.isStarting, "missing Codex reports error without a stranded panel")

        let broken = LaunchFixture(); broken.fail = true
        let brokenController = broken.controller()
        brokenController.start(enabled: true, animated: true)
        try await waitUntil("launch failure finishes") { !brokenController.isStarting }
        try check(broken.events.suffix(2) == ["cancel", "error"], "launch failure restores display before error")

        let slow = LaunchFixture(), slowController = slow.controller(timeout: 0.05)
        slowController.start(enabled: true, animated: true)
        try await waitUntil("window timeout is bounded") { !slowController.isStarting }
        try check(slow.events.suffix(2) == ["cancel", "error"] && slow.opens == 1, "timeout neither retries nor quits Codex")
        slow.ready = true
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(slow.events.filter { $0 == "cancel" }.count == 1, "late readiness cannot finish a completed launch again")

        let exiting = LaunchFixture(), exitingController = exiting.controller()
        exitingController.start(enabled: true, animated: true)
        try await waitUntil("process observed during cold start") { exiting.running }
        try await Task.sleep(nanoseconds: 15_000_000)
        exiting.running = false
        try await waitUntil("early process exit ends splash") { !exitingController.isStarting }
        try check(exiting.events.last == "error", "early exit is an explicit failure")

        let sleeping = LaunchFixture(), sleepingController = sleeping.controller()
        sleepingController.start(enabled: true, animated: true)
        sleepingController.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(sleeping.opens == 0 && sleeping.events == ["present", "cancel"], "sleep or quit cancels a pending launch without errors")

        let consent = LaunchFixture(), consentController = consent.controller()
        consentController.onWillLaunch = { consentController.cancel(); return [] }
        consentController.start(enabled: true, animated: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(consent.opens == 0 && consent.events == ["cancel"], "sleep during first-use consent cannot resume an abandoned launch")

        let html = LaunchFixture(), htmlController = html.controller()
        var rendered = false
        htmlController.presentationReady = { rendered }
        htmlController.start(enabled: true, animated: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(html.opens == 0 && htmlController.isStarting, "HTML gets its first rendered frame before Codex is requested")
        rendered = true
        try await waitUntil("rendered HTML releases launch gate") { html.opens == 1 }
        html.ready = true
        try await waitUntil("ready window can end a still-playing animation") { !htmlController.isStarting }
        try check(html.events.last == "restore", "client readiness controls dismissal independently of animation length")

        let stalledHTML = LaunchFixture(), stalledController = stalledHTML.controller(timeout: 0.05)
        stalledController.presentationReady = { false }
        stalledController.start(enabled: true, animated: true)
        try await waitUntil("unready HTML cannot strand coordinator") { !stalledController.isStarting }
        try check(stalledHTML.opens == 0 && stalledHTML.events.last == "error", "readiness timeout cancels a launch that was never requested")

        let shell = LaunchFixture(), shellController = shell.controller()
        shell.ready = true; shell.interactive = false
        shellController.start(enabled: true, animated: true)
        try await waitUntil("shell process opens") { shell.running }
        try await Task.sleep(nanoseconds: 30_000_000)
        try check(shellController.isStarting, "a visible window shell does not dismiss animation while interface is loading")
        shell.interactive = true
        try await waitUntil("interactive client dismisses animation") { !shellController.isStarting }
        try check(shell.events.last == "restore", "widget restoration waits for usable main interface")

        let manual = LaunchFixture(), manualController = manual.controller()
        manual.ready = true
        let connectionArguments = ["--remote-debugging-address=127.0.0.1", "--remote-debugging-port=39222"]
        var preparations = 0
        try check(manualController.canStart, "manual launch is available when client is absent")
        manualController.start(enabled: true, animated: false, launchPreparation: {
            preparations += 1
            return connectionArguments
        })
        try check(!manualController.canStart, "manual launch is disabled while launch is in progress")
        manualController.start(enabled: true, animated: false, launchPreparation: { preparations += 1; return [] })
        try await waitUntil("manual connected launch finishes") { !manualController.isStarting }
        try check(manual.opens == 1 && preparations == 1 && manual.arguments == connectionArguments,
                  "manual action passes loopback arguments once without invoking the automatic consent preparation")
        try check(!manualController.canStart, "manual launch remains disabled while client is running")
        manualController.start(enabled: true, animated: false, launchPreparation: { preparations += 1; return [] })
        try check(manual.opens == 1 && preparations == 1, "stale menu actions cannot relaunch an existing client or change consent")
        manual.running = false
        try check(manualController.canStart, "manual launch availability follows the actual client process")
    }

    @MainActor static func clientExit() async throws {
        let suite = "PetsPetClientExit-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var running = false, quits = 0
        let lifecycle = CodexClientLifecycle(isClientRunning: { running }, quit: { quits += 1 }, preferences: preferences)
        try check(lifecycle.quitWithClient, "new preference defaults to enabled, preserving the installed behavior")
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(quits == 0, "starting Pet's Pet without a running client does not exit immediately")
        lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.chat", processID: 10, restartingProcessID: nil)
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(quits == 0, "unrelated apps and standalone ChatGPT are outside the confirmed Codex target")
        lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 10, restartingProcessID: 10)
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(quits == 0, "the expected process exit during authorized sidebar reconnection preserves Pet's Pet")
        running = true
        lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 10, restartingProcessID: nil)
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(quits == 0, "another running target instance prevents companion exit")
        running = false
        lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 11, restartingProcessID: 10)
        lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 11, restartingProcessID: 10)
        try await waitUntil("final target exit requests companion quit") { quits == 1 }
        lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 11, restartingProcessID: nil)
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(quits == 1, "duplicate termination notifications request cleanup and quit only once")
        let cancelled = CodexClientLifecycle(isClientRunning: { false }, quit: { quits += 1 }, preferences: preferences)
        cancelled.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 12, restartingProcessID: nil)
        cancelled.cancel()
        try await Task.sleep(nanoseconds: 220_000_000)
        try check(quits == 1, "normal app shutdown cancels pending follow-exit handling")

        let controlled = CodexClientLifecycle(isClientRunning: { false }, quit: { quits += 1 }, preferences: preferences)
        controlled.setQuitWithClient(false)
        controlled.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 13, restartingProcessID: nil)
        try await Task.sleep(nanoseconds: 230_000_000)
        try check(quits == 1 && !controlled.quitWithClient, "disabled follow-exit keeps Pet's Pet running after client exits")
        let restored = CodexClientLifecycle(isClientRunning: { false }, quit: { quits += 1 }, preferences: preferences)
        try check(!restored.quitWithClient, "disabled preference survives creating a new lifecycle controller")
        controlled.setQuitWithClient(true)
        try await Task.sleep(nanoseconds: 230_000_000)
        try check(quits == 1, "enabling while client is absent does not retroactively quit Pet's Pet")
        controlled.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 14, restartingProcessID: nil)
        controlled.setQuitWithClient(false)
        try await Task.sleep(nanoseconds: 230_000_000)
        try check(quits == 1, "turning off the control cancels a pending follow-exit request")
        controlled.setQuitWithClient(true)
        try check(restored.quitWithClient, "the saved enabled state is visible to a recreated controller")
        controlled.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 15, restartingProcessID: nil)
        try await waitUntil("re-enabled follow-exit processes the next actual client exit") { quits == 2 }
    }

    static func layout() throws {
        let main = CGRect(x: 0, y: 30, width: 1440, height: 870)
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        let previous = CGRect(x: 100, y: 100, width: 1000, height: 700)
        try check(StartupLayout.frame(previous: previous, screens: [main, left], preferred: left) == previous,
                  "saved Codex geometry takes precedence over pointer screen")
        let secondary = CGRect(x: -1100, y: 40, width: 900, height: 700)
        try check(StartupLayout.frame(previous: secondary, screens: [main, left], preferred: main) == secondary,
                  "negative coordinates and secondary display are retained")
        try check(main.contains(StartupLayout.frame(previous: secondary, screens: [main], preferred: main)),
                  "disconnected display moves splash on screen")
        try check(StartupLayout.frame(previous: CGRect(x: -200, y: -200, width: 9000, height: 9000), screens: [main], preferred: main) == main,
                  "oversized saved frame is clamped to available screen")
        let initial = StartupLayout.frame(previous: nil, screens: [main], preferred: main)
        try check(initial.width == 1152 && initial.midX == main.midX && initial.midY == main.midY, "first launch has a centered screen-relative size")
        try check(!StartupLayout.valid(CGRect(x: Double.nan, y: 0, width: 300, height: 300)), "invalid saved geometry is rejected")
    }

    static func writePNG(_ url: URL, width: Int = 64, height: Int = 32) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw StartupMediaError.invalidImage }
    }

    static func writeVideo(_ url: URL, type: AVFileType) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                       AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StartupMediaError.invalidVideo }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &pixel)
            guard let pixel, input.isReadyForMoreMediaData else { throw StartupMediaError.invalidVideo }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 120, CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 3)) else {
                throw writer.error ?? StartupMediaError.invalidVideo
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StartupMediaError.invalidVideo }
    }

    @MainActor static func media() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PetsPetStartup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PetsPetStartup-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = StartupMediaStore(directory: root, preferences: preferences)
        try check(store.url == nil, "empty selection uses default loading")
        let png = root.appendingPathComponent("artwork.PNG")
        try writePNG(png)
        try await store.importFile(png)
        let imported = store.url!
        try check(imported != png && FileManager.default.fileExists(atPath: imported.path), "PNG import owns a separate managed copy")
        let importedData = try Data(contentsOf: imported), sourceData = try Data(contentsOf: png)
        try check(importedData == sourceData, "import preserves image bytes")
        try FileManager.default.removeItem(at: png)
        let restored = StartupMediaStore(directory: root, preferences: preferences)
        try check(restored.url == imported && restored.title == "artwork.PNG", "selection survives restart and source removal")
        let bad = root.appendingPathComponent("broken.mp4")
        try Data("invalid video".utf8).write(to: bad)
        do { try await store.importFile(bad); throw NSError(domain: "Expected video rejection", code: 1) }
        catch let error as NSError where error.domain == "Expected video rejection" { throw error }
        catch { try check(store.url == imported, "failed video import preserves previous selection") }
        let fakePNG = root.appendingPathComponent("broken.png")
        try Data("invalid image".utf8).write(to: fakePNG)
        do { try await store.importFile(fakePNG); throw NSError(domain: "Expected PNG rejection", code: 1) }
        catch let error as NSError where error.domain == "Expected PNG rejection" { throw error }
        catch { try check(store.url == imported, "failed PNG import preserves previous selection") }
        let unsupported = root.appendingPathComponent("artwork.gif")
        try Data([1]).write(to: unsupported)
        do { try await store.importFile(unsupported); throw NSError(domain: "Expected extension rejection", code: 1) }
        catch let error as NSError where error.domain == "Expected extension rejection" { throw error }
        catch { try check(store.url == imported, "unsupported extension does not replace selection") }
        let oversized = root.appendingPathComponent("oversized.mov")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: 200 * 1024 * 1024 + 1)
        try oversizedHandle.close()
        do { try await store.importFile(oversized); throw NSError(domain: "Expected size rejection", code: 1) }
        catch let error as NSError where error.domain == "Expected size rejection" { throw error }
        catch { try check(store.url == imported, "oversized media is rejected before copying") }
        let hugePNG = root.appendingPathComponent("wide.png")
        try writePNG(hugePNG, width: 4097, height: 1)
        do { try await store.importFile(hugePNG); throw NSError(domain: "Expected image dimension rejection", code: 1) }
        catch let error as NSError where error.domain == "Expected image dimension rejection" { throw error }
        catch { try check(store.url == imported, "excessive image dimensions do not replace selection") }
        for (ext, type) in [("mp4", AVFileType.mp4), ("mov", AVFileType.mov)] {
            let video = root.appendingPathComponent("clip." + ext)
            try await writeVideo(video, type: type)
            let old = store.url!
            try await store.importFile(video)
            try check(store.url?.pathExtension == ext && !FileManager.default.fileExists(atPath: old.path), "valid \(ext) imports and replaces old asset")
            let player = StartupAnimationController.videoPlayer(url: video)
            let item = player.currentItem
            player.play()
            try await waitUntil("\(ext) reaches its last frame") { player.currentTime().seconds > 0.6 && player.rate == 0 }
            let held = player.currentTime().seconds
            try await Task.sleep(nanoseconds: 100_000_000)
            try check(player.currentItem === item && abs(player.currentTime().seconds - held) < 0.01,
                      "\(ext) keeps its last item and timestamp instead of looping or advancing")
            player.pause(); player.replaceCurrentItem(with: nil)
            let preview = StartupAnimationController()
            preview.show(url: video, preview: true)
            if let screen = NSScreen.main, let window = NSApp.windows.first(where: { $0.title == "Pet’s Pet 开场动画" && $0.isVisible }) {
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 1, y: screen.visibleFrame.minY))
            }
            try check(preview.isPreviewing, "\(ext) starts a native one-play preview")
            try await waitUntil("\(ext) preview ends at its real EOF") { !preview.isPreviewing }
            try check(preview.player == nil, "\(ext) preview releases playback after natural completion")
            preview.dismissImmediately()
        }
        let bundledHTML = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PetsPet/DefaultStartup.html")
        let oldVideo = store.url!
        try await store.importFile(bundledHTML)
        let htmlCopy = store.url!
        let originalHTML = try Data(contentsOf: bundledHTML), copiedHTML = try Data(contentsOf: htmlCopy)
        try check(originalHTML == copiedHTML && !FileManager.default.fileExists(atPath: oldVideo.path), "self-contained HTML imports as an exact managed copy")
        let brokenHTML = root.appendingPathComponent("broken.html")
        try Data([0xff, 0xfe, 0xff]).write(to: brokenHTML)
        do { try await store.importFile(brokenHTML); throw NSError(domain: "Expected HTML rejection", code: 1) }
        catch let error as NSError where error.domain == "Expected HTML rejection" { throw error }
        catch { try check(store.url == htmlCopy, "invalid HTML leaves the selected animation intact") }
        try check(StartupMediaStore(directory: root, preferences: preferences).url == htmlCopy, "HTML selection survives restart")
        let items = try FileManager.default.contentsOfDirectory(at: imported.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        try check(items.count == 1, "only the final asset remains, failed imports are cleaned up")
        let last = store.url!
        store.reset()
        try check(store.url == nil && !FileManager.default.fileExists(atPath: last.path), "restore default clears saved choice and managed copy")
        let unsafe = StartupMedia(filename: "../outside.png", originalName: "outside")
        preferences.set(try JSONEncoder().encode(unsafe), forKey: StartupMediaStore.selectionKey)
        try check(StartupMediaStore(directory: root, preferences: preferences).url == nil, "saved path traversal is rejected")
    }

    @MainActor static func rendering() throws {
        // A wide striped source rendered into a square must crop the side stripes, not squash them or leave bars.
        let context = CGContext(data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (x, color) in [(0, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                           (200, CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
                           (400, CGColor(red: 0, green: 0, blue: 1, alpha: 1))] {
            context.setFillColor(color); context.fill(CGRect(x: x, y: 0, width: 200, height: 200))
        }
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 600, height: 200))
        let renderer = ImageRenderer(content: StartupView(image: image, player: nil, preview: false, fallback: false)
            .frame(width: 200, height: 200))
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { throw StartupMediaError.invalidImage }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        for point in [(10, 100), (190, 100), (100, 10), (100, 190)] {
            let color = bitmap.colorAt(x: point.0, y: point.1)!.usingColorSpace(.deviceRGB)!
            try check(color.greenComponent > 0.9 && color.redComponent < 0.1 && color.blueComponent < 0.1,
                      "PNG fills each edge with a proportional center crop")
        }
        let host = StartupPlayerHost(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        host.layout()
        try check(host.playerLayer.videoGravity == .resizeAspectFill, "video uses native proportional fill rather than stretch")
        try check(host.playerLayer.frame == host.bounds, "video surface covers the full animation window")
        host.setFrameSize(NSSize(width: 400, height: 700)); host.layout()
        try check(host.playerLayer.frame == host.bounds, "video fill follows a changed Codex window size")
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await lifecycle()
        try await clientExit()
        try layout()
        try await media()
        try rendering()
        print("Startup checks passed: \(assertions) assertions (real coordinator, geometry, PNG/MOV/MP4 import and native fill rendering; isolated launch fixture, no Codex launch or quit).")
    }
}
