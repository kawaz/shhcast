import ApplicationServices
import AppKit
import Foundation

func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ name: CFString) -> String {
    guard let value = attribute(element, name) else { return "-" }
    if CFGetTypeID(value) == AXValueGetTypeID() {
        let axValue = value as! AXValue
        if AXValueGetType(axValue) == .cgPoint {
            var point = CGPoint.zero
            if AXValueGetValue(axValue, .cgPoint, &point) { return "(\(point.x), \(point.y))" }
        }
    }
    return String(describing: value).replacingOccurrences(of: "\n", with: "\\n")
}

func usage() -> Never {
    fputs("Usage: ax-dump [bundle-id-or-name] [--max-depth N] [--max-elements N]\n", stderr)
    exit(2)
}

var target = "Slack"
var maxDepth = 12
var maxElements = 2000
var args = Array(CommandLine.arguments.dropFirst())
var targetSet = false
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--max-depth", "--max-elements":
        guard !args.isEmpty, let number = Int(args.removeFirst()), number >= 0 else { usage() }
        if arg == "--max-depth" { maxDepth = number } else { maxElements = number }
    default:
        guard !arg.hasPrefix("-"), !targetSet else { usage() }
        target = arg
        targetSet = true
    }
}

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
var windows: CFTypeRef?
let result = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
guard result == .success, let elements = windows as? [AXUIElement] else {
    fputs("Cannot read application windows: AXError \(result.rawValue)\n", stderr)
    exit(1)
}
var count = 0
func dump(_ element: AXUIElement, depth: Int) {
    guard count < maxElements else { return }
    count += 1
    let fields: [(String, CFString)] = [
        ("role", kAXRoleAttribute as CFString),
        ("subrole", kAXSubroleAttribute as CFString),
        ("title", kAXTitleAttribute as CFString),
        ("description", kAXDescriptionAttribute as CFString),
        ("value", kAXValueAttribute as CFString),
        ("identifier", kAXIdentifierAttribute as CFString),
        ("enabled", kAXEnabledAttribute as CFString),
        ("position", kAXPositionAttribute as CFString)
    ]
    print(String(repeating: "  ", count: depth) + fields.map { "\($0.0)=\(text(element, $0.1))" }.joined(separator: " "))
    guard depth < maxDepth, let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else { return }
    for child in children {
        guard count < maxElements else { return }
        dump(child, depth: depth + 1)
    }
}
for window in elements {
    guard count < maxElements else { break }
    dump(window, depth: 0)
}
if count == maxElements { fputs("Element limit reached (\(maxElements)).\n", stderr) }
