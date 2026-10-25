import AppKit

@MainActor private final class TerminationDelegate: NSObject, NSApplicationDelegate {
    let controller = ApplicationTerminationController(timeout: 0.3)
    let suite = "PetsPetNativeExit-" + UUID().uuidString
    lazy var preferences = UserDefaults(suiteName: suite)!
    lazy var lifecycle = CodexClientLifecycle(isClientRunning: { false }, quit: { [weak self] in self?.controller.request() }, preferences: preferences)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("termination requested"); fflush(stdout)
        controller.beginCleanup {
            if CommandLine.arguments.contains("--stalled") {
                // Deliberately ignore cancellation, like an uninterruptible external operation.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { continuation.resume() }
                }
            } else {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            print("cleanup completed"); fflush(stdout)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        preferences.removePersistentDomain(forName: suite)
        print("termination finished"); fflush(stdout)
    }
}

@main struct TerminationChecks {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = TerminationDelegate()
        application.delegate = delegate
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            if CommandLine.arguments.contains("--client-exit-disabled") {
                delegate.lifecycle.setQuitWithClient(false)
                delegate.lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 123, restartingProcessID: nil)
                try? await Task.sleep(nanoseconds: 400_000_000)
                print("disabled follow-exit retained process"); fflush(stdout)
                delegate.controller.request()
            } else if CommandLine.arguments.contains("--client-exit") {
                delegate.lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 123, restartingProcessID: nil)
                delegate.lifecycle.clientDidTerminate(bundleIdentifier: "com.openai.codex", processID: 123, restartingProcessID: nil)
            } else {
                delegate.controller.request()
                delegate.controller.request()
            }
        }
        withExtendedLifetime(delegate) { application.run() }
    }
}
