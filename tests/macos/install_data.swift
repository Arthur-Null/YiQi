// C2: 用户改过的配置文件在升级时保留；未改过的照常更新；旧版占用的 *.custom.yaml 让出给用户。
import Foundation

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("yiqi-install-\(UUID().uuidString)")
let v1 = root.appendingPathComponent("v1"), v2 = root.appendingPathComponent("v2"), user = root.appendingPathComponent("user")
func write(_ dir: URL, _ name: String, _ text: String) {
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try! text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
func read(_ name: String) -> String? { try? String(contentsOf: user.appendingPathComponent(name), encoding: .utf8) }
func check(_ ok: Bool, _ what: String) { print(ok ? "OK \(what)" : "FAIL \(what)"); if !ok { exit(1) } }

write(v1, "qi_data_version.txt", "1"); write(v1, "custom_phrase.txt", "phrase v1"); write(v1, "rime_ice.dict.yaml", "dict v1")
write(v2, "qi_data_version.txt", "2"); write(v2, "custom_phrase.txt", "phrase v2"); write(v2, "rime_ice.dict.yaml", "dict v2")
write(user, "rime_ice.custom.yaml", "# C2: 旧版一炁的调整")
write(user, "squirrel.custom.yaml", "patch: {}")

check(Rime.install(from: v1, to: user), "first install")
check(read("custom_phrase.txt") == "phrase v1" && read("rime_ice.dict.yaml") == "dict v1", "files installed")
check(read("rime_ice.custom.yaml") == nil, "legacy custom file removed")
check(read("squirrel.custom.yaml") == "patch: {}", "user's own custom file kept")
check(!Rime.install(from: v1, to: user), "same version skipped")

write(user, "custom_phrase.txt", "my phrases")
check(Rime.install(from: v2, to: user), "upgrade")
check(read("custom_phrase.txt") == "my phrases", "user-edited file kept on upgrade")
check(read("rime_ice.dict.yaml") == "dict v2", "untouched file updated")

write(v1, "qi_data_version.txt", "3")
check(Rime.install(from: v1, to: user), "second upgrade")
check(read("custom_phrase.txt") == "my phrases", "user-edited file still kept")
try? fm.removeItem(at: root)
