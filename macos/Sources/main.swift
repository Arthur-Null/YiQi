import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = Model()
    var item: NSStatusItem!
    var window: NSWindow?
    var observers: [Any] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        Rime.installData()
        LoginItem.ensure()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        observers.append(model.$scheme.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTitle() } })
        if !FileManager.default.fileExists(atPath: Store.dir.appendingPathComponent("welcomed").path) {
            FileManager.default.createFile(atPath: Store.dir.appendingPathComponent("welcomed").path, contents: nil)
            Rime.selectInputSource()
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func refreshTitle() {
        item.button?.title = model.scheme.short
        item.button?.toolTip = "一炁输入法：\(model.scheme.title)（Ctrl+Shift+1 切换）"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.scheme = Rime.scheme
        menu.removeAllItems()
        let head = NSMenuItem(title: "输入方式（Ctrl+Shift+1 切换）", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for s in Scheme.allCases {
            let mi = NSMenuItem(title: s.title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.rawValue
            mi.state = s == model.scheme ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let st = NSMenuItem(title: "剪贴板同步：\(model.status.label)", action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        let open = NSMenuItem(title: model.pairCode == nil ? "设置剪贴板同步…" : "配对手机或其他电脑…",
                              action: #selector(openSettingsAction), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出一炁", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc func pick(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let s = Scheme(rawValue: id) {
            model.choose(s)
            refreshTitle()
        }
    }

    @objc func openSettingsAction() { openSettings() }

    func openSettings() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "一炁输入法"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum LoginItem {
    static func ensure() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let plist = dir.appendingPathComponent("im.yiqi.app.plist")
        let exe = Bundle.main.executablePath ?? "/Applications/YiQi.app/Contents/MacOS/YiQi"
        let dict: [String: Any] = ["Label": "im.yiqi.app", "ProgramArguments": [exe], "RunAtLoad": true,
                                   "LimitLoadToSessionType": "Aqua"]
        if let old = NSDictionary(contentsOf: plist) as? [String: Any],
           (old["ProgramArguments"] as? [String]) == [exe] { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        (dict as NSDictionary).write(to: plist, atomically: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
