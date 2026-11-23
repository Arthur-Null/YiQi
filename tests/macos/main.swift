// C3, C5: 两份独立剪贴板模拟两台 Mac，经中转同步长文本；由 sync/relay/macos_test.go 驱动。
import AppKit

let code = CommandLine.arguments[1]
let long = try! String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let pa = NSPasteboard(name: .init("qi-test-a")), pb = NSPasteboard(name: .init("qi-test-b"))
pa.clearContents(); pb.clearContents()
let a = ClipboardSync(pasteboard: pa, deviceID: "mac-a")
let b = ClipboardSync(pasteboard: pb, deviceID: "mac-b")
a.configure(QiKey(pairCode: code)!)
b.configure(QiKey(pairCode: code)!)

func wait(_ what: String, _ cond: () -> Bool) {
    let end = Date().addingTimeInterval(10)
    while !cond() {
        if Date() > end { print("TIMEOUT \(what)"); exit(1) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    print("OK \(what)")
}

wait("connected") { a.status == .connected && b.status == .connected }
pa.clearContents(); pa.setString(long, forType: .string)
wait("b-received-long") { pb.string(forType: .string) == long }
print("READY")
fflush(stdout)
wait("both-received-remote") {
    pa.string(forType: .string) == "来自另一台设备" && pb.string(forType: .string) == "来自另一台设备"
}
exit(0)
