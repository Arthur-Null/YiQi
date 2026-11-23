import AppKit
import CryptoKit
import Foundation

// C5: 与 sync/protocol 相同的格式：配对密钥派生认证令牌与内容密钥，内容用 AES-GCM 加密后才离开本机。
struct QiKey {
    let server: URL
    let raw: Data

    init?(pairCode: String) {
        guard let c = URLComponents(string: pairCode.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme == "qi", c.host == "pair",
              let s = c.queryItems?.first(where: { $0.name == "s" })?.value, let url = URL(string: s),
              let k = c.queryItems?.first(where: { $0.name == "k" })?.value, let raw = Data(base64URL: k),
              raw.count == 32
        else { return nil }
        server = url
        self.raw = raw
    }

    private func derive(_ label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: raw)))
    }

    var authToken: String { derive("qi-auth-v1").base64URL }
    private var encKey: SymmetricKey { SymmetricKey(data: derive("qi-enc-v1")) }

    func seal(_ clip: Clip) throws -> String {
        let plain = try JSONEncoder().encode(clip)
        return try AES.GCM.seal(plain, using: encKey).combined!.base64EncodedString()
    }

    func open(_ d: String) throws -> Clip {
        guard let raw = Data(base64Encoded: d) else { throw CocoaError(.coderReadCorrupt) }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: encKey)
        return try JSONDecoder().decode(Clip.self, from: plain)
    }
}

struct Clip: Codable {
    var id: String
    var from: String
    var ts: Int64
    var text: String
}

private struct Frame: Codable {
    var t: String
    var d: String
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum SyncStatus: Equatable {
    case unpaired, connecting, connected, offline

    var label: String {
        switch self {
        case .unpaired: return "未配对"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .offline: return "暂时连不上服务器，稍后自动重试"
        }
    }
}

final class Store {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YiQi")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()

    static var pairCode: String? {
        get { try? String(contentsOf: dir.appendingPathComponent("pair.txt"), encoding: .utf8) }
        set {
            let f = dir.appendingPathComponent("pair.txt")
            if let v = newValue {
                FileManager.default.createFile(atPath: f.path, contents: Data(v.utf8),
                                               attributes: [.posixPermissions: 0o600])
            } else {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    static let deviceID: String = {
        let f = dir.appendingPathComponent("device-id")
        if let s = try? String(contentsOf: f, encoding: .utf8), !s.isEmpty { return s }
        let id = UUID().uuidString
        try? id.write(to: f, atomically: true, encoding: .utf8)
        return id
    }()
}

// C3: 同步最新一条文本；收到后写入系统剪贴板，任何应用都能常规粘贴。
final class ClipboardSync: NSObject, URLSessionWebSocketDelegate {
    private(set) var status: SyncStatus = .unpaired { didSet { if status != oldValue { onStatus?(status) } } }
    var onStatus: ((SyncStatus) -> Void)?

    private var key: QiKey?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var retry: TimeInterval = 1
    private var generation = 0

    private let pb: NSPasteboard
    private let deviceID: String
    private var lastChange: Int
    private var lastText: String?
    private var lastTS: Int64 = 0
    private var pending: Clip?
    private var pollTimer: Timer?
    private var pingTimer: Timer?

    init(pasteboard: NSPasteboard = .general, deviceID: String = Store.deviceID) {
        pb = pasteboard
        self.deviceID = deviceID
        lastChange = pasteboard.changeCount
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.task?.sendPing { err in if err != nil { DispatchQueue.main.async { self?.drop() } } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.reconnectNow() }
    }

    func configure(_ key: QiKey?) {
        self.key = key
        reconnectNow()
    }

    func reconnectNow() {
        retry = 1
        connect()
    }

    private func connect() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard let key else { status = .unpaired; return }
        status = .connecting
        var req = URLRequest(url: key.server)
        req.setValue("Bearer \(key.authToken)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 4 << 20
        task = t
        t.resume()
        receive(t, generation)
    }

    private func drop() {
        guard key != nil else { return }
        status = .offline
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + retry) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.connect()
        }
        retry = min(retry * 2, 30)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        status = .connected
        retry = 1
        if let p = pending { pending = nil; send(p) }
    }

    func urlSession(_ session: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        if t === task { drop() }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure:
                    self.drop()
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let f = try? JSONDecoder().decode(Frame.self, from: data), f.t == "clip",
                       let clip = try? self.key?.open(f.d) {
                        self.apply(clip)
                    }
                    self.receive(t, gen)
                }
            }
        }
    }

    private func apply(_ clip: Clip) {
        guard clip.from != deviceID, clip.ts > lastTS else { return }
        lastTS = clip.ts
        lastText = clip.text
        pb.clearContents()
        pb.setString(clip.text, forType: .string)
        lastChange = pb.changeCount
    }

    private func poll() {
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard key != nil, let s = pb.string(forType: .string), !s.isEmpty, s != lastText else { return }
        lastText = s
        lastTS = Int64(Date().timeIntervalSince1970 * 1000)
        send(Clip(id: UUID().uuidString, from: deviceID, ts: lastTS, text: s))
    }

    private func send(_ clip: Clip) {
        guard let key, let t = task, status == .connected,
              let d = try? key.seal(clip),
              let body = try? JSONEncoder().encode(Frame(t: "clip", d: d)),
              let s = String(data: body, encoding: .utf8)
        else { pending = clip; return }
        t.send(.string(s)) { [weak self] err in
            if err != nil { DispatchQueue.main.async { self?.pending = clip; self?.drop() } }
        }
    }
}
