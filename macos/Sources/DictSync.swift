import Foundation

// C9: 与 sync/protocol 相同的压缩格式（gzip），Rime 导出的词库快照压缩后才加密发送。
enum Gzip {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func compress(_ d: Data) throws -> Data {
        let raw = try (d as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF])
        out += raw
        for v in [crc32(d), UInt32(truncatingIfNeeded: d.count)] {
            out += withUnsafeBytes(of: v.littleEndian) { Data($0) }
        }
        return out
    }

    static func decompress(_ d: Data) throws -> Data {
        guard d.count > 18, d[d.startIndex] == 0x1F, d[d.startIndex + 1] == 0x8B, d[d.startIndex + 2] == 8,
              d[d.startIndex + 3] == 0
        else { throw CocoaError(.coderReadCorrupt) }
        let body = d.subdata(in: (d.startIndex + 10)..<(d.endIndex - 8))
        return try (body as NSData).decompressed(using: .zlib) as Data
    }
}

// C9: 用户词库跨设备同步。借用 Rime 自带的「同步用户资料」：本机导出快照到 <用户目录>/sync/<本机安装号>/，
// 其他设备的快照放进 <用户目录>/sync/<设备号>/，Rime 同步时合并进本机词库。
final class DictSync {
    static let file = "rime_frost.userdb.txt"

    let userDir: URL
    // 请 Rime 执行一次同步（导出本机快照并合并其他设备的快照）
    let trigger: () -> Void
    var first: TimeInterval = 5
    var debounce: TimeInterval = 20
    var period: TimeInterval = 1800
    var wait: TimeInterval = 40

    private var timer: Timer?
    private var kick: Timer?
    private var sent: Int?
    private var send: ((Data) -> Void)?

    init(userDir: URL = Rime.userDir, trigger: @escaping () -> Void = DictSync.postSync) {
        self.userDir = userDir
        self.trigger = trigger
    }

    static func postSync() {
        DistributedNotificationCenter.default().postNotificationName(
            .init("YiQiSyncNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private var ownSnapshot: URL? {
        guard let s = try? String(contentsOf: userDir.appendingPathComponent("installation.yaml"), encoding: .utf8),
              let line = s.split(separator: "\n").first(where: { $0.hasPrefix("installation_id:") })
        else { return nil }
        let id = line.dropFirst("installation_id:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return id.isEmpty ? nil : userDir.appendingPathComponent("sync/\(id)/\(DictSync.file)")
    }

    private func modTime(_ u: URL?) -> Date? {
        guard let u else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date
    }

    // 只看词条，不看文件头（版本、tick 等），避免只因合并导致头部变化而反复上传
    private func fingerprint(_ d: Data) -> Int {
        var h = Hasher()
        String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }.forEach { h.combine($0) }
        return h.finalize()
    }

    func connected(send: @escaping (Data) -> Void) {
        self.send = send
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in self?.run() }
        schedule(first)
    }

    func disconnected() {
        timer?.invalidate()
        kick?.invalidate()
        send = nil
    }

    private func schedule(_ after: TimeInterval) {
        kick?.invalidate()
        kick = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in self?.run() }
    }

    func receive(from: String, text: Data) {
        guard from.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return }
        let f = userDir.appendingPathComponent("sync/\(from)/\(DictSync.file)")
        if let old = try? Data(contentsOf: f), old == text { return }
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: f, options: .atomic)
        schedule(debounce)
    }

    private func run() {
        let before = modTime(ownSnapshot)
        trigger()
        let deadline = Date().addingTimeInterval(wait)
        func poll() {
            let now = modTime(ownSnapshot)
            if (now != nil && now != before) || Date() > deadline {
                publish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
            }
        }
        poll()
    }

    private func publish() {
        guard let f = ownSnapshot, let text = try? Data(contentsOf: f), !text.isEmpty else { return }
        let fp = fingerprint(text)
        if fp != sent {
            sent = fp
            send?(text)
        }
    }
}
