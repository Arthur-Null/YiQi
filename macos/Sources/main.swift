import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

final class Model: ObservableObject {
    @Published var scheme: Scheme = Rime.scheme
    @Published var status: SyncStatus = .unpaired
    @Published var pairCode: String? = Store.pairCode
    @Published var pairError = false
    @Published var input = ""
    @Published var showReplace = false
    let sync = ClipboardSync()

    init() {
        sync.onStatus = { [weak self] s in self?.status = s }
        sync.configure(pairCode.flatMap(QiKey.init(pairCode:)))
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let s = Rime.scheme
            if self?.scheme != s { self?.scheme = s }
        }
    }

    func choose(_ s: Scheme) {
        Rime.request(s)
        scheme = s
    }

    func pair(_ code: String) {
        guard let k = QiKey(pairCode: code) else { pairError = true; return }
        pairError = false
        Store.pairCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        pairCode = Store.pairCode
        sync.configure(k)
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: Binding(get: { model.scheme }, set: { model.choose($0) })) {
                        ForEach(Scheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("快捷键：Ctrl + Shift + 1 在两者之间切换。菜单栏的「鹤 / 全」也可以随时点选。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("在系统的输入法菜单里，一炁显示为「鼠须管」（它使用的输入引擎）。")
                        .font(.callout).foregroundStyle(.secondary)
                    if !Rime.squirrelInstalled {
                        Text("还没有装好输入法本体，请重新打开安装包。").foregroundStyle(.red)
                    }
                }.padding(6)
            } label: { Text("输入方式").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(model.status == .connected ? .green : (model.status == .unpaired ? .gray : .orange))
                            .frame(width: 8, height: 8)
                        Text(model.status.label)
                        // C7: 显示当前使用的服务器（来自配对码）
                        if let host = model.pairCode.flatMap(QiKey.init(pairCode:))?.server.host {
                            Text("服务器：\(host)").foregroundStyle(.secondary)
                        }
                    }
                    if let code = model.pairCode, !model.showReplace {
                        HStack(alignment: .top, spacing: 16) {
                            if let img = qr(code) {
                                Image(nsImage: img).interpolation(.none).resizable().frame(width: 180, height: 180)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("在手机上打开一炁输入法 →「输入方式与剪贴板同步」→「扫码配对」，扫描左侧二维码。")
                                Text("其他电脑：点「复制配对码」，在那台电脑的一炁设置里粘贴。")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("复制配对码") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(code, forType: .string)
                                    }
                                    Button("换一个配对码…") { model.showReplace = true }
                                }
                            }.font(.callout)
                        }
                    } else {
                        Text("粘贴配对码（qi://pair 开头），这台电脑就会加入剪贴板同步。配对码由你的服务器生成，包含服务器地址。").font(.callout)
                        HStack {
                            TextField("qi://pair?...", text: $model.input).textFieldStyle(.roundedBorder)
                            Button("配对") { model.pair(model.input); if !model.pairError { model.showReplace = false; model.input = "" } }
                            if model.showReplace { Button("取消") { model.showReplace = false } }
                        }
                        if model.pairError { Text("配对码不对，请重新复制完整的配对码。").foregroundStyle(.red) }
                    }
                    Text("复制的文字会加密后同步到你自己的其他设备，在那里直接粘贴即可。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(6)
            } label: { Text("剪贴板同步").font(.headline) }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func qr(_ s: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

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
