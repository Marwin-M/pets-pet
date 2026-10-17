import AppKit
import Darwin

// A quota-service crash must become a recoverable error, not terminate the app on a pipe write.
signal(SIGPIPE, SIG_IGN)

let application = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
