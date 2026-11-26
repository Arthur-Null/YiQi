import Combine
import SwiftUI
import UIKit

final class AppModel: ObservableObject {
    @Published var scheme: QiScheme = QiStore.scheme
    @Published var status: QiSyncStatus = .unpaired
    @Published var pairCode: String? = QiStore.pairCode
    @Published var message: String?
    @Published var serverInput = ""
    @Published var codeInput = ""
    @Published var busy = false
    @Published var inviteCode: String?
    @Published var inviteDeadline = Date()
    @Published var keyboardEnabled = false
    @Published var update: QiUpdater.Release?
    @Published var updateMessage: String?
    @Published var betaUpdates = QiStore.betaUpdates {
        didSet { QiStore.betaUpdates = betaUpdates; checkUpdate(manual: true) }
    }
    // 按键震动强度：选中后立即按该档震一下，让用户感受手感
    @Published var hapticLevel = QiStore.hapticLevel {
        didSet {
            QiStore.hapticLevel = hapticLevel
            hapticPreview.setLevel(hapticLevel)
            hapticPreview.tick()
        }
    }
    private let hapticPreview = QiHaptic()

    let sync = QiClipboardSync()

    init() {
        QiStore.prepareRimeData()
        refreshKeyboardEnabled()
        sync.onStatus = { [weak self] s in self?.status = s }
        sync.configure(pairCode.flatMap(QiKey.init(pairCode:)))
        checkUpdate()
    }

    var serverHost: String? { pairCode.flatMap(QiKey.init(pairCode:))?.server.host }

    func onBecomeActive() {
        refreshKeyboardEnabled()
        scheme = QiStore.scheme
        sync.reconnectNow()
        sync.syncLocalPasteboardIfNeeded()
    }

    func refreshKeyboardEnabled() {
        let modes = UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String] ?? []
        keyboardEnabled = modes.contains(QiStore.keyboardBundleID)
    }

    func choose(_ s: QiScheme) {
        QiStore.requestScheme(s)
        scheme = s
    }

    private func save(_ k: QiKey) {
        QiStore.pairCode = k.pairCode
        pairCode = QiStore.pairCode
        codeInput = ""
        message = nil
        busy = false
        sync.configure(k)
    }

    private func finish(_ r: Result<QiKey, QiPairing.Failure>) {
        busy = false
        switch r {
        case .success(let k): save(k)
        case .failure(let e): message = e.message
        }
    }

    func join() {
        busy = true
        message = "正在加入…"
        QiPairing.join(server: serverInput, code: codeInput) { self.finish($0) }
    }

    func register() {
        busy = true
        message = "正在注册…"
        QiPairing.register(server: serverInput, code: codeInput) { self.finish($0) }
    }

    func startInvite() {
        guard let code = sync.startInvite() else {
            message = "需要先连上服务器才能添加设备。"
            return
        }
        inviteCode = code
        inviteDeadline = Date().addingTimeInterval(300)
        message = nil
    }

    func stopInvite() {
        sync.stopInvite()
        inviteCode = nil
    }

    func leave() {
        stopInvite()
        QiStore.pairCode = nil
        pairCode = nil
        sync.configure(nil)
    }

    func checkUpdate(manual: Bool = false) {
        if manual { updateMessage = "正在检查…" }
        QiUpdater.check(includeBeta: QiStore.betaUpdates) { [weak self] r, ok in
            self?.update = r
            if manual || self?.updateMessage == "正在检查…" {
                self?.updateMessage = r != nil ? nil : (ok ? "已是最新版本" : "暂时无法检查更新，请稍后再试")
            }
        }
    }
}

@main
struct YiQiApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { model.onBecomeActive() }
                }
        }
    }
}
