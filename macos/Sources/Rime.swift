import AppKit
import Carbon
import CryptoKit
import Foundation

enum Scheme: String, CaseIterable {
    case flypy = "double_pinyin_flypy"
    case quanpin = "rime_ice"

    var title: String { self == .flypy ? "小鹤双拼" : "全拼" }
    var short: String { self == .flypy ? "鹤" : "全" }
}

enum Rime {
    static let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Rime")
    static let squirrel = "/Library/Input Methods/Squirrel.app/Contents/MacOS/Squirrel"
    static let sourceID = "im.rime.inputmethod.Squirrel.Hans"
    private static let stateFile = userDir.appendingPathComponent("qi_schema.txt")

    // C2: 读写当前输入方式（与输入法内的 qi_switch.lua 共用 qi_schema.txt）。
    static var scheme: Scheme {
        guard let s = try? String(contentsOf: stateFile, encoding: .utf8),
              let id = s.split(separator: " ").first, let sc = Scheme(rawValue: String(id))
        else { return .flypy }
        return sc
    }

    static func request(_ s: Scheme) {
        let seq = "ui-\(Int(Date().timeIntervalSince1970 * 1000))"
        try? "\(s.rawValue) \(seq)\n".write(to: stateFile, atomically: true, encoding: .utf8)
    }

    private static func sha(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    // C2: 用户可自行修改配置：升级时，用户改过的文件（与上次装入时不同）保留不动。
    static func installData() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("rime-data") else { return }
        if install(from: bundled, to: userDir) { deploy() }
    }

    static func install(from bundled: URL, to userDir: URL) -> Bool {
        let manifestFile = userDir.appendingPathComponent("qi_installed.json")
        let versionFile = userDir.appendingPathComponent("qi_data_version.txt")
        guard let version = try? String(contentsOf: bundled.appendingPathComponent("qi_data_version.txt"), encoding: .utf8)
        else { return false }
        if (try? String(contentsOf: versionFile, encoding: .utf8)) == version { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let old = (try? Data(contentsOf: manifestFile)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        // C2: 旧版曾占用这几个文件名放一炁自己的调整，现在它们留给用户
        for name in ["default.custom.yaml", "double_pinyin_flypy.custom.yaml", "rime_ice.custom.yaml"] {
            let u = userDir.appendingPathComponent(name)
            if let t = try? String(contentsOf: u, encoding: .utf8), t.hasPrefix("# C2:") { try? fm.removeItem(at: u) }
        }
        var manifest: [String: String] = [:]
        let base = bundled.resolvingSymlinksInPath().path
        if let e = fm.enumerator(at: bundled, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let src as URL in e {
                let rel = String(src.resolvingSymlinksInPath().path.dropFirst(base.count + 1))
                let dst = userDir.appendingPathComponent(rel)
                if (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    continue
                }
                let newHash = sha(src)
                if let old, let cur = sha(dst), cur != newHash, cur != old[rel] {
                    manifest[rel] = old[rel]
                    continue
                }
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
                manifest[rel] = newHash
            }
        }
        if let d = try? JSONEncoder().encode(manifest) { try? d.write(to: manifestFile) }
        return true
    }

    static func deploy() {
        guard FileManager.default.isExecutableFile(atPath: squirrel) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: squirrel)
        p.arguments = ["--reload"]
        try? p.run()
    }

    static var squirrelInstalled: Bool { FileManager.default.isExecutableFile(atPath: squirrel) }

    private static func findSource(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    // C1: 以系统的「已启用」列表为准；输入模式自身的启用属性在未添加时也可能显示为真
    static var inputSourceEnabled: Bool {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return false }
        return list.contains { s in
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return false }
            return (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String) == sourceID
        }
    }

    // C1: 登记并尝试启用；新版 macOS 只接受用户在系统设置里添加第三方输入法，此时由设置窗口引导。
    @discardableResult
    static func ensureInputSource(select: Bool) -> Bool {
        guard squirrelInstalled else { return false }
        if findSource(sourceID) == nil {
            TISRegisterInputSource(URL(fileURLWithPath: "/Library/Input Methods/Squirrel.app") as CFURL)
        }
        if !inputSourceEnabled {
            for id in ["im.rime.inputmethod.Squirrel", sourceID] {
                if let s = findSource(id) { TISEnableInputSource(s) }
            }
        }
        let ok = inputSourceEnabled
        if ok && select, let s = findSource(sourceID) { TISSelectInputSource(s) }
        return ok
    }

    static func openInputSourceSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    // C2: 切换快捷键由用户设置，保存为 Rime 按键写法（空格分隔的多种写法），qi_switch.lua 读取。
    private static let hotkeyFile = userDir.appendingPathComponent("qi_hotkey.txt")
    static let defaultHotkey = Hotkey(rime: ["Control+Shift+1", "Control+Shift+exclam"], label: "Ctrl + Shift + 1")

    static var hotkey: Hotkey {
        guard let s = try? String(contentsOf: hotkeyFile, encoding: .utf8) else { return defaultHotkey }
        let lines = s.split(separator: "\n", maxSplits: 1).map(String.init)
        guard lines.count == 2 else { return defaultHotkey }
        return Hotkey(rime: lines[1].split(separator: " ").map(String.init), label: lines[0])
    }

    static func setHotkey(_ h: Hotkey) {
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try? "\(h.label)\n\(h.rime.joined(separator: " "))\n".write(to: hotkeyFile, atomically: true, encoding: .utf8)
    }
}

struct Hotkey: Equatable {
    var rime: [String]
    var label: String

    private static let names: [UInt16: (String, String?)] = [
        0: ("a", nil), 1: ("s", nil), 2: ("d", nil), 3: ("f", nil), 4: ("h", nil), 5: ("g", nil), 6: ("z", nil),
        7: ("x", nil), 8: ("c", nil), 9: ("v", nil), 11: ("b", nil), 12: ("q", nil), 13: ("w", nil), 14: ("e", nil),
        15: ("r", nil), 16: ("y", nil), 17: ("t", nil), 31: ("o", nil), 32: ("u", nil), 34: ("i", nil), 35: ("p", nil),
        37: ("l", nil), 38: ("j", nil), 40: ("k", nil), 45: ("n", nil), 46: ("m", nil),
        18: ("1", "exclam"), 19: ("2", "at"), 20: ("3", "numbersign"), 21: ("4", "dollar"), 23: ("5", "percent"),
        22: ("6", "asciicircum"), 26: ("7", "ampersand"), 28: ("8", "asterisk"), 25: ("9", "parenleft"),
        29: ("0", "parenright"), 27: ("minus", "underscore"), 24: ("equal", "plus"), 33: ("bracketleft", "braceleft"),
        30: ("bracketright", "braceright"), 42: ("backslash", "bar"), 41: ("semicolon", "colon"),
        39: ("apostrophe", "quotedbl"), 43: ("comma", "less"), 47: ("period", "greater"), 44: ("slash", "question"),
        50: ("grave", "asciitilde"), 49: ("space", nil), 48: ("Tab", nil),
        122: ("F1", nil), 120: ("F2", nil), 99: ("F3", nil), 118: ("F4", nil), 96: ("F5", nil), 97: ("F6", nil),
        98: ("F7", nil), 100: ("F8", nil), 101: ("F9", nil), 109: ("F10", nil), 103: ("F11", nil), 111: ("F12", nil),
    ]

    // C2: 由按下的组合键生成快捷键；必须带 Ctrl 或 Option（功能键 F1–F12 除外），以免和打字冲突。
    init?(event: NSEvent) {
        guard let (base, shifted) = Hotkey.names[event.keyCode] else { return nil }
        let f = event.modifierFlags
        let isF = base.hasPrefix("F") && base.count > 1
        guard f.contains(.control) || f.contains(.option) || isF else { return nil }
        var mods: [String] = []
        var label: [String] = []
        if f.contains(.control) { mods.append("Control"); label.append("Ctrl") }
        if f.contains(.option) { mods.append("Alt"); label.append("Option") }
        if f.contains(.shift) { mods.append("Shift"); label.append("Shift") }
        let symbols = ["minus": "-", "equal": "=", "bracketleft": "[", "bracketright": "]", "backslash": "\\",
                       "semicolon": ";", "apostrophe": "'", "comma": ",", "period": ".", "slash": "/", "grave": "`",
                       "space": "Space"]
        label.append(base.count == 1 ? base.uppercased() : (symbols[base] ?? base))
        var rime = [(mods + [base]).joined(separator: "+")]
        if f.contains(.shift), let sh = shifted { rime.append((mods + [sh]).joined(separator: "+")) }
        self.rime = rime
        self.label = label.joined(separator: " + ")
    }

    init(rime: [String], label: String) {
        self.rime = rime
        self.label = label
    }
}
