// 调试用：每 0.2 秒读一次 Zoom 会议窗口里所有含名字的元素，有变化就打印
import AppKit
import ApplicationServices
let secs = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first else { exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> Any? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func collect(_ e: AXUIElement, _ d: Int, _ out: inout [String]) {
    if d > 25 { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let desc = attr(e, kAXDescriptionAttribute) as? String ?? ""
    let title = attr(e, kAXTitleAttribute) as? String ?? ""
    let val = attr(e, kAXValueAttribute).map { "\($0)" } ?? ""
    if role == "AXTabGroup" || role == "AXCell" || role == "AXRow" || role == "AXStaticText" || (role == "AXButton" && attr(e, kAXIdentifierAttribute) == nil && !desc.contains("options")) {
        let s = [role, desc, title, val].filter { !$0.isEmpty }.joined(separator: " | ")
        if !s.isEmpty { out.append(String(repeating: " ", count: d) + s) }
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { collect(c, d + 1, &out) }
}
var last = ""
let t0 = Date()
while Date().timeIntervalSince(t0) < secs {
    var out: [String] = []
    for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []) { collect(w, 0, &out) }
    let s = out.joined(separator: "\n")
    if s != last { print(String(format: "--- t=%.1fs", Date().timeIntervalSince(t0))); print(s); last = s }
    Thread.sleep(forTimeInterval: 0.2)
}
