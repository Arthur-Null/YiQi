import UIKit

enum KeyboardPage {
    case qwerty, numbers, symbols, emoji, clipboard, candidates
}

// C6: 微信输入法风格 26 键 / 数字 / 符号 / 表情 / 剪贴板 / 展开候选面板（与安卓一炁主题保持一致）。
final class KeyboardView: UIView {
    var onLetter: ((String) -> Void)?
    var onDirectText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?
    var onToggleLang: (() -> Void)?
    var onNextKeyboard: (() -> Void)?
    var onSelectCandidate: ((Int) -> Void)?
    var onRefreshClipboard: (() -> Void)?
    var onMoveCursor: ((Int) -> Void)?

    private let content = UIView()
    private var page: KeyboardPage = .qwerty
    private enum ShiftState { case off, once, lock }
    private var shiftState: ShiftState = .off
    private var lastShiftTap: TimeInterval = 0
    private var letterLabels: [(ch: String, label: UILabel)] = []
    private weak var shiftButton: KeyButton?
    private var spacePanApplied: CGFloat = 0
    private var asciiMode = false
    private var returnLabel = "换行"
    private var showGlobe = false
    private var candidates: [QiCandidate] = []
    private var latestClip: String?
    private var hasFullAccess = true
    private var repeatTimer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private static let row1: [(String, String)] = [
        ("q", "1"), ("w", "2"), ("e", "3"), ("r", "4"), ("t", "5"),
        ("y", "6"), ("u", "7"), ("i", "8"), ("o", "9"), ("p", "0"),
    ]
    private static let row2: [(String, String)] = [
        ("a", "-"), ("s", "/"), ("d", ":"), ("f", ";"), ("g", "("),
        ("h", ")"), ("j", "~"), ("k", "“"), ("l", "”"),
    ]
    private static let row3: [(String, String)] = [
        ("z", "@"), ("x", "."), ("c", "#"), ("v", "、"), ("b", "?"),
        ("n", "!"), ("m", "…"),
    ]
    private static let emojis: [String] = [
        "😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂",
        "🙂", "🙃", "😉", "😊", "😇", "🥰", "😍", "🤩",
        "😘", "😗", "😋", "😛", "😜", "🤪", "😝", "🤗",
        "🤭", "🤫", "🤔", "🤐", "🤨", "😐", "😑", "😶",
        "😏", "😒", "🙄", "😬", "😌", "😔", "😪", "😴",
        "😷", "🤒", "🤕", "🤢", "🤮", "🥵", "🥶", "😵",
        "🤯", "🤠", "🥳", "😎", "🤓", "🧐", "😕", "😟",
        "🙁", "😮", "😯", "😲", "😳", "🥺", "😦", "😨",
        "😰", "😥", "😢", "😭", "😱", "😖", "😣", "😞",
        "👍", "👎", "👏", "🙌", "🤝", "🙏", "💪", "👌",
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "✨",
        "🎉", "🔥", "💯", "✅", "❌", "⭐", "🌙", "☀️",
    ]
    private static let cnSymbols: [[(String, String)]] = [
        [("，", ","), ("。", "."), ("？", "?"), ("！", "!"), ("、", "、"),
         ("：", ":"), ("；", ";"), ("“", "\""), ("”", "\""), ("…", "…")],
        [("（", "("), ("）", ")"), ("《", "<"), ("》", ">"), ("【", "["),
         ("】", "]"), ("「", "{"), ("」", "}"), ("～", "~"), ("·", "`")],
        [("@", "@"), ("#", "#"), ("%", "%"), ("&", "&"), ("*", "*"),
         ("-", "-"), ("+", "+"), ("=", "="), ("/", "/"), ("￥", "$")],
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardTheme.background
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        let h = heightAnchor.constraint(equalToConstant: 224)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPage(_ p: KeyboardPage) {
        page = p
        rebuild()
    }

    var currentPage: KeyboardPage { page }

    func configure(asciiMode: Bool, returnLabel: String, showGlobe: Bool,
                   candidates: [QiCandidate], latestClip: String?, hasFullAccess: Bool) {
        let needRebuild = self.asciiMode != asciiMode || self.returnLabel != returnLabel ||
            self.showGlobe != showGlobe || (page == .candidates && self.candidates != candidates) ||
            (page == .clipboard && (self.latestClip != latestClip || self.hasFullAccess != hasFullAccess))
        self.asciiMode = asciiMode
        self.returnLabel = returnLabel
        self.showGlobe = showGlobe
        self.candidates = candidates
        self.latestClip = latestClip
        self.hasFullAccess = hasFullAccess
        if needRebuild { rebuild() }
    }

    private func rebuild() {
        letterLabels = []
        content.subviews.forEach { $0.removeFromSuperview() }
        switch page {
        case .qwerty: buildQwerty()
        case .numbers: buildNumbers()
        case .symbols: buildSymbols()
        case .emoji: buildEmoji()
        case .clipboard: buildClipboard()
        case .candidates: buildCandidateGrid()
        }
    }

    private func buildQwerty() {
        let rows = vStack()
        // Row 1
        let r1 = hStack()
        for (ch, hint) in Self.row1 { r1.addArrangedSubview(letterKey(ch, hint: hint)) }
        equalWidths(r1.arrangedSubviews)
        rows.addArrangedSubview(r1)

        // Row 2：左右各留 5% 空白，与微信输入法一致
        let r2 = hStack()
        let lead = UIView(), trail = UIView()
        r2.addArrangedSubview(lead)
        for (ch, hint) in Self.row2 { r2.addArrangedSubview(letterKey(ch, hint: hint)) }
        r2.addArrangedSubview(trail)
        let r2Keys = Array(r2.arrangedSubviews.dropFirst().dropLast())
        equalWidths(r2Keys)
        lead.widthAnchor.constraint(equalTo: r2.widthAnchor, multiplier: 0.05).isActive = true
        trail.widthAnchor.constraint(equalTo: r2.widthAnchor, multiplier: 0.05).isActive = true
        rows.addArrangedSubview(r2)

        // Row 3: Shift + Z..M + Backspace
        let r3 = hStack()
        let shiftBtn = iconFnKey(shiftIconName) { [weak self] in self?.tapShift() }
        shiftButton = shiftBtn
        r3.addArrangedSubview(shiftBtn)
        let mid3 = hStack()
        for (ch, hint) in Self.row3 { mid3.addArrangedSubview(letterKey(ch, hint: hint)) }
        equalWidths(mid3.arrangedSubviews)
        r3.addArrangedSubview(mid3)
        let delBtn = backspaceKey()
        r3.addArrangedSubview(delBtn)
        NSLayoutConstraint.activate([
            shiftBtn.widthAnchor.constraint(equalTo: r3.widthAnchor, multiplier: 0.14),
            delBtn.widthAnchor.constraint(equalTo: r3.widthAnchor, multiplier: 0.14),
        ])
        rows.addArrangedSubview(r3)

        // Row 4: 符, 123, (globe), ，, 空格, 。, 中/英, 发送/换行
        let r4 = hStack()
        let symBtn = textFnKey("符") { [weak self] in self?.setPage(.symbols) }
        let numBtn = textFnKey("123") { [weak self] in self?.setPage(.numbers) }
        let commaBtn = simpleKey(asciiMode ? "," : "，") { [weak self] in
            guard let self else { return }
            self.onDirectText?(self.asciiMode ? "," : "，")
        }
        let spaceBtn = spaceKey("空格") { [weak self] in self?.onSpace?() }
        let periodBtn = simpleKey(asciiMode ? "." : "。") { [weak self] in
            guard let self else { return }
            self.onDirectText?(self.asciiMode ? "." : "。")
        }
        let langBtn = textFnKey(asciiMode ? "英" : "中") { [weak self] in self?.onToggleLang?() }
        let retBtn = accentKey(returnLabel) { [weak self] in self?.onReturn?() }

        r4.addArrangedSubview(symBtn)
        r4.addArrangedSubview(numBtn)
        var globeBtn: KeyButton?
        if showGlobe {
            let g = iconFnKey("globe") { [weak self] in self?.onNextKeyboard?() }
            r4.addArrangedSubview(g)
            globeBtn = g
        }
        r4.addArrangedSubview(commaBtn)
        r4.addArrangedSubview(spaceBtn)
        r4.addArrangedSubview(periodBtn)
        r4.addArrangedSubview(langBtn)
        r4.addArrangedSubview(retBtn)

        NSLayoutConstraint.activate([
            symBtn.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.11),
            numBtn.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.115),
            commaBtn.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.085),
            periodBtn.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.085),
            langBtn.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.09),
            retBtn.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.15),
        ])
        if let g = globeBtn {
            g.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.095).isActive = true
        }
        rows.addArrangedSubview(r4)

        pin(rows, to: content)
        updateLetterLabels()
    }

    // MARK: - Shift（C6：单击为下一个字母大写，快速双击为锁定大写；状态只换图标不换底色，与安卓一致）

    private var shiftIconName: String {
        switch shiftState {
        case .off: return "shift"
        case .once: return "shift.fill"
        case .lock: return "capslock.fill"
        }
    }

    private func tapShift() {
        let now = Date().timeIntervalSinceReferenceDate
        switch shiftState {
        case .off:
            shiftState = .once
        case .once:
            shiftState = (now - lastShiftTap < 0.35) ? .lock : .off
        case .lock:
            shiftState = .off
        }
        lastShiftTap = now
        refreshShiftUI()
    }

    private func refreshShiftUI() {
        shiftButton?.setIcon(shiftIconName)
        updateLetterLabels()
    }

    // 中文态按键帽恒为大写（微信风格）；英文态跟随 Shift。原地更新文字，不重建整个键盘。
    private func updateLetterLabels() {
        let upper = shiftState != .off || !asciiMode
        for (ch, label) in letterLabels { label.text = upper ? ch.uppercased() : ch }
    }

    private func buildNumbers() {
        let rows = vStack()
        let layout: [[(String, Bool)]] = [
            [("+", true), ("1", false), ("2", false), ("3", false), ("⌫", true)],
            [("-", true), ("4", false), ("5", false), ("6", false), (".", true)],
            [("*", true), ("7", false), ("8", false), ("9", false), ("@", true)],
            [("返回", true), (",", false), ("0", false), ("空格", false), (returnLabel, true)],
        ]
        for (ri, row) in layout.enumerated() {
            let h = hStack()
            for (ci, item) in row.enumerated() {
                let btn: KeyButton
                if item.0 == "⌫" {
                    btn = backspaceKey()
                } else if ri == 3 && ci == 4 {
                    btn = accentKey(item.0) { [weak self] in self?.onReturn?() }
                } else if item.0 == "返回" {
                    btn = textFnKey("返回") { [weak self] in self?.setPage(.qwerty) }
                } else if item.0 == "空格" {
                    btn = spaceKey("空格") { [weak self] in self?.onDirectText?(" ") }
                } else if item.1 {
                    btn = textFnKey(item.0) { [weak self] in self?.onDirectText?(item.0) }
                } else {
                    btn = simpleKey(item.0) { [weak self] in self?.onDirectText?(item.0) }
                }
                h.addArrangedSubview(btn)
                let mult: CGFloat = (ci == 0 || ci == 4) ? 0.16 : 0.22
                btn.widthAnchor.constraint(equalTo: h.widthAnchor, multiplier: mult).isActive = true
            }
            rows.addArrangedSubview(h)
        }
        pin(rows, to: content)
    }

    private func buildSymbols() {
        let rows = vStack()
        for line in Self.cnSymbols {
            let h = hStack()
            for (cn, en) in line {
                let s = asciiMode ? en : cn
                h.addArrangedSubview(simpleKey(s) { [weak self] in self?.onDirectText?(s) })
            }
            equalWidths(h.arrangedSubviews)
            rows.addArrangedSubview(h)
        }
        let r4 = hStack()
        let back = textFnKey("返回") { [weak self] in self?.setPage(.qwerty) }
        let num = textFnKey("123") { [weak self] in self?.setPage(.numbers) }
        let sp = spaceKey("空格") { [weak self] in self?.onDirectText?(" ") }
        let del = backspaceKey()
        let ret = accentKey(returnLabel) { [weak self] in self?.onReturn?() }
        r4.addArrangedSubview(back)
        r4.addArrangedSubview(num)
        r4.addArrangedSubview(sp)
        r4.addArrangedSubview(del)
        r4.addArrangedSubview(ret)
        NSLayoutConstraint.activate([
            back.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.15),
            num.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.15),
            del.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.15),
            ret.widthAnchor.constraint(equalTo: r4.widthAnchor, multiplier: 0.15),
        ])
        rows.addArrangedSubview(r4)
        pin(rows, to: content)
    }

    private func buildEmoji() {
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.disableEdgeEffects()
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        let cols = 8
        for i in stride(from: 0, to: Self.emojis.count, by: cols) {
            let r = hStack()
            for j in 0..<cols {
                let idx = i + j
                if idx < Self.emojis.count {
                    let em = Self.emojis[idx]
                    let b = UIButton(type: .system)
                    b.setTitle(em, for: .normal)
                    b.titleLabel?.font = .systemFont(ofSize: 24)
                    b.backgroundColor = .clear
                    b.addAction(UIAction { [weak self] _ in
                        self?.haptic.impactOccurred()
                        self?.onDirectText?(em)
                    }, for: .touchUpInside)
                    r.addArrangedSubview(b)
                } else {
                    r.addArrangedSubview(UIView())
                }
            }
            equalWidths(r.arrangedSubviews)
            r.heightAnchor.constraint(equalToConstant: 38).isActive = true
            grid.addArrangedSubview(r)
        }
        scroll.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            grid.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        let foot = hStack()
        foot.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let back = textFnKey("← 返回") { [weak self] in self?.setPage(.qwerty) }
        let spacer = UIView()
        let del = backspaceKey()
        foot.addArrangedSubview(back)
        foot.addArrangedSubview(spacer)
        foot.addArrangedSubview(del)
        NSLayoutConstraint.activate([
            back.widthAnchor.constraint(equalToConstant: 78),
            del.widthAnchor.constraint(equalToConstant: 64),
        ])

        root.addArrangedSubview(scroll)
        root.addArrangedSubview(foot)
        pin(root, to: content)
    }

    private func buildClipboard() {
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = KeyboardTheme.pillBack
        card.layer.cornerRadius = 10
        let lbl = UILabel()
        lbl.numberOfLines = 5
        lbl.font = .systemFont(ofSize: 14)
        lbl.textColor = KeyboardTheme.text
        lbl.translatesAutoresizingMaskIntoConstraints = false
        if !hasFullAccess {
            lbl.text = "请在系统设置 → 键盘 → 一炁输入法中开启「允许完全访问」，即可同步其他设备复制的文字。"
            lbl.textColor = KeyboardTheme.hint
        } else if let text = latestClip, !text.isEmpty {
            lbl.text = text
        } else {
            lbl.text = "暂无同步剪贴板内容。在其他设备复制文字后，这里会立即显示。"
            lbl.textColor = KeyboardTheme.hint
        }
        card.addSubview(lbl)
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            lbl.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            lbl.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            lbl.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12),
        ])

        let actions = hStack()
        actions.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let back = textFnKey("← 返回") { [weak self] in self?.setPage(.qwerty) }
        let refresh = textFnKey("同步") { [weak self] in self?.onRefreshClipboard?() }
        let paste = accentKey("粘贴全文") { [weak self] in
            guard let self, let t = self.latestClip, !t.isEmpty else { return }
            self.onDirectText?(t)
            self.setPage(.qwerty)
        }
        paste.isEnabled = latestClip?.isEmpty == false
        paste.alpha = paste.isEnabled ? 1.0 : 0.45
        actions.addArrangedSubview(back)
        actions.addArrangedSubview(refresh)
        actions.addArrangedSubview(paste)
        NSLayoutConstraint.activate([
            back.widthAnchor.constraint(equalToConstant: 78),
            refresh.widthAnchor.constraint(equalToConstant: 72),
        ])

        root.addArrangedSubview(card)
        root.addArrangedSubview(actions)
        pin(root, to: content)
    }

    private func buildCandidateGrid() {
        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.disableEdgeEffects()
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        let cols = 4
        for i in stride(from: 0, to: candidates.count, by: cols) {
            let r = hStack()
            for j in 0..<cols {
                let idx = i + j
                if idx < candidates.count {
                    let c = candidates[idx]
                    let b = simpleKey(c.text) { [weak self] in
                        self?.onSelectCandidate?(idx)
                        self?.setPage(.qwerty)
                    }
                    b.titleLabel?.font = .systemFont(ofSize: 17)
                    r.addArrangedSubview(b)
                } else {
                    r.addArrangedSubview(UIView())
                }
            }
            equalWidths(r.arrangedSubviews)
            r.heightAnchor.constraint(equalToConstant: 38).isActive = true
            grid.addArrangedSubview(r)
        }
        scroll.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            grid.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            grid.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        let back = textFnKey("← 返回键盘") { [weak self] in self?.setPage(.qwerty) }
        back.heightAnchor.constraint(equalToConstant: 36).isActive = true

        root.addArrangedSubview(scroll)
        root.addArrangedSubview(back)
        pin(root, to: content)
    }

    // MARK: - Key Builders
    // 每个键的可点击区域占满整个格子（含键间空隙），只有里面的 face 是可见的圆角块，
    // 因此手指落在两键之间时也会落到最近的键上，不会出现点不到或点偏。

    private func letterKey(_ ch: String, hint: String) -> KeyButton {
        let b = KeyButton(normal: KeyboardTheme.keyBack, pressed: KeyboardTheme.keyHighlight)

        let hintLbl = UILabel()
        hintLbl.text = hint
        hintLbl.font = .systemFont(ofSize: 9)
        hintLbl.textColor = KeyboardTheme.hint
        hintLbl.textAlignment = .center
        hintLbl.isUserInteractionEnabled = false
        hintLbl.translatesAutoresizingMaskIntoConstraints = false

        let mainLbl = UILabel()
        mainLbl.text = ch.uppercased()
        mainLbl.font = .systemFont(ofSize: 20, weight: .regular)
        mainLbl.textColor = KeyboardTheme.text
        mainLbl.textAlignment = .center
        mainLbl.isUserInteractionEnabled = false
        mainLbl.translatesAutoresizingMaskIntoConstraints = false

        b.addSubview(hintLbl)
        b.addSubview(mainLbl)
        NSLayoutConstraint.activate([
            hintLbl.topAnchor.constraint(equalTo: b.topAnchor, constant: 7),
            hintLbl.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            mainLbl.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            mainLbl.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -9),
        ])
        letterLabels.append((ch, mainLbl))

        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.tick()
            if self.shiftState != .off {
                // 大写字母不进拼音引擎：先上屏正在输入的拼音，再直接输入大写字母
                self.onDirectText?(ch.uppercased())
                if self.shiftState == .once {
                    self.shiftState = .off
                    self.refreshShiftUI()
                }
            } else {
                self.onLetter?(ch)
            }
        }, for: .touchUpInside)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.4
        b.accessibilityHint = hint
        b.addGestureRecognizer(lp)
        return b
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let hint = gr.view?.accessibilityHint else { return }
        tick()
        onDirectText?(hint)
    }

    private func tick() {
        haptic.impactOccurred()
        haptic.prepare()
    }

    private func simpleKey(_ title: String, action: @escaping () -> Void) -> KeyButton {
        let b = KeyButton(normal: KeyboardTheme.keyBack, pressed: KeyboardTheme.keyHighlight)
        b.setTitle(title, for: .normal)
        b.setTitleColor(KeyboardTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17)
        b.addAction(UIAction { [weak self] _ in self?.tick(); action() }, for: .touchUpInside)
        return b
    }

    // 空格键：轻点输入空格；按住左右滑动移动光标（每滑约 12pt 移动一个字符）。
    private func spaceKey(_ title: String, tap: @escaping () -> Void) -> KeyButton {
        let b = simpleKey(title, action: tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSpacePan(_:)))
        b.addGestureRecognizer(pan)
        return b
    }

    @objc private func handleSpacePan(_ gr: UIPanGestureRecognizer) {
        let step: CGFloat = 12
        switch gr.state {
        case .began:
            spacePanApplied = 0
        case .changed:
            let t = gr.translation(in: gr.view).x
            let n = Int(((t - spacePanApplied) / step).rounded(.towardZero))
            if n != 0 {
                spacePanApplied += CGFloat(n) * step
                onMoveCursor?(n)
            }
        default:
            spacePanApplied = 0
        }
    }

    private func textFnKey(_ title: String, action: @escaping () -> Void) -> KeyButton {
        let b = KeyButton(normal: KeyboardTheme.fnBack, pressed: KeyboardTheme.fnHighlight)
        b.setTitle(title, for: .normal)
        b.setTitleColor(KeyboardTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.addAction(UIAction { [weak self] _ in self?.tick(); action() }, for: .touchUpInside)
        return b
    }

    private func iconFnKey(_ sfName: String, action: @escaping () -> Void) -> KeyButton {
        let b = KeyButton(normal: KeyboardTheme.fnBack, pressed: KeyboardTheme.fnHighlight)
        b.setIcon(sfName)
        b.addAction(UIAction { [weak self] _ in self?.tick(); action() }, for: .touchUpInside)
        return b
    }

    private func accentKey(_ title: String, action: @escaping () -> Void) -> KeyButton {
        let b = KeyButton(normal: KeyboardTheme.accentBack,
                          pressed: KeyboardTheme.accentBack.withAlphaComponent(0.75))
        b.setTitle(title, for: .normal)
        b.setTitleColor(KeyboardTheme.accentText, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.addAction(UIAction { [weak self] _ in self?.tick(); action() }, for: .touchUpInside)
        return b
    }

    // 退格：按下立即删除一次，按住 0.4 秒后连续删除。
    private func backspaceKey() -> KeyButton {
        let b = KeyButton(normal: KeyboardTheme.fnBack, pressed: KeyboardTheme.fnHighlight)
        b.setIcon("delete.left")
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.tick()
            self.onBackspace?()
            self.repeatTimer?.invalidate()
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    self?.onBackspace?()
                }
            }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            self?.repeatTimer?.invalidate()
            self?.repeatTimer = nil
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    private func equalWidths(_ views: [UIView]) {
        guard let first = views.first else { return }
        for v in views.dropFirst() {
            v.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
        }
    }

    private func vStack() -> UIStackView {
        let s = UIStackView()
        s.axis = .vertical
        s.distribution = .fillEqually
        s.spacing = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func hStack() -> UIStackView {
        let s = UIStackView()
        s.axis = .horizontal
        s.distribution = .fill
        s.spacing = 0
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func pin(_ child: UIView, to parent: UIView) {
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

// 键：整个格子都可点击，face 是里面可见的圆角块（按下时变色）。
final class KeyButton: UIButton {
    private let face = UIView()
    private let normalColor: UIColor
    private let pressedColor: UIColor

    init(normal: UIColor, pressed: UIColor) {
        normalColor = normal
        pressedColor = pressed
        super.init(frame: .zero)
        backgroundColor = .clear
        face.isUserInteractionEnabled = false
        face.backgroundColor = normal
        face.layer.cornerRadius = 6
        face.layer.shadowColor = UIColor.black.cgColor
        face.layer.shadowOffset = CGSize(width: 0, height: 1)
        face.layer.shadowOpacity = 0.14
        face.layer.shadowRadius = 0.5
        face.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(face, at: 0)
        NSLayoutConstraint.activate([
            face.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            face.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            face.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            face.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // 图标由键自己的 UIImageView 绘制，不依赖 UIButton 自带的 imageView
    //（后者在盖了一层 face 之后图标会消失）。
    private lazy var iconView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .center
        v.tintColor = KeyboardTheme.text
        v.isUserInteractionEnabled = false
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.centerXAnchor.constraint(equalTo: centerXAnchor),
            v.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        return v
    }()

    func setIcon(_ sfName: String) {
        iconView.image = UIImage(systemName: sfName, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
    }

    override var isHighlighted: Bool {
        didSet { face.backgroundColor = isHighlighted ? pressedColor : normalColor }
    }
}
