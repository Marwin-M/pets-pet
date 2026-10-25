import Foundation

/// Receives application termination events, independently of window and connection visibility.
@MainActor final class CodexClientLifecycle {
    static let quitWithClientKey = "quitWithCodex"
    private let preferences: UserDefaults
    private let isClientRunning: () -> Bool
    private let quit: () -> Void
    private var pendingExit: Task<Void, Never>?
    private var quitRequested = false

    var quitWithClient: Bool { preferences.object(forKey: Self.quitWithClientKey) as? Bool ?? true }

    init(isClientRunning: @escaping () -> Bool, quit: @escaping () -> Void, preferences: UserDefaults = .standard) {
        self.isClientRunning = isClientRunning
        self.quit = quit
        self.preferences = preferences
    }

    func setQuitWithClient(_ enabled: Bool) {
        preferences.set(enabled, forKey: Self.quitWithClientKey)
        if !enabled { cancel() }
    }

    func clientDidTerminate(bundleIdentifier: String?, processID: pid_t, restartingProcessID: pid_t?) {
        guard quitWithClient, bundleIdentifier == "com.openai.codex", processID != restartingProcessID, !quitRequested else { return }
        pendingExit?.cancel()
        pendingExit = Task { [weak self] in
            // Let Workspace finish updating its process list and coalesce duplicate notifications.
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.quitWithClient, !self.quitRequested, !self.isClientRunning() else { return }
            self.pendingExit = nil
            self.quitRequested = true
            self.quit()
        }
    }

    func cancel() {
        pendingExit?.cancel()
        pendingExit = nil
    }
}
