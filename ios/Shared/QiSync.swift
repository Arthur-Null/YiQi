import CryptoKit
import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

// C5: 与 sync/protocol、macOS、Android 完全一致的加密与认证协议：AES-GCM 加密后才离开设备。
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

    init(server: URL, raw: Data) {
        self.server = server
        self.raw = raw
    }

    init(server: URL) {
        self.server = server
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        raw = Data(bytes)
    }

    var pairCode: String {
        var c = URLComponents()
        c.scheme = "qi"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "s", value: server.absoluteString),
            URLQueryItem(name: "k", value: raw.base64URL),
        ]
        return c.string!
    }

    var verifier: String { Data(SHA256.hash(data: Data(authToken.utf8))).base64URL }

    private func derive(_ label: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: raw)))
    }

    var authToken: String { derive("qi-auth-v1").base64URL }
    private var encKey: SymmetricKey { SymmetricKey(data: derive("qi-enc-v1")) }

    func seal(_ clip: QiClip) throws -> String {
        let plain = try JSONEncoder().encode(clip)
        return try AES.GCM.seal(plain, using: encKey).combined!.base64EncodedString()
    }

    // C9: 词库快照：压缩后加密，附加认证数据 "dict" 与剪贴板内容区分
    func sealDict(_ text: Data) throws -> String {
        let box = try AES.GCM.seal(try QiGzip.compress(text), using: encKey, authenticating: Data("dict".utf8))
        return box.combined!.base64EncodedString()
    }

    func openDict(_ d: String) throws -> Data {
        guard let raw = Data(base64Encoded: d) else { throw CocoaError(.coderReadCorrupt) }
        let zipped = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: encKey, authenticating: Data("dict".utf8))
        return try QiGzip.decompress(zipped)
    }

    func open(_ d: String) throws -> QiClip {
        guard let raw = Data(base64Encoded: d) else { throw CocoaError(.coderReadCorrupt) }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: raw), using: encKey)
        return try JSONDecoder().decode(QiClip.self, from: plain)
    }
}

struct QiClip: Codable, Equatable {
    var id: String
    var from: String
    var ts: Int64
    var text: String
}

private struct QiFrame: Codable {
    var t: String
    var d: String?
    var j: String?
    var f: String?
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum QiSyncStatus: Equatable {
    case unpaired, connecting, connected, offline, invalid

    var label: String {
        switch self {
        case .unpaired: return "未配对"
        case .connecting: return "连接中…"
        case .connected: return "已连接"
        case .offline: return "暂时连不上服务器，稍后自动重试"
        case .invalid: return "这台设备已不在同步组中，请重新加入"
        }
    }
}

// C3, C4, C5: iOS 端剪贴板同步（主程序与键盘扩展共用）；收到内容写入系统剪贴板并回调候选栏展示。
final class QiClipboardSync: NSObject, URLSessionWebSocketDelegate {
    private(set) var status: QiSyncStatus = .unpaired {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    var onStatus: ((QiSyncStatus) -> Void)?
    var onIncomingClip: ((QiClip) -> Void)?

    private var key: QiKey?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var retry: TimeInterval = 1
    private var generation = 0
    private let deviceID: String
    private var lastText: String?
    private var lastTS: Int64 = 0
    private var lastPasteboardChangeCount: Int = -1
    private var pending: QiClip?
    private var pingTimer: Timer?
    private(set) var inviteCode: String?
    // C9: 用户词库同步；为空表示不同步词库
    var dict: QiDictSync?

    init(deviceID: String = QiStore.deviceID) {
        self.deviceID = deviceID
        if let cached = QiStore.latestClip {
            self.lastText = cached.text
            self.lastTS = cached.ts
        }
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            self?.task?.sendPing { err in
                if err != nil { DispatchQueue.main.async { self?.drop() } }
            }
        }
    }

    deinit {
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
    }

    func configure(_ key: QiKey?) {
        self.key = key
        reconnectNow()
    }

    func reconnectNow() {
        retry = 1
        connect()
    }

    func disconnect() {
        dict?.disconnected()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
        dict?.disconnected()
        guard key != nil else { return }
        if (task?.response as? HTTPURLResponse)?.statusCode == 401 {
            status = .invalid
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            generation += 1
            return
        }
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
        dict?.connected { [weak self] text in self?.sendDict(text) }
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
                    if let data, let f = try? JSONDecoder().decode(QiFrame.self, from: data) {
                        if f.t == "clip", let d = f.d, let clip = try? self.key?.open(d) {
                            self.apply(clip)
                        } else if f.t == "dict", let d = f.d, let from = f.f, from != self.deviceID,
                                  let text = try? self.key?.openDict(d) {
                            self.dict?.receive(from: from, text: text)
                        } else if f.t == "join", let d = f.d, let j = f.j {
                            self.answerJoin(d, j)
                        }
                    }
                    self.receive(t, gen)
                }
            }
        }
    }

    private func apply(_ clip: QiClip) {
        guard clip.from != deviceID, clip.ts > lastTS else { return }
        lastTS = clip.ts
        lastText = clip.text
        QiStore.latestClip = CachedClip(text: clip.text, ts: clip.ts, fromRemote: true)
        #if canImport(UIKit)
        UIPasteboard.general.string = clip.text
        lastPasteboardChangeCount = UIPasteboard.general.changeCount
        #endif
        onIncomingClip?(clip)
    }

    // C3: 键盘或主程序打开时检查 iOS 剪贴板是否有新复制的文本并推送到同组其他设备。
    func syncLocalPasteboardIfNeeded() {
        #if canImport(UIKit)
        guard key != nil else { return }
        let pb = UIPasteboard.general
        guard pb.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pb.changeCount
        guard pb.hasStrings, let s = pb.string, !s.isEmpty else { return }
        onLocalCopy(s)
        #endif
    }

    func onLocalCopy(_ text: String) {
        guard key != nil, !text.isEmpty, text != lastText else { return }
        lastText = text
        lastTS = Int64(Date().timeIntervalSince1970 * 1000)
        QiStore.latestClip = CachedClip(text: text, ts: lastTS, fromRemote: false)
        send(QiClip(id: UUID().uuidString, from: deviceID, ts: lastTS, text: text))
    }

    func startInvite() -> String? {
        guard task != nil, status == .connected else { return nil }
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        inviteCode = code
        sendFrame(QiFrame(t: "invite"))
        return code
    }

    func stopInvite() {
        guard inviteCode != nil else { return }
        inviteCode = nil
        sendFrame(QiFrame(t: "invite-end"))
    }

    private func answerJoin(_ peer: String, _ id: String) {
        guard let key, let code = inviteCode,
              let reply = try? QiPairing.sealGroupKey(peer: peer, code: code, key: key) else { return }
        sendFrame(QiFrame(t: "join-ok", d: reply, j: id))
    }

    private func sendDict(_ text: Data) {
        guard let key, let t = task, status == .connected, let d = try? key.sealDict(text),
              let body = try? JSONEncoder().encode(QiFrame(t: "dict", d: d, f: deviceID)),
              let s = String(data: body, encoding: .utf8)
        else { return }
        t.send(.string(s)) { _ in }
    }

    private func sendFrame(_ f: QiFrame) {
        guard let t = task, let body = try? JSONEncoder().encode(f),
              let s = String(data: body, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    private func send(_ clip: QiClip) {
        guard let key, let t = task, status == .connected,
              let d = try? key.seal(clip),
              let body = try? JSONEncoder().encode(QiFrame(t: "clip", d: d)),
              let s = String(data: body, encoding: .utf8)
        else { pending = clip; return }
        t.send(.string(s)) { [weak self] err in
            if err != nil { DispatchQueue.main.async { self?.pending = clip; self?.drop() } }
        }
    }
}

// C5, C7: 注册同步组与新设备加入（与服务器和其他四端使用同一 P-256 ECDH + 6 位临时密码协议）。
enum QiPairing {
    enum Failure: Error, Equatable {
        case wrongCode, alreadyRegistered, noInvite, tooManyAttempts, badServer, network(String)

        var message: String {
            switch self {
            case .wrongCode: return "临时密码不对或已过期，请核对后重试。"
            case .alreadyRegistered: return "这台服务器已经注册过同步组。请在已同步的设备上点「添加设备」，用它给出的 6 位临时密码加入。"
            case .noInvite: return "没有找到等待加入的邀请。请先在已同步的设备上点「添加设备」，并保持那个窗口打开。"
            case .tooManyAttempts: return "尝试次数过多，请在已同步的设备上重新点「添加设备」获取新的临时密码。"
            case .badServer: return "服务器地址不对，请填写例如 yiqi.example.com。"
            case .network(let s): return "连不上服务器（\(s)），请检查地址和网络。"
            }
        }
    }

    // C7: 服务器地址由用户自行配置。
    static func serverURL(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("https://") { t = "wss://" + t.dropFirst(8) }
        if t.hasPrefix("http://") { t = "ws://" + t.dropFirst(7) }
        if !t.hasPrefix("wss://") && !t.hasPrefix("ws://") { t = "wss://" + t }
        guard var c = URLComponents(string: t), c.host?.isEmpty == false else { return nil }
        if c.path.isEmpty || c.path == "/" { c.path = "/v1/ws" }
        return c.url
    }

    private static func endpoint(_ server: URL, _ path: String) -> URL {
        var c = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "ws" ? "http" : "https"
        c.path = path
        return c.url!
    }

    private static func post(_ url: URL, _ body: [String: String], _ done: @escaping (Int?, Data?, String?) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async { done((resp as? HTTPURLResponse)?.statusCode, data, err?.localizedDescription) }
        }.resume()
    }

    static func register(server: String, code: String, done: @escaping (Result<QiKey, Failure>) -> Void) {
        guard let url = serverURL(server) else { done(.failure(.badServer)); return }
        let k = QiKey(server: url)
        post(endpoint(url, "/v1/claim"), ["code": code.filter(\.isNumber), "v": k.verifier]) { status, _, err in
            switch status {
            case 200: done(.success(k))
            case 403: done(.failure(.wrongCode))
            case 409: done(.failure(.alreadyRegistered))
            default: done(.failure(.network(err ?? "HTTP \(status ?? 0)")))
            }
        }
    }

    static func join(server: String, code: String, done: @escaping (Result<QiKey, Failure>) -> Void) {
        guard let url = serverURL(server) else { done(.failure(.badServer)); return }
        let priv = P256.KeyAgreement.PrivateKey()
        let digits = code.filter(\.isNumber)
        post(endpoint(url, "/v1/join"), ["t": "join", "d": priv.publicKey.x963Representation.base64EncodedString()]) { status, data, err in
            switch status {
            case 200:
                guard let data, let f = try? JSONDecoder().decode(QiFrame.self, from: data), let reply = f.d,
                      let raw = try? openGroupKey(priv: priv, reply: reply, code: digits)
                else { done(.failure(.wrongCode)); return }
                done(.success(QiKey(server: url, raw: raw)))
            case 404: done(.failure(.noInvite))
            case 429: done(.failure(.tooManyAttempts))
            default: done(.failure(.network(err ?? "HTTP \(status ?? 0)")))
            }
        }
    }

    private static func joinKey(_ shared: SharedSecret, _ code: String) -> SymmetricKey {
        let raw = shared.withUnsafeBytes { Data($0) }
        return SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("yiqi-join-v1|\(code)".utf8),
                                                                       using: SymmetricKey(data: raw))))
    }

    static func sealGroupKey(peer: String, code: String, key: QiKey) throws -> String {
        guard let pd = Data(base64Encoded: peer) else { throw CocoaError(.coderReadCorrupt) }
        let peerKey = try P256.KeyAgreement.PublicKey(x963Representation: pd)
        let priv = P256.KeyAgreement.PrivateKey()
        let k = joinKey(try priv.sharedSecretFromKeyAgreement(with: peerKey), code)
        let sealed = try AES.GCM.seal(key.raw, using: k).combined!
        return priv.publicKey.x963Representation.base64EncodedString() + "." + sealed.base64EncodedString()
    }

    static func openGroupKey(priv: P256.KeyAgreement.PrivateKey, reply: String, code: String) throws -> Data {
        let parts = reply.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pa = Data(base64Encoded: parts[0]), let e = Data(base64Encoded: parts[1])
        else { throw CocoaError(.coderReadCorrupt) }
        let k = joinKey(try priv.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: pa)), code)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: e), using: k)
        guard raw.count == 32 else { throw CocoaError(.coderReadCorrupt) }
        return raw
    }
}
