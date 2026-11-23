import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        Rime.cleanUpLegacyData()
        LoginItem.ensure()
        NSApp.mainMenu = editMenu()
        let first = !FileManager.default.fileExists(atPath: Store.dir.appendingPathComponent("welcomed").path)
        // C1: 每次启动都确认输入法已登记并启用，第一次还直接切换过去
        let ready = Rime.ensureInputSource(select: first)
        // C2: 输入法下拉菜单里的「一炁输入法设置…」通过这个通知打开设置窗口
        DistributedNotificationCenter.default().addObserver(forName: .init("im.yiqi.app.openSettings"), object: nil,
                                                            queue: .main) { [weak self] _ in self?.openSettings() }
        let background = CommandLine.arguments.contains("--background")
        if first || !ready || model.pairCode == nil || !background {
            FileManager.default.createFile(atPath: Store.dir.appendingPathComponent("welcomed").path, contents: nil)
            openSettings()
        }
    }

    // C5: 设置窗口里要能粘贴；后台程序没有主菜单，粘贴快捷键靠这个编辑菜单生效
    private func editMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        let args = [exe, "--background"]
        let dict: [String: Any] = ["Label": "im.yiqi.app", "ProgramArguments": args, "RunAtLoad": true,
                                   "LimitLoadToSessionType": "Aqua"]
        if let old = NSDictionary(contentsOf: plist) as? [String: Any],
           (old["ProgramArguments"] as? [String]) == args { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        (dict as NSDictionary).write(to: plist, atomically: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
