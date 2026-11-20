// 调试用：打印 Zoom 视频格（AXTabGroup）的全部属性
import AppKit
import ApplicationServices
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first else { exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> Any? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func walk(_ e: AXUIElement, _ d: Int) {
    if d > 25 { return }
    let role = attr(e, kAXRoleAttribute) as? String ?? ""
    if role == "AXTabGroup" || (d > 0 && role == "AXButton" && attr(e, kAXIdentifierAttribute) == nil && (attr(e, kAXDescriptionAttribute) as? String ?? "").count < 30 && !(attr(e, kAXDescriptionAttribute) as? String ?? "").isEmpty && d >= 2) {
        var names: CFArray?
        AXUIElementCopyAttributeNames(e, &names)
        print(String(repeating: "  ", count: d) + "== \(role)")
        for n in (names as? [String] ?? []) where n != kAXChildrenAttribute && n != kAXParentAttribute && n != kAXWindowAttribute && n != kAXTopLevelUIElementAttribute {
            if let v = attr(e, n) { print(String(repeating: "  ", count: d) + "   \(n) = \("\(v)".prefix(160))") }
        }
    }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement] ?? []) where (attr(w, kAXIdentifierAttribute) as? String) == "zm.meeting.window.main" { walk(w, 0) }
