// 会议助手 · 面板窗口（原生 WebKit 窗口，取代原来借用 Chrome 的 --app 窗口）
// 关掉这个窗口 = 退出会议助手：停止面板服务、语音引擎、悬浮字幕，并让 Dock 里的“会议助手”一起退出。
// 再次点 Dock 里的“会议助手”时 start.sh 发 SIGUSR1，这里把窗口重新调到最前面，不会开第二个。
// 编译：swiftc -O -o MeetingPanel MeetingPanel.swift
import AppKit
import WebKit

let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8766"
let panelURL = URL(string: "http://127.0.0.1:\(port)/")!
let home = FileManager.default.homeDirectoryForCurrentUser.path
let projectDir = "\(home)/Projects/meeting-copilot"
let launcherURL = URL(fileURLWithPath: "/Applications/会议助手.app", isDirectory: true)

func isLauncherBundle(_ bundleURL: URL?, installedAt launcherURL: URL) -> Bool {
    bundleURL?.resolvingSymlinksInPath().path == launcherURL.resolvingSymlinksInPath().path
}

/// 窗口不在前台时，第一次点击也直接传给页面（否则第一次点击只用来把窗口调到前台，按钮要按两次）
final class PanelWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var usr1: DispatchSourceSignal?
    var shuttingDown = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = buildMenu()

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // localStorage（各模块高度）跨次保留
        web = PanelWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "会议助手"
        window.minSize = NSSize(width: 520, height: 420)
        window.contentView = web
        window.delegate = self
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("MeetingPanel") { window.center() }
        window.setFrameAutosaveName("MeetingPanel")

        web.load(URLRequest(url: panelURL))
        bringToFront()

        // start.sh 发 SIGUSR1 = 用户又点了 Dock 图标
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.bringToFront() }
        src.resume()
        usr1 = src
    }

    func bringToFront() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // 服务还没起来时页面打不开：一秒后重试
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.web.load(URLRequest(url: panelURL))
        }
    }

    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        guard !shuttingDown else { return }
        shuttingDown = true
        signal(SIGTERM, SIG_IGN)                   // stop.sh 会顺带杀面板进程，这里先把收尾做完
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["\(projectDir)/stop.sh"]
        p.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try? p.run()
        p.waitUntilExit()
        // Dock 里的“会议助手”一起退出（它的退出处理会再跑一次 stop.sh，重复无害）
        for app in NSWorkspace.shared.runningApplications where isLauncherBundle(app.bundleURL, installedAt: launcherURL) {
            app.terminate()
        }
    }

    func buildMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出会议助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "刷新", action: #selector(WKWebView.reload(_:)), keyEquivalent: "r")
        winItem.submenu = win
        return main
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不另占一个 Dock 图标：Dock 里只有“会议助手”
let delegate = AppDelegate()
app.delegate = delegate
app.run()
