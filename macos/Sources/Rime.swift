import Carbon
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
    private static let versionFile = userDir.appendingPathComponent("qi_data_version.txt")

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

    static func installData() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("rime-data"),
              let version = try? String(contentsOf: bundled.appendingPathComponent("qi_data_version.txt"), encoding: .utf8)
        else { return }
        if (try? String(contentsOf: versionFile, encoding: .utf8)) == version { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        if let e = fm.enumerator(at: bundled, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let src as URL in e {
                let rel = String(src.path.dropFirst(bundled.path.count + 1))
                let dst = userDir.appendingPathComponent(rel)
                if (try? src.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                } else {
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }
        deploy()
    }

    static func deploy() {
        guard FileManager.default.isExecutableFile(atPath: squirrel) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: squirrel)
        p.arguments = ["--reload"]
        try? p.run()
    }

    static var squirrelInstalled: Bool { FileManager.default.isExecutableFile(atPath: squirrel) }

    static func selectInputSource() {
        let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let src = list.first else { return }
        TISEnableInputSource(src)
        TISSelectInputSource(src)
    }
}
