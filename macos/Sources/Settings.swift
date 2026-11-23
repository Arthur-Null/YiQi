import AppKit
import Combine
import SwiftUI

final class Model: ObservableObject {
    @Published var scheme: Scheme = Rime.scheme
    @Published var status: SyncStatus = .unpaired
    @Published var pairCode: String? = Store.pairCode
    @Published var message: String?
    @Published var codeInput = ""
    @Published var serverInput = ""
    @Published var busy = false
    @Published var inviteCode: String?
    @Published var inviteDeadline = Date()
    @Published var hotkey: Hotkey = Rime.hotkey
    @Published var recording = false
    @Published var inputSourceReady = Rime.inputSourceEnabled
    @Published var update: Updater.Release?
    @Published var updateMessage: String?
    let sync = ClipboardSync()
    private var monitor: Any?

    init() {
        sync.onStatus = { [weak self] s in self?.status = s }
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkUpdate() }
        sync.configure(pairCode.flatMap(QiKey.init(pairCode:)))
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = Rime.scheme
            if self.scheme != s { self.scheme = s }
            let ready = Rime.inputSourceEnabled
            if self.inputSourceReady != ready {
                self.inputSourceReady = ready
                // C1: 用户刚在系统设置里添加好，立即切换过去并部署词库
                if ready {
                    Rime.ensureInputSource(select: true)
                    Rime.deploy()
                }
            }
        }
    }

    var serverHost: String? { pairCode.flatMap(QiKey.init(pairCode:))?.server.host }

    func checkUpdate() {
        Updater.check { [weak self] r in
            self?.update = r
            // C2: 告诉输入法下拉菜单是否显示「有新版本」
            let flag = Store.dir.appendingPathComponent("update-available.txt")
            if let r { try? r.version.write(to: flag, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: flag) }
        }
    }

    func installUpdate() {
        guard let r = update else { return }
        updateMessage = "正在下载 \(r.version)…"
        Updater.install(r) { [weak self] err in
            self?.updateMessage = err ?? "安装程序已打开，按提示完成安装即可（需要输入一次电脑密码）。"
        }
    }

    func choose(_ s: Scheme) {
        Rime.request(s)
        scheme = s
    }

    private func save(_ k: QiKey) {
        Store.pairCode = k.pairCode
        pairCode = Store.pairCode
        codeInput = ""
        message = nil
        busy = false
        sync.configure(k)
    }

    private func finish(_ r: Result<QiKey, Pairing.Failure>) {
        busy = false
        switch r {
        case .success(let k): save(k)
        case .failure(let e): message = e.message
        }
    }

    // C5, C7: 新设备凭已同步设备给出的临时密码加入
    func join() {
        busy = true
        message = "正在加入…"
        Pairing.join(server: serverInput, code: codeInput) { self.finish($0) }
    }

    // C5, C7: 第一台设备凭服务器给出的临时密码注册同步组
    func register() {
        busy = true
        message = "正在注册…"
        Pairing.register(server: serverInput, code: codeInput) { self.finish($0) }
    }

    func startInvite() {
        guard let code = sync.startInvite() else { message = "需要先连上服务器才能添加设备。"; return }
        inviteCode = code
        inviteDeadline = Date().addingTimeInterval(300)
        message = nil
    }

    func stopInvite() {
        sync.stopInvite()
        inviteCode = nil
    }

    func leave() {
        let a = NSAlert()
        a.messageText = "让这台电脑退出同步组？"
        a.informativeText = "之后需要在其他已同步的设备上点「添加设备」才能重新加入。"
        a.addButton(withTitle: "退出")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        stopInvite()
        Store.pairCode = nil
        pairCode = nil
        sync.configure(nil)
    }

    // C2: 录制新的切换快捷键；Esc 取消
    func recordHotkey() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.stopRecording(); return nil }
            if let h = Hotkey(event: e) {
                Rime.setHotkey(h)
                self.hotkey = h
                self.stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    func resetHotkey() {
        Rime.setHotkey(Rime.defaultHotkey)
        hotkey = Rime.defaultHotkey
    }
}

struct SettingsView: View {
    @ObservedObject var model: Model

    private func note(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let u = model.update {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("有新版本 \(u.version)（当前 \(Updater.current)）").font(.headline)
                            Button("下载并安装") { model.installUpdate() }
                        }
                        if let m = model.updateMessage { note(m) }
                    }.padding(6)
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if !Rime.squirrelInstalled {
                        Text("还没有装好输入法本体，请重新打开安装包。").foregroundStyle(.red)
                    } else if !model.inputSourceReady {
                        // C1: 新版 macOS 需要用户在系统设置里添加一次输入法，这里一步步引导
                        VStack(alignment: .leading, spacing: 6) {
                            Text("还差一步：把一炁添加到系统输入法").font(.headline).foregroundStyle(.red)
                            Text("1. 点下面的「打开输入法设置」\n2. 在「文字输入」的「输入法」一行点「编辑…」，再点左下角的 +\n3. 左边选「简体中文」，右边选「一炁输入法」，点「添加」")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            note("添加好后这里会自动消失，一炁会直接切换过去，不需要注销或重启。")
                            Button("打开输入法设置") { Rime.openInputSourceSettings() }
                        }
                        Divider()
                    }
                    Picker("", selection: Binding(get: { model.scheme }, set: { model.choose($0) })) {
                        ForEach(Scheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    HStack {
                        Text("切换快捷键")
                        Button(model.recording ? "请按下新的快捷键…（Esc 取消）" : model.hotkey.label) {
                            model.recording ? model.stopRecording() : model.recordHotkey()
                        }
                        if model.hotkey != Rime.defaultHotkey && !model.recording {
                            Button("恢复默认") { model.resetHotkey() }
                        }
                    }
                    note("快捷键需包含 Ctrl 或 Option（F1–F12 可单独使用）。也可以点菜单栏的一炁图标，选「切换至全拼 / 小鹤双拼」。")
                }.padding(6)
            } label: { Text("输入方式").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Circle().fill(model.status == .connected ? .green : (model.status == .unpaired ? .gray : .orange))
                            .frame(width: 8, height: 8)
                        Text(model.status.label)
                        if let host = model.serverHost {
                            Text("服务器：\(host)").foregroundStyle(.secondary)
                        }
                    }
                    if model.pairCode != nil {
                        if let code = model.inviteCode {
                            inviteView(code)
                        } else {
                            HStack {
                                Button("添加设备…") { model.startInvite() }
                                Button("退出同步组…") { model.leave() }
                            }
                            note("要让手机或另一台电脑加入，点「添加设备」，会生成一个 6 位临时密码。")
                        }
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow {
                                Text("服务器地址")
                                TextField("例如 yiqi.example.com", text: $model.serverInput).textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("临时密码")
                                TextField("6 位数字", text: $model.codeInput).textFieldStyle(.roundedBorder).frame(width: 120)
                            }
                        }
                        HStack {
                            Button("加入同步组") { model.join() }.disabled(model.busy)
                            note("临时密码在已同步的设备上点「添加设备」获得。")
                        }
                        HStack {
                            Button("注册新同步组") { model.register() }.disabled(model.busy)
                            note("第一台设备用这个；临时密码在服务器上运行 yiqi-relay code 生成，10 分钟内有效。")
                        }
                    }
                    if let m = model.message {
                        Text(m).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    note("复制的文字会在本机加密后，经你的服务器同步到同组的其他设备，在那里直接粘贴即可。")
                }.padding(6)
            } label: { Text("剪贴板同步").font(.headline) }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("版本 \(Updater.current)").font(.caption).foregroundStyle(.tertiary).padding(.trailing, 24).padding(.bottom, 4)
        }
        .padding(20)
        .frame(width: 560)
    }

    private func inviteView(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在新设备的一炁设置里填写：").font(.callout)
            Text("服务器地址  \(model.serverHost ?? "")").font(.title3)
            HStack(alignment: .firstTextBaseline) {
                Text("临时密码").font(.title3)
                Text("\(String(code.prefix(3))) \(String(code.suffix(3)))")
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(model.inviteDeadline.timeIntervalSince(ctx.date)))
                Text(left > 0 ? "\(left / 60):\(String(format: "%02d", left % 60)) 内有效，请保持此窗口打开" : "已过期，请重新生成")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("完成") { model.stopInvite() }
                Button("重新生成") { model.startInvite() }
            }
        }
    }
}
