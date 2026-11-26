import Foundation

// C2: 小鹤双拼与全拼方案标识，与 qi_switch.lua 和其他端完全一致。
enum QiScheme: String, CaseIterable {
    case flypy = "rime_frost_double_pinyin_flypy"
    case quanpin = "rime_frost"

    var title: String { self == .flypy ? "小鹤双拼" : "全拼" }
    var short: String { self == .flypy ? "小鹤" : "全拼" }
    var toggled: QiScheme { self == .flypy ? .quanpin : .flypy }
}

struct QiHotkey: Equatable {
    var rime: [String]
    var label: String
}

struct CachedClip: Codable, Equatable {
    var text: String
    var ts: Int64
    var fromRemote: Bool
}

// C1, C2, C3, C5: 主程序与键盘扩展通过 App Group 共享同步凭据、输入方式状态与最新剪贴板缓存。
enum QiStore {
    static let appGroupID = "group.im.yiqi.input"
    static let keyboardBundleID = "im.yiqi.input.keyboard"
    static let defaultHotkey = QiHotkey(rime: ["Control+Shift+1", "Control+Shift+exclam"], label: "Ctrl + Shift + 1")

    static var containerDir: URL {
        if let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            try? FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
            return g
        }
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiQi")
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    static var rimeUserDir: URL {
        let d = containerDir.appendingPathComponent("Rime", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var sharedSupportDir: URL? {
        if let u = Bundle.main.url(forResource: "SharedSupport", withExtension: nil) {
            return u
        }
        // Keyboard extension sits in PlugIns/YiQiKeyboard.appex; check containing app bundle too.
        let appBundle = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let cand = appBundle.appendingPathComponent("SharedSupport", isDirectory: true)
        return FileManager.default.fileExists(atPath: cand.path) ? cand : nil
    }

    static var pairCode: String? {
        get {
            let f = containerDir.appendingPathComponent("pair.txt")
            guard let s = try? String(contentsOf: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty else { return nil }
            return s
        }
        set {
            let f = containerDir.appendingPathComponent("pair.txt")
            if let v = newValue, !v.isEmpty {
                FileManager.default.createFile(atPath: f.path, contents: Data(v.utf8),
                                               attributes: [.posixPermissions: 0o600])
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    static var betaUpdates: Bool {
        get { FileManager.default.fileExists(atPath: containerDir.appendingPathComponent("beta-updates").path) }
        set {
            let f = containerDir.appendingPathComponent("beta-updates")
            if newValue { FileManager.default.createFile(atPath: f.path, contents: nil) } else { try? FileManager.default.removeItem(at: f) }
        }
    }

    static var deviceID: String {
        let f = containerDir.appendingPathComponent("device-id")
        if let s = try? String(contentsOf: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty { return s }
        let id = UUID().uuidString
        try? id.write(to: f, atomically: true, encoding: .utf8)
        return id
    }

    // C2: 读写当前输入方式（与 qi_switch.lua 共用 qi_schema.txt）。
    static var scheme: QiScheme {
        let f = rimeUserDir.appendingPathComponent("qi_schema.txt")
        guard let s = try? String(contentsOf: f, encoding: .utf8),
              let id = s.split(separator: " ").first,
              let sc = QiScheme(rawValue: String(id))
        else { return .flypy }
        return sc
    }

    static func requestScheme(_ s: QiScheme) {
        let f = rimeUserDir.appendingPathComponent("qi_schema.txt")
        let line = "\(s.rawValue) ui-\(Int64(Date().timeIntervalSince1970 * 1000))\n"
        try? line.write(to: f, atomically: true, encoding: .utf8)
    }

    static var hotkey: QiHotkey {
        let f = rimeUserDir.appendingPathComponent("qi_hotkey.txt")
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return defaultHotkey }
        let lines = s.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count == 2 else { return defaultHotkey }
        return QiHotkey(rime: lines[1].split(separator: " ").map(String.init), label: lines[0])
    }

    static func setHotkey(_ h: QiHotkey) {
        let f = rimeUserDir.appendingPathComponent("qi_hotkey.txt")
        try? "\(h.label)\n\(h.rime.joined(separator: " "))\n".write(to: f, atomically: true, encoding: .utf8)
    }

    // C3: 共享最新一条同步剪贴板文本，键盘刚打开时立即可在候选栏显示。
    static var latestClip: CachedClip? {
        get {
            let f = containerDir.appendingPathComponent("latest-clip.json")
            guard let d = try? Data(contentsOf: f) else { return nil }
            return try? JSONDecoder().decode(CachedClip.self, from: d)
        }
        set {
            let f = containerDir.appendingPathComponent("latest-clip.json")
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                try? d.write(to: f, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    // C1: 雾凇拼音农历脚本依赖用户目录下的 lua/lunar.db，首次启动补齐。
    static func prepareRimeData() {
        guard let shared = sharedSupportDir else { return }
        let src = shared.appendingPathComponent("lua/lunar.db")
        let dst = rimeUserDir.appendingPathComponent("lua/lunar.db")
        guard FileManager.default.fileExists(atPath: src.path),
              !FileManager.default.fileExists(atPath: dst.path) else { return }
        try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: src, to: dst)
    }
}
