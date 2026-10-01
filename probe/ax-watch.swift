import ApplicationServices
import AppKit
import Foundation

func attribute(_ element: AXUIElement, _ name: CFString) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success, let value else { return "-" }
    return String(describing: value).replacingOccurrences(of: "\n", with: "\\n")
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count <= 1 else {
    fputs("Usage: ax-watch [bundle-id-or-name]\n", stderr)
    exit(2)
}
let target = args.first ?? "Slack"
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
guard AXIsProcessTrustedWithOptions(options) else {
    fputs("Accessibility permission required for this executable or its parent terminal. Grant access in System Settings > Privacy & Security > Accessibility.\n", stderr)
    exit(1)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == target || $0.localizedName == target
}) else {
    fputs("Application not running: \(target)\n", stderr)
    exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
let notifications: [CFString] = [
    kAXValueChangedNotification as CFString,
    kAXTitleChangedNotification as CFString,
    kAXWindowCreatedNotification as CFString,
    kAXUIElementDestroyedNotification as CFString,
    kAXFocusedWindowChangedNotification as CFString
]
var observer: AXObserver?
var seen = Set<UInt>()
func subscribe(_ element: AXUIElement, depth: Int = 0) {
    guard depth <= 20, seen.count < 5000 else { return }
    let identity = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
    guard seen.insert(identity).inserted, let observer else { return }
    for notification in notifications {
        let result = AXObserverAddNotification(observer, element, notification, nil)
        if result != .success && result != .notificationUnsupported && result != .notificationAlreadyRegistered {
            fputs("Notification registration failed (\(notification)): AXError \(result.rawValue)\n", stderr)
        }
    }
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let children = children as? [AXUIElement] {
        for child in children { subscribe(child, depth: depth + 1) }
    }
}
let status = AXObserverCreate(app.processIdentifier, { _, element, notification, _ in
    if notification == kAXWindowCreatedNotification as CFString { subscribe(element) }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("\(timestamp) \(notification) role=\(attribute(element, kAXRoleAttribute as CFString)) title=\(attribute(element, kAXTitleAttribute as CFString)) value=\(attribute(element, kAXValueAttribute as CFString))")
    fflush(stdout)
}, &observer)
guard status == .success, let observer else {
    fputs("AXObserverCreate failed: AXError \(status.rawValue)\n", stderr)
    exit(1)
}
subscribe(root)
var windows: CFTypeRef?
if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
   let windows = windows as? [AXUIElement] {
    for window in windows { subscribe(window) }
}
guard !seen.isEmpty else {
    fputs("No AX elements found to watch.\n", stderr)
    exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
print("Watching \(app.localizedName ?? target) (pid \(app.processIdentifier)); Ctrl-C to stop")
fflush(stdout)
CFRunLoopRun()
