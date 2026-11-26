import UIKit

// C1, C2, C3: iOS 键盘扩展主控制器：连接 librime 雾凇词库、小鹤/全拼切换与跨设备剪贴板同步。
final class KeyboardViewController: UIInputViewController {
    private let topBar = KeyboardTopBar()
    private let keyboardView = KeyboardView()
    private let engine = QiRimeEngine.shared
    private let sync = QiClipboardSync()
    private lazy var dictSync = QiDictSync { [weak self] in self?.engine.syncUserData() ?? false }

    private var currentSnapshot = QiRimeSnapshot(
        committed: "", preedit: "", candidates: [], highlightedIndex: 0,
        isComposing: false, schema: .flypy, asciiMode: false
    )
    private var clipSuggestion: String?
    private var dismissedClipTS: Int64 = 0
    private var latestClipText: String?
    private var refreshScheduled = false
    private var pasteboardTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 系统给键盘扩展的底层是半透明材质：铺一层不透明底色把它完全盖住，候选栏和按键区都不再透出毛玻璃。
        view.backgroundColor = KeyboardTheme.background
        view.isOpaque = true
        let backing = UIView()
        backing.backgroundColor = KeyboardTheme.background
        backing.isUserInteractionEnabled = false
        backing.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backing, at: 0)
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: view.topAnchor),
            backing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [topBar, keyboardView])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        wireCallbacks()
        engine.startIfNeeded()
        currentSnapshot = engine.snapshot()
        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        engine.startIfNeeded()
        engine.syncSchemaFromStore()
        keyboardView.setHapticLevel(QiStore.hapticLevel)
        currentSnapshot = engine.snapshot()

        // C3: 键盘弹出时连接中转同步剪贴板；若刚收到其他设备复制的文本，立即在候选栏展示并写入系统剪贴板。
        if hasFullAccess {
            sync.onIncomingClip = { [weak self] clip in
                self?.clipSuggestion = clip.text
                self?.latestClipText = clip.text
                self?.refreshUI()
            }
            sync.dict = dictSync
            sync.configure(QiStore.pairCode.flatMap(QiKey.init(pairCode:)))
            sync.syncLocalPasteboardIfNeeded()
            // C3: 键盘开着时在手机上复制（例如在同一个输入框里选中文字点「拷贝」）也要立即发出，
            // 每秒看一次剪贴板变化计数（只读计数，不读内容，不会触发粘贴提示）。
            pasteboardTimer?.invalidate()
            pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.sync.syncLocalPasteboardIfNeeded()
            }
        }
        loadRecentCachedClip()
        refreshUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.gestureRecognizers?.forEach {
            $0.delaysTouchesBegan = false
            $0.delaysTouchesEnded = false
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        sync.disconnect()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshUI()
        }
    }

    // C2: 外接蓝牙/iPad 键盘时同样支持自定义快捷键切换小鹤双拼与全拼。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            let ctrl = key.modifierFlags.contains(.control)
            let alt = key.modifierFlags.contains(.alternate)
            let shift = key.modifierFlags.contains(.shift)
            if matchesConfiguredHotkey(key.charactersIgnoringModifiers, ctrl: ctrl, alt: alt, shift: shift) {
                toggleScheme()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }

    private func matchesConfiguredHotkey(_ ch: String, ctrl: Bool, alt: Bool, shift: Bool) -> Bool {
        var mods: [String] = []
        if ctrl { mods.append("Control") }
        if alt { mods.append("Alt") }
        if shift { mods.append("Shift") }
        let spec = (mods + [ch.lowercased()]).joined(separator: "+")
        return QiStore.hotkey.rime.contains { $0.lowercased() == spec.lowercased() }
    }

    private func wireCallbacks() {
        topBar.onToggleScheme = { [weak self] in self?.toggleScheme() }
        topBar.onSelectCandidate = { [weak self] idx in self?.selectCandidate(idx) }
        topBar.onToggleExpandCandidates = { [weak self] in
            guard let self else { return }
            self.keyboardView.setPage(self.keyboardView.currentPage == .candidates ? .qwerty : .candidates)
            self.refreshUI()
        }
        topBar.onTapClipboardSuggestion = { [weak self] text in
            guard let self else { return }
            self.textDocumentProxy.insertText(text)
            self.clipSuggestion = nil
            self.dismissedClipTS = QiStore.latestClip?.ts ?? Int64(Date().timeIntervalSince1970 * 1000)
            self.refreshUI()
        }
        topBar.onToggleEmoji = { [weak self] in
            guard let self else { return }
            self.keyboardView.setPage(self.keyboardView.currentPage == .emoji ? .qwerty : .emoji)
        }
        topBar.onToggleClipboardPanel = { [weak self] in
            guard let self else { return }
            self.keyboardView.setPage(self.keyboardView.currentPage == .clipboard ? .qwerty : .clipboard)
            self.refreshUI()
        }
        topBar.onDismissKeyboard = { [weak self] in self?.dismissKeyboard() }

        keyboardView.onLetter = { [weak self] letter in self?.handleLetter(letter) }
        keyboardView.onDirectText = { [weak self] text in self?.handleDirectText(text) }
        keyboardView.onBackspace = { [weak self] in self?.handleBackspace() }
        keyboardView.onSpace = { [weak self] in self?.handleSpace() }
        keyboardView.onReturn = { [weak self] in self?.handleReturn() }
        keyboardView.onToggleLang = { [weak self] in
            guard let self else { return }
            self.currentSnapshot = self.engine.toggleAsciiMode()
            self.refreshUI()
        }
        keyboardView.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        // 空格键左右滑动移动光标；正在拼写时不动，避免拼音与光标错位
        keyboardView.onMoveCursor = { [weak self] offset in
            guard let self, !self.currentSnapshot.isComposing else { return }
            self.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        }
        keyboardView.onSelectCandidate = { [weak self] idx in self?.selectCandidate(idx) }
        keyboardView.onRefreshClipboard = { [weak self] in
            guard let self else { return }
            if self.hasFullAccess {
                self.sync.reconnectNow()
                self.sync.syncLocalPasteboardIfNeeded()
            }
            self.loadRecentCachedClip()
            self.refreshUI()
        }
    }

    private func loadRecentCachedClip() {
        latestClipText = QiStore.latestClip?.text
        guard let cached = QiStore.latestClip, !cached.text.isEmpty else { return }
        let ageMs = Int64(Date().timeIntervalSince1970 * 1000) - cached.ts
        if ageMs < 100_000 && cached.ts != dismissedClipTS {
            clipSuggestion = cached.text
        }
    }

    private func toggleScheme() {
        let next = currentSnapshot.schema.toggled
        currentSnapshot = engine.switchScheme(next)
        refreshUI()
    }

    private func handleLetter(_ letter: String) {
        if currentSnapshot.asciiMode {
            textDocumentProxy.insertText(letter)
            return
        }
        guard let scalar = letter.unicodeScalars.first else { return }
        let res = engine.processKey(code: Int32(scalar.value))
        apply(res.snapshot)
        if !res.handled && res.snapshot.committed.isEmpty {
            textDocumentProxy.insertText(letter)
        }
    }

    private func handleDirectText(_ text: String) {
        if currentSnapshot.isComposing {
            let snap = engine.commitComposition()
            apply(snap)
        }
        textDocumentProxy.insertText(text)
    }

    private func handleBackspace() {
        if currentSnapshot.isComposing {
            let res = engine.processKey(code: 0xFF08) // XK_BackSpace
            apply(res.snapshot)
            return
        }
        textDocumentProxy.deleteBackward()
    }

    private func handleSpace() {
        if currentSnapshot.isComposing {
            let res = engine.processKey(code: 0x0020) // XK_space
            apply(res.snapshot)
            return
        }
        textDocumentProxy.insertText(" ")
    }

    private func handleReturn() {
        if currentSnapshot.isComposing {
            let snap = engine.commitComposition()
            apply(snap)
            return
        }
        textDocumentProxy.insertText("\n")
    }

    private func selectCandidate(_ idx: Int) {
        let snap = engine.selectCandidate(at: idx)
        apply(snap)
    }

    private func apply(_ snap: QiRimeSnapshot) {
        if !snap.committed.isEmpty {
            textDocumentProxy.insertText(snap.committed)
        }
        currentSnapshot = snap
        if !snap.isComposing && keyboardView.currentPage == .candidates {
            keyboardView.setPage(.qwerty)
        }
        refreshUI()
    }

    private var returnKeyLabel: String {
        switch textDocumentProxy.returnKeyType {
        case .go: return "前往"
        case .done: return "完成"
        case .next: return "下一步"
        case .search, .google, .yahoo: return "搜索"
        case .send: return "发送"
        default: return "换行"
        }
    }

    private func refreshUI() {
        topBar.update(
            snapshot: currentSnapshot,
            clipSuggestion: clipSuggestion,
            expanded: keyboardView.currentPage == .candidates
        )
        keyboardView.configure(
            asciiMode: currentSnapshot.asciiMode,
            returnLabel: returnKeyLabel,
            showGlobe: needsInputModeSwitchKey,
            candidates: currentSnapshot.candidates,
            latestClip: latestClipText,
            hasFullAccess: hasFullAccess
        )
    }
}
