import AppKit
import Foundation

enum Updater {
    struct Release: Equatable {
        var version: String
        var download: URL
    }

    static let releases = URL(string: "https://api.github.com/repos/Arthur-Null/YiQi/releases?per_page=10")!

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func check(includeBeta: Bool, _ done: @escaping (Release?, Bool) -> Void) {
        var req = URLRequest(url: releases)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var found: Release?
            var ok = false
            if let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                ok = true
                for r in list where (r["draft"] as? Bool) != true && (includeBeta || (r["prerelease"] as? Bool) != true) {
                    guard let tag = r["tag_name"] as? String, let assets = r["assets"] as? [[String: Any]],
                          let pkg = assets.first(where: { ($0["name"] as? String) == "YiQi-macOS.pkg" }),
                          let s = pkg["browser_download_url"] as? String, let url = URL(string: s) else { continue }
                    let v = String(tag.drop(while: { $0 == "v" }))
                    if found == nil || isNewer(v, than: found!.version) { found = Release(version: v, download: url) }
                }
            }
            DispatchQueue.main.async { done(found.flatMap { isNewer($0.version, than: current) ? $0 : nil }, ok) }
        }.resume()
    }

    static func install(_ r: Release, _ done: @escaping (String?) -> Void) {
        URLSession.shared.downloadTask(with: r.download) { tmp, resp, err in
            DispatchQueue.main.async {
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    done("下载失败\(err.map { "：\($0.localizedDescription)" } ?? "")，请稍后重试。")
                    return
                }
                let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("YiQi-\(r.version).pkg")
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    NSWorkspace.shared.open(dest)
                    done(nil)
                } catch {
                    done("保存安装包失败：\(error.localizedDescription)")
                }
            }
        }.resume()
    }
}
