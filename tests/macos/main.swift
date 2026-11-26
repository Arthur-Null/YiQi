// C3, C5, C7: 两份独立剪贴板模拟两台 Mac：第一台凭服务器临时密码注册同步组，第二台凭「添加设备」的临时密码加入，
// 然后经中转同步长文本；由 sync/relay/macos_test.go 驱动。
import AppKit

let server = CommandLine.arguments[1]
let setupCode = CommandLine.arguments[2]
let long = try! String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
let pa = NSPasteboard(name: .init("qi-test-a")), pb = NSPasteboard(name: .init("qi-test-b"))
pa.clearContents(); pb.clearContents()

func wait(_ what: String, _ cond: () -> Bool) {
    let end = Date().addingTimeInterval(15)
    while !cond() {
        if Date() > end { print("TIMEOUT \(what)"); exit(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    print("OK \(what)")
    fflush(stdout)
}

var registered: Result<QiKey, Pairing.Failure>?
Pairing.register(server: server, code: "000000" == setupCode ? "111111" : "000000") { registered = $0 }
wait("register-wrong-code-rejected") { if case .failure(.wrongCode) = registered { return true }; return false }
registered = nil
Pairing.register(server: server, code: setupCode) { registered = $0 }
wait("registered") { if case .success = registered { return true }; return false }
guard case .success(let ka) = registered else { exit(1) }
print("PAIRED \(ka.pairCode)")

let a = ClipboardSync(pasteboard: pa, deviceID: "mac-a")
a.configure(ka)
wait("a-connected") { a.status == .connected }
let code = a.startInvite()!
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
var joined: Result<QiKey, Pairing.Failure>?
Pairing.join(server: server, code: code == "000000" ? "111111" : "000000") { joined = $0 }
wait("join-wrong-code-rejected") { if case .failure(.wrongCode) = joined { return true }; return false }
joined = nil
Pairing.join(server: server, code: code) { joined = $0 }
wait("joined") { if case .success = joined { return true }; return false }
guard case .success(let kb) = joined, kb.raw == ka.raw else { print("TIMEOUT key-mismatch"); exit(1) }
a.stopInvite()

// C9: 用文件模拟 Rime 的词库导出：触发同步时把本机快照写到 sync/<安装号>/
let dictDir = FileManager.default.temporaryDirectory.appendingPathComponent("qi-dict-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dictDir, withIntermediateDirectories: true)
try! "installation_id: \"install-b\"\n".write(to: dictDir.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
let ownDict = "# Rime user dictionary\n#@/tick\t1\nni hao\t你好\tc=1\n"
let dictSync = DictSync(userDir: dictDir) {
    let f = dictDir.appendingPathComponent("sync/install-b/\(DictSync.file)")
    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? ownDict.write(to: f, atomically: true, encoding: .utf8)
}
dictSync.first = 0.2; dictSync.debounce = 0.2; dictSync.wait = 3
let b = ClipboardSync(pasteboard: pb, deviceID: "mac-b")
b.dict = dictSync
b.configure(kb)
wait("b-connected") { b.status == .connected }
pa.clearContents(); pa.setString(long, forType: .string)
wait("b-received-long") { pb.string(forType: .string) == long }
print("READY")
fflush(stdout)
wait("both-received-remote") {
    pa.string(forType: .string) == "来自另一台设备" && pb.string(forType: .string) == "来自另一台设备"
}
wait("dict-from-phone-stored") {
    (try? String(contentsOf: dictDir.appendingPathComponent("sync/phone/\(DictSync.file)"), encoding: .utf8))
        == "wo men\t我们\tc=3\n"
}
print("DICT-OK")
fflush(stdout)
RunLoop.main.run(until: Date().addingTimeInterval(1))
exit(0)
