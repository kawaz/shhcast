// Electron/Chromium に web AX ツリーの公開を要求する (AXManualAccessibility / AXEnhancedUserInterface)
import AppKit
import ApplicationServices
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Slack"
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name || $0.bundleIdentifier == name }) else { print("app not found: \(name)"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
for attr in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
  let r = AXUIElementSetAttributeValue(ax, attr as CFString, kCFBooleanTrue)
  print("\(attr): \(r.rawValue == 0 ? "ok" : "err \(r.rawValue)")")
}
