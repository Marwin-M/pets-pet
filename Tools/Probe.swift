import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

print("accessibility=\(AXIsProcessTrusted()) screenMetadata=\(CGPreflightScreenCaptureAccess())")
for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.openai.codex" {
    print("codex pid=\(app.processIdentifier) hidden=\(app.isHidden)")
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 0.3)
    let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
    for window in windows {
        let fields = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute]
        print("AX", fields.map { "\($0)=\(String(describing: attribute(window, $0)))" }.joined(separator: " "))
    }
    for entry in CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] where entry[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier {
        let keys = [kCGWindowNumber, kCGWindowBounds, kCGWindowLayer, kCGWindowAlpha, kCGWindowIsOnscreen]
        print("CG", keys.map { "\($0)=\(String(describing: entry[$0 as String]))" }.joined(separator: " "))
    }
}
