import AppKit

/// AppKit's deferred termination may run a nested loop. Enter it from a run-loop callback,
/// never while a Swift main-actor task is holding the executor needed for async cleanup.
@MainActor final class ApplicationTerminationController {
    private let timeout: TimeInterval
    private var requested = false
    private var cleanupStarted = false
    private var completed = false
    private var deadline: Timer?
    private var cleanupTask: Task<Void, Never>?

    init(timeout: TimeInterval = 2) {
        self.timeout = timeout
    }

    func request() {
        guard !requested else { return }
        requested = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.cleanupStarted else { return }
                NSApp.terminate(nil)
            }
        }
    }

    func beginCleanup(_ cleanup: @escaping @MainActor () async -> Void) {
        guard !cleanupStarted else { return }
        requested = true
        cleanupStarted = true
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        deadline = timer
        RunLoop.main.add(timer, forMode: .common)
        cleanupTask = Task { [weak self] in
            await cleanup()
            self?.finish()
        }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        deadline?.invalidate(); deadline = nil
        cleanupTask?.cancel(); cleanupTask = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
