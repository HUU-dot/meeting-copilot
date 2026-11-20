// 调试用：打印 Zoom 会议窗口的辅助功能树（角色、标题、描述、值、帮助）
import AppKit
import ApplicationServices
print("trusted:", AXIsProcessTrusted())
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first else { print("no zoom"); exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> Any? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func dump(_ e: AXUIElement, _ d: Int) {
    if d > 25 { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    var parts = [role]
    for a in [kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXIdentifierAttribute] {
        if let v = attr(e, a) { let s = "\(v)"; if !s.isEmpty && s.count < 200 { parts.append("\(a.replacingOccurrences(of: "AX", with: ""))=\(s)") } }
    }
    print(String(repeating: "  ", count: d) + parts.joined(separator: " | "))
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { dump(c, d + 1) }
}
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []) where (attr(w, kAXTitleAttribute) as? String ?? "").contains("会议") { dump(w, 0) }
