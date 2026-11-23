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
        NSApp.mainMenu = editMenu()
        let first = !FileManager.default.fileExists(atPath: Store.dir.appendingPathComponent("welcomed").path)
        // C1: 每次启动都确认输入法已登记并启用，第一次还直接切换过去
        let ready = Rime.ensureInputSource(select: first)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        observers.append(model.$scheme.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTitle() } })
        observers.append(model.$update.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshTitle() } })
        if first || !ready || model.pairCode == nil {
            FileManager.default.createFile(atPath: Store.dir.appendingPathComponent("welcomed").path, contents: nil)
            openSettings()
        }
    }

    // C5: 设置窗口里要能粘贴配对码；菜单栏程序没有主菜单，粘贴快捷键靠这个编辑菜单生效
    private func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "退出一炁", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func refreshTitle() {
        item.button?.title = model.scheme.short + (model.update == nil ? "" : "↑")
        item.button?.toolTip = "一炁输入法：\(model.scheme.title)（\(model.hotkey.label) 切换）"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.scheme = Rime.scheme
        menu.removeAllItems()
        if let u = model.update {
            let up = NSMenuItem(title: "有新版本 \(u.version)，点此更新…", action: #selector(updateAction), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
            menu.addItem(.separator())
        }
        let head = NSMenuItem(title: "输入方式（\(model.hotkey.label) 切换）", action: nil, keyEquivalent: "")
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
        let open = NSMenuItem(title: model.pairCode == nil ? "设置…" : "设置与配对手机…",
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

    @objc func updateAction() {
        model.installUpdate()
        openSettings()
    }

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
