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

final class SubtitleView: NSView {
    let zh = NSTextField(wrappingLabelWithString: "")
    let en = NSTextField(wrappingLabelWithString: "")
    let grip = GripView()
    var zhText = "" { didSet { if zhText != oldValue { needsLayout = true } } }
    var enText = "" { didSet { if enText != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        applyOpacity()
        for (label, color) in [(zh, NSColor.white), (en, NSColor(white: 0.82, alpha: 1))] {
            label.textColor = color
            label.alignment = .center
            label.isSelectable = false
            label.drawsBackground = false
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byWordWrapping
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.9)
            shadow.shadowBlurRadius = 3
            label.shadow = shadow
            addSubview(label)
        }
        addSubview(grip)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyOpacity() {
        let a = defaults.object(forKey: "bgAlpha") as? Double ?? 0.55
        layer?.backgroundColor = NSColor(white: 0, alpha: CGFloat(a)).cgColor
    }

    /// 只保留文本末尾能放进两行的部分（长句滚动显示最新内容）。
    private func tail(_ s: String, maxChars: Int, wordBoundary: Bool) -> String {
        guard s.count > maxChars else { return s }
        var t = String(s.suffix(maxChars))
        if wordBoundary, let sp = t.firstIndex(of: " ") { t = String(t[t.index(after: sp)...]) }
        return "…" + t
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let pad: CGFloat = 20
        let showEn = h >= 96
        let zhSize = min(max(h * (showEn ? 0.25 : 0.34), 17), 46)
        let enSize = min(max(h * 0.115, 11), 19)
        zh.font = NSFont.systemFont(ofSize: zhSize, weight: .semibold)
        en.font = NSFont.systemFont(ofSize: enSize, weight: .regular)
        en.isHidden = !showEn

        let zhPerLine = max(6, Int((w - 2 * pad) / zhSize))
        let enPerLine = max(16, Int((w - 2 * pad) / (enSize * 0.52)))
        let enH = showEn ? enSize * 2.6 : 0
        let zhLines = (h - enH - 16) >= zhSize * 2.5 ? 2 : 1
        zh.maximumNumberOfLines = zhLines
        zh.stringValue = tail(zhText, maxChars: zhPerLine * zhLines - 1, wordBoundary: false)
        en.stringValue = tail(enText, maxChars: enPerLine * 2 - 2, wordBoundary: true)

        en.frame = NSRect(x: pad, y: 8, width: w - 2 * pad, height: enH)
        let zhH = min(h - enH - 16, zhSize * 1.32 * CGFloat(zhLines))
        zh.frame = NSRect(x: pad, y: 8 + enH + max(0, (h - enH - 16 - zhH) / 2), width: w - 2 * pad, height: zhH)
        grip.frame = NSRect(x: w - 18, y: 0, width: 18, height: 18)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: NSPanel!
    var view: SubtitleView!
    var failures = 0

    func defaultFrame() -> NSRect {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let w = min(max(vf.width * 0.52, 720), 1150)
        let h: CGFloat = 128
        return NSRect(x: vf.midX - w / 2, y: vf.minY + vf.height * 0.13, width: w, height: h)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        var frame = defaultFrame()
        if let s = defaults.string(forKey: "frame") {
            let f = NSRectFromString(s)
            // 记住的位置必须还在某块屏幕上，否则回到默认
            if f.width >= 300, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { frame = f }
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
        panel.minSize = NSSize(width: 360, height: 64)
        panel.delegate = self
        view = SubtitleView(frame: NSRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.menu = buildMenu()
        view.zhText = "悬浮字幕已打开"
        view.enText = "拖动移动 · 拖右下角或边缘改大小 · 右键更多选项"
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
        m.addItem(withTitle: "关闭悬浮字幕", action: #selector(quit), keyEquivalent: "").target = self
        return m
    }

    @objc func resetFrame() { panel.setFrame(defaultFrame(), display: true, animate: true); saveFrame() }
    @objc func setAlpha(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? Double ?? 0.55, forKey: "bgAlpha")
        view.applyOpacity()
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
            let (zh, en) = AppDelegate.pick(s)
            DispatchQueue.main.async {
                self.failures = 0
                self.view.zhText = zh
                self.view.enText = en
            }
        }.resume()
    }

    /// 选出当前要显示的一句：正在说的句子优先；它的译文还没出来时先沿用上一句译文。
    static func pick(_ s: [String: Any]) -> (String, String) {
        let source = s["source"] as? String ?? "system"
        let engine = s["engine"] as? String ?? "off"
        let lines = (s["lines"] as? [[String: Any]] ?? []).filter { ($0["label"] as? String) != "me" || source == "mic" }
        let lastZh = lines.last?["zh"] as? String ?? ""
        let lastEn = lines.last?["en"] as? String ?? ""
        if let parts = s["partials"] as? [String: [String: Any]] {
            for (label, p) in parts where label != "me" || source == "mic" {
                let text = p["text"] as? String ?? ""
                if text.isEmpty { continue }
                let pz = p["zh"] as? String ?? ""
                return (pz.isEmpty ? (lastZh.isEmpty ? "…" : lastZh) : pz, text)
            }
        }
        if !lastEn.isEmpty { return (lastZh.isEmpty ? "…" : lastZh, lastEn) }
        switch engine {
        case "listening": return ("正在听…", "有人说英文时这里出字幕")
        case "loading": return ("正在加载模型…", s["status_msg"] as? String ?? "")
        default: return ("未开始", "在会议助手窗口里点\u{201C}开始\u{201D}")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
