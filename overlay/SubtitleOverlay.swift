// 会议助手 · 悬浮字幕窗
// 半透明、圆角、始终置顶（含全屏应用之上）；拖动窗口任意处移动，拖边缘或右下角改大小；
// 位置和大小自动记住。内容每 0.12 秒从本机面板服务 http://127.0.0.1:<port>/state 读取。
// 编译：swiftc -O -o SubtitleOverlay SubtitleOverlay.swift
import AppKit

let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8766"
let stateURL = URL(string: "http://127.0.0.1:\(port)/state")!
let defaults = UserDefaults.standard

final class GripView: NSView {
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.35).setStroke()
        let p = NSBezierPath()
        for i in 0..<3 {
            let o = CGFloat(4 + i * 4)
            p.move(to: NSPoint(x: bounds.maxX - 3, y: o))
            p.line(to: NSPoint(x: bounds.maxX - o, y: 3))
        }
        p.lineWidth = 1.2
        p.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        startFrame = window!.frame
        startMouse = NSEvent.mouseLocation
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        let newW = max(w.minSize.width, startFrame.width + (m.x - startMouse.x))
        let newH = max(w.minSize.height, startFrame.height - (m.y - startMouse.y))
        // 右下角拖动：左上角保持不动
        w.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - newH, width: newW, height: newH), display: true)
    }
}

/// 一句字幕：中文 + 英文原文
struct Sub: Equatable { var zh: String; var en: String }

/// 字幕绘制区。每句一样大（字号固定，可在右键菜单里换）；窗口越大放下的句子越多：
/// 从最新一句往前排，放得下几句就显示几句，最新一句贴底；一句都放不下时只显示最新一句的末尾。
final class SubtitleView: NSView {
    let grip = GripView()
    var subs: [Sub] = [] { didSet { if subs != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        applyOpacity()
        addSubview(grip)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyOpacity() {
        let a = defaults.object(forKey: "bgAlpha") as? Double ?? 0.55
        layer?.backgroundColor = NSColor(white: 0, alpha: CGFloat(a)).cgColor
    }

    static var zhSize: CGFloat { CGFloat(defaults.object(forKey: "fontSize") as? Double ?? 22) }

    private func attributed(_ s: Sub) -> NSAttributedString {
        let zhSize = SubtitleView.zhSize
        let enSize = max(11, (zhSize * 0.62).rounded())
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.9)
        shadow.shadowBlurRadius = 3
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let out = NSMutableAttributedString(string: s.zh, attributes: [
            .font: NSFont.systemFont(ofSize: zhSize, weight: .semibold),
            .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: para])
        if !s.en.isEmpty {
            let p2 = para.mutableCopy() as! NSMutableParagraphStyle
            p2.paragraphSpacingBefore = 2
            out.append(NSAttributedString(string: "\n" + s.en, attributes: [
                .font: NSFont.systemFont(ofSize: enSize, weight: .regular),
                .foregroundColor: NSColor(white: 0.82, alpha: 1), .shadow: shadow, .paragraphStyle: p2]))
        }
        return out
    }

    override func layout() { super.layout(); grip.frame = NSRect(x: bounds.width - 18, y: bounds.height - 18, width: 18, height: 18) }

    override var isFlipped: Bool { true }   // 原点在左上，方便 TextKit 绘制

    /// 用同一套排版既量高度又绘制，避免量出来的高度和实际画出来的不一致
    /// 返回值里保留 NSTextStorage：NSLayoutManager 只弱引用它，不保留的话画出来是空的
    private func layout(_ a: NSAttributedString, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer, CGFloat) {
        let storage = NSTextStorage(attributedString: a)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: tc)
        return (storage, lm, tc, ceil(lm.usedRect(for: tc).height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let padX: CGFloat = 20, padY: CGFloat = 10, gap = SubtitleView.zhSize * 0.45
        let w = bounds.width - 2 * padX
        let avail = bounds.height - 2 * padY
        guard w > 40, !subs.isEmpty else { return }
        // 从最新一句往前，放得下就加上（至少一句）
        var blocks: [(NSTextStorage, NSLayoutManager, NSTextContainer, CGFloat)] = []
        var used: CGFloat = 0
        for s in subs.reversed() {
            let b = layout(attributed(s), width: w)
            let need = used + (blocks.isEmpty ? 0 : gap) + b.3
            if !blocks.isEmpty && need > avail { break }
            blocks.append(b)
            used = need
        }
        // 自上而下画：最旧的在上、最新的贴底；放得下时整体垂直居中，放不下（只剩一句也太长）时贴底、顶部被裁掉
        var y = padY + (used <= avail ? (avail - used) / 2 : avail - used)
        for (_, lm, tc, h) in blocks.reversed() {
            lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: tc), at: NSPoint(x: padX, y: y))
            y += h + gap
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var view: SubtitleView!
    var failures = 0

    /// 鼠标所在的屏幕（点“悬浮字幕”时鼠标就在会议助手窗口上，字幕就出现在用户正在看的那块屏幕）
    func mouseScreen() -> NSScreen {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func defaultFrame() -> NSRect {
        let vf = mouseScreen().visibleFrame
        let w = min(max(vf.width * 0.52, 720), 1150)
        let h: CGFloat = 150
        return NSRect(x: vf.midX - w / 2, y: vf.minY + vf.height * 0.13, width: w, height: h)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        var frame = defaultFrame()
        if let s = defaults.string(forKey: "frame") {
            let f = NSRectFromString(s)
            // 记住的位置只在它就在鼠标所在的那块屏幕上时沿用；在别的屏幕上就到当前屏幕的默认位置
            if f.width >= 300, mouseScreen().visibleFrame.intersects(f) { frame = f }
        }
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 360, height: 72)   // 最小也放得下一句（一行中文 + 一行英文）
        panel.delegate = self
        view = SubtitleView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.menu = buildMenu()
        view.subs = [Sub(zh: "悬浮字幕已打开", en: "拖动移动 · 拖右下角或边缘改大小 · 右键更多选项")]
        panel.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.poll() }
    }

    func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "回到默认位置和大小", action: #selector(resetFrame), keyEquivalent: "").target = self
        m.addItem(.separator())
        for (title, a) in [("背景：更透明", 0.35), ("背景：半透明", 0.55), ("背景：更深", 0.8)] {
            let it = m.addItem(withTitle: title, action: #selector(setAlpha(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = a
        }
        m.addItem(.separator())
        for (title, sz) in [("字号：小", 18.0), ("字号：中", 22.0), ("字号：大", 28.0)] {
            let it = m.addItem(withTitle: title, action: #selector(setFont(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sz
        }
        m.addItem(.separator())
        m.addItem(withTitle: "关闭悬浮字幕", action: #selector(quit), keyEquivalent: "").target = self
        return m
    }

    @objc func resetFrame() { panel.setFrame(defaultFrame(), display: true, animate: true); saveFrame() }
    @objc func setAlpha(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? Double ?? 0.55, forKey: "bgAlpha")
        view.applyOpacity()
    }
    @objc func setFont(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? Double ?? 22, forKey: "fontSize")
        view.needsDisplay = true
    }
    @objc func quit() { NSApp.terminate(nil) }

    func saveFrame() { defaults.set(NSStringFromRect(panel.frame), forKey: "frame") }
    func windowDidMove(_ n: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ n: Notification) { saveFrame() }
    func windowDidResize(_ n: Notification) { saveFrame() }

    func poll() {
        var req = URLRequest(url: stateURL)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.async {
                    self.failures += 1
                    if self.failures > 15 { NSApp.terminate(nil) }   // 面板服务没了，跟着退出
                }
                return
            }
            let subs = AppDelegate.pick(s)
            DispatchQueue.main.async {
                self.failures = 0
                self.view.subs = subs
            }
        }.resume()
    }

    /// 要显示的句子：最近的若干句定稿 + 正在说的那句，按时间先后；实际显示几句由窗口大小决定。
    static func pick(_ s: [String: Any]) -> [Sub] {
        let source = s["source"] as? String ?? "system"
        let engine = s["engine"] as? String ?? "off"
        var out: [Sub] = (s["lines"] as? [[String: Any]] ?? [])
            .filter { ($0["label"] as? String) != "me" || source == "mic" }
            .suffix(30)
            .map { Sub(zh: ($0["zh"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "…", en: $0["en"] as? String ?? "") }
        if let parts = s["partials"] as? [String: [String: Any]] {
            for (label, p) in parts.sorted(by: { $0.key < $1.key }) where label != "me" || source == "mic" {
                let text = p["text"] as? String ?? ""
                if text.isEmpty { continue }
                let pz = p["zh"] as? String ?? ""
                out.append(Sub(zh: pz.isEmpty ? "…" : pz, en: text))
            }
        }
        if !out.isEmpty { return out }
        switch engine {
        case "listening": return [Sub(zh: "正在听…", en: "有人说英文时这里出字幕")]
        case "loading": return [Sub(zh: "正在加载模型…", en: s["status_msg"] as? String ?? "")]
        default: return [Sub(zh: "未开始", en: "在会议助手窗口里点\u{201C}开始\u{201D}")]
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
