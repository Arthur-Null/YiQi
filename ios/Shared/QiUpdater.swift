import Foundation

enum QiUpdater {
    struct Release: Equatable {
        var version: String
        var download: URL
    }

    static let releases = URL(string: "https://api.github.com/repos/Arthur-Null/YiQi/releases?per_page=10")!

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func parseVersion(_ v: String) -> (core: [Int], pre: [Int]?) {
        var t = v.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        let pre: [Int]? = parts.count > 1 ? parts[1].split(whereSeparator: { $0 == "." || $0 == "-" }).compactMap { Int($0) } : nil
        return (core, pre)
    }

    private static func compare(_ x: [Int], _ y: [Int]) -> Int {
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q ? 1 : -1 }
        }
        return 0
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parseVersion(a), y = parseVersion(b)
        let c = compare(x.core, y.core)
        if c != 0 { return c > 0 }
        guard let xp = x.pre, let yp = y.pre else { return x.pre == nil && y.pre != nil }
        return compare(xp, yp) > 0
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
                    guard let tag = r["tag_name"] as? String,
                          let assets = r["assets"] as? [[String: Any]],
                          let ipa = assets.first(where: { ($0["name"] as? String) == "YiQi-iOS.ipa" }),
                          let s = ipa["browser_download_url"] as? String,
                          let url = URL(string: s) else { continue }
                    let v = String(tag.drop(while: { $0 == "v" }))
                    if found == nil || isNewer(v, than: found!.version) {
                        found = Release(version: v, download: url)
                    }
                }
            }
            DispatchQueue.main.async {
                done(found.flatMap { isNewer($0.version, than: current) ? $0 : nil }, ok)
            }
        }.resume()
    }
}
