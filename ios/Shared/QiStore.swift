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
    static let baseAppGroupID = "group.im.yiqi.input"
    static let defaultHotkey = QiHotkey(rime: ["Control+Shift+1", "Control+Shift+exclam"], label: "Ctrl + Shift + 1")

    // 用户用自己的 Apple ID 通过 AltStore / SideStore 签名安装时，App Group 会被改名（附加账号编号）。
    // 所以不能写死分组名：从这次签名实际拿到的描述文件里读出分组，主程序和键盘才能读到同一份数据。
    // 诊断用：这次运行找到的分组候选与最终使用的位置（主程序和键盘各自显示，便于核对两边是否一致）。
    private(set) static var groupCandidates: [String] = []
    static var storageDiagnostic: String {
        let usingGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
        let found = groupCandidates.isEmpty ? "无" : groupCandidates.joined(separator: ", ")
        return usingGroup ? "共享分组 \(appGroupID)" : "私有目录（候选：\(found)）"
    }

    static let appGroupID: String = {
        var candidates: [String] = []
        defer { groupCandidates = Array(Set(candidates)).sorted() }
        // 键盘扩展自己的包里不一定带这些信息，所以同时看它所在的主程序包。
        let appBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        for bundle in [Bundle.main, Bundle(url: appBundleURL)].compactMap({ $0 }) {
            if let alt = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
                candidates += alt
            }
            candidates += provisionedAppGroups(in: bundle)
        }
        candidates.sort { $0.hasPrefix(baseAppGroupID) && !$1.hasPrefix(baseAppGroupID) }
        candidates.append(baseAppGroupID)
        for g in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g) != nil {
            return g
        }
        return baseAppGroupID
    }()

    private static func provisionedAppGroups(in bundle: Bundle) -> [String] {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }

    // 打包时间（版本号相同时用来确认手机上装的、键盘正在跑的是不是最新包）；本机调试构建为空。
    static var buildStamp: String {
        (Bundle.main.object(forInfoDictionaryKey: "QiBuild") as? String) ?? ""
    }

    // 键盘扩展的实际 bundle id（签名工具可能改过），用于判断用户是否已在系统里添加了一炁键盘。
    static var keyboardBundleID: String {
        let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("YiQiKeyboard.appex")
        return appex.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "im.yiqi.input.keyboard"
    }

    private static var privateDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiQi")
    }

    static let containerDir: URL = {
        guard let g = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            try? FileManager.default.createDirectory(at: privateDir, withIntermediateDirectories: true)
            return privateDir
        }
        try? FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
        // 早先版本找不到共享分组时把配对信息、学到的词存在各自的私有目录里：合并进共享目录，不用重新配对，学过的词也不丢。
        mergeMove(from: privateDir, into: g)
        return g
    }()

    private static func mergeMove(from src: URL, into dst: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
                if isDir.boolValue, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    mergeMove(from: item, into: target)
                }
            } else {
                try? fm.moveItem(at: item, to: target)
            }
        }
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

    // 按键震动强度：0 关、1 轻、2 中、3 强；主 App 设置，键盘弹出时读取。
    static var hapticLevel: Int {
        get {
            let f = containerDir.appendingPathComponent("haptic.txt")
            guard let s = try? String(contentsOf: f, encoding: .utf8),
                  let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 1 }
            return min(max(v, 0), 3)
        }
        set {
            let f = containerDir.appendingPathComponent("haptic.txt")
            try? String(newValue).write(to: f, atomically: true, encoding: .utf8)
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
