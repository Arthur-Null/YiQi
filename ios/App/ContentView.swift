import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var confirmLeave = false

    var body: some View {
        NavigationStack {
            Form {
                if let u = model.update {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("有新版本 \(u.version)").font(.headline)
                                Text("当前版本 \(QiUpdater.current)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("下载更新") {
                                UIApplication.shared.open(u.download)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.32, green: 0.69, blue: 0.50))
                        }
                    }
                }

                // C1: 首次启用引导，帮助普通用户快速打开系统键盘与完全访问权限
                if !model.keyboardEnabled {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("把一炁添加到系统键盘").font(.headline)
                            Text("1. 点下方「前往系统设置」→「键盘」，开启「一炁输入法」并打开「允许完全访问」\n2. 在「从其他 App 粘贴」中选择「允许」，让手机复制的文字自动同步到电脑\n3. 在任意输入框长按地球键即可切换至「一炁输入法」")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("前往系统设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.32, green: 0.69, blue: 0.50))
                        }
                        .padding(.vertical, 4)
                    }
                }

                // C2: 界面可见可点的输入方式切换
                Section {
                    Picker("输入方式", selection: Binding(get: { model.scheme }, set: { model.choose($0) })) {
                        ForEach(QiScheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("输入方式")
                } footer: {
                    Text("打字时也可以点键盘右上方的「双 / 全」图标随时切换。")
                }

                Section {
                    Picker("按键震动", selection: $model.hapticLevel) {
                        ForEach(0..<QiHaptic.levelTitles.count, id: \.self) { Text(QiHaptic.levelTitles[$0]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("按键震动")
                } footer: {
                    Text("选中后手机会按该强度震一下。键盘需要打开「允许完全访问」才能震动；改完后重新弹出键盘即生效。")
                }

                // C3, C5, C7: 剪贴板同步
                Section {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(model.status == .connected ? .green : (model.status == .unpaired ? .gray : .orange))
                            .frame(width: 8, height: 8)
                        Text(model.status.label)
                        Spacer()
                        if let host = model.serverHost {
                            Text(host).font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    if model.pairCode != nil {
                        if let code = model.inviteCode {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("在新设备的一炁设置里填写：").font(.callout)
                                Text("服务器地址  \(model.serverHost ?? "")").font(.headline)
                                HStack(alignment: .firstTextBaseline) {
                                    Text("临时密码").font(.headline)
                                    Text("\(String(code.prefix(3))) \(String(code.suffix(3)))")
                                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                                }
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    let left = max(0, Int(model.inviteDeadline.timeIntervalSince(ctx.date)))
                                    Text(left > 0 ? "\(left / 60):\(String(format: "%02d", left % 60)) 内有效，请保持此页面打开" : "已过期，请重新生成")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("完成") { model.stopInvite() }.buttonStyle(.bordered)
                                    Button("重新生成") { model.startInvite() }.buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        } else {
                            Button("添加设备…") { model.startInvite() }
                            Button("退出同步组…", role: .destructive) { confirmLeave = true }
                        }
                    } else {
                        TextField("服务器地址，例如 yiqi.example.com", text: $model.serverInput)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("6 位临时密码", text: $model.codeInput)
                            .keyboardType(.numberPad)
                        Button("加入同步组") { model.join() }
                            .disabled(model.busy)
                        Button("注册新同步组") { model.register() }
                            .disabled(model.busy)
                    }

                    if let m = model.message {
                        Text(m).font(.callout).foregroundStyle(.orange)
                    }
                } header: {
                    Text("剪贴板同步")
                } footer: {
                    Text("同步后，在电脑上复制的文字会加密传到手机：打开键盘时顶部会出现这段文字，点一下即可输入；也可以在输入框长按「粘贴」。手机上复制的文字同样会出现在电脑上。")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(QiStore.buildStamp.isEmpty ? QiUpdater.current : "\(QiUpdater.current)（构建 \(QiStore.buildStamp)）")
                            .foregroundStyle(.secondary)
                    }
                    Text("数据位置：\(QiStore.storageDiagnostic)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Toggle("接受测试版更新", isOn: $model.betaUpdates)
                    Button("检查更新") { model.checkUpdate(manual: true) }
                    if model.update == nil, let m = model.updateMessage {
                        Text(m).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("一炁输入法")
            .alert("让这台手机退出同步组？", isPresented: $confirmLeave) {
                Button("退出", role: .destructive) { model.leave() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("之后需要在其他已同步的设备上点「添加设备」才能重新加入。")
            }
        }
    }
}
