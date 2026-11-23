// C2: 升级到随输入法本体提供词库的新版时，用户目录里旧版复制的未改动副本被清掉，用户改过的和自己的文件保留。
import CryptoKit
import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("yiqi-clean-\(UUID().uuidString)")
let shared = root.appendingPathComponent("shared"), user = root.appendingPathComponent("user")
func write(_ dir: URL, _ name: String, _ text: String) {
    let u = dir.appendingPathComponent(name)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: u, atomically: true, encoding: .utf8)
}
func exists(_ name: String) -> Bool { fm.fileExists(atPath: user.appendingPathComponent(name).path) }
func check(_ ok: Bool, _ what: String) { print(ok ? "OK \(what)" : "FAIL \(what)"); if !ok { exit(1) } }
func sha(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

for (n, t) in [("rime_ice.dict.yaml", "dict v2"), ("custom_phrase.txt", "phrase v2"), ("lua/qi_switch.lua", "lua v2"), ("build/x.bin", "bin")] {
    write(shared, n, t)
}
write(user, "rime_ice.dict.yaml", "dict v1")
write(user, "custom_phrase.txt", "my phrases")
write(user, "lua/qi_switch.lua", "lua v1")
write(user, "build/x.bin", "user build")
write(user, "rime_ice.custom.yaml", "# C2: 旧版一炁的调整")
write(user, "squirrel.custom.yaml", "patch: {}")
write(user, "qi_schema.txt", "rime_ice 1")
let manifest = ["rime_ice.dict.yaml": sha("dict v1"), "custom_phrase.txt": sha("phrase v1"), "lua/qi_switch.lua": sha("lua v1")]
try! JSONEncoder().encode(manifest).write(to: user.appendingPathComponent("qi_installed.json"))

check(Rime.cleanUp(userDir: user, shared: shared), "cleanup ran")
check(!exists("rime_ice.dict.yaml") && !exists("lua/qi_switch.lua"), "unmodified old copies removed")
check(exists("custom_phrase.txt"), "user-edited file kept")
check(!exists("rime_ice.custom.yaml"), "legacy qi patch removed")
check(exists("squirrel.custom.yaml") && exists("qi_schema.txt") && exists("build/x.bin"), "user's own files kept")
check(!exists("qi_installed.json"), "old manifest removed")
try? fm.removeItem(at: root)
