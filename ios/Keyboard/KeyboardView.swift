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

    private let content = UIView()
    private var page: KeyboardPage = .qwerty
    private var shifted = false
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
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 228),
        ])
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
        let rows = vStack(spacing: 10)
        // Row 1
        let r1 = hStack(spacing: 6)
        for (ch, hint) in Self.row1 { r1.addArrangedSubview(letterKey(ch, hint: hint)) }
        rows.addArrangedSubview(r1)

        // Row 2 (inset 5% each side)
        let r2Wrap = UIView()
        let r2 = hStack(spacing: 6)
        for (ch, hint) in Self.row2 { r2.addArrangedSubview(letterKey(ch, hint: hint)) }
        r2Wrap.addSubview(r2)
        NSLayoutConstraint.activate([
            r2.topAnchor.constraint(equalTo: r2Wrap.topAnchor),
            r2.bottomAnchor.constraint(equalTo: r2Wrap.bottomAnchor),
            r2.leadingAnchor.constraint(equalTo: r2Wrap.leadingAnchor, constant: 16),
            r2.trailingAnchor.constraint(equalTo: r2Wrap.trailingAnchor, constant: -16),
        ])
        rows.addArrangedSubview(r2Wrap)

        // Row 3: Shift + Z..M + Backspace
        let r3 = hStack(spacing: 6)
        let shiftBtn = iconFnKey(shifted ? "shift.fill" : "shift") { [weak self] in
            self?.shifted.toggle()
            self?.rebuild()
        }
        r3.addArrangedSubview(shiftBtn)
        let mid3 = hStack(spacing: 6)
        for (ch, hint) in Self.row3 { mid3.addArrangedSubview(letterKey(ch, hint: hint)) }
        r3.addArrangedSubview(mid3)
        let delBtn = backspaceKey()
        r3.addArrangedSubview(delBtn)
        NSLayoutConstraint.activate([
            shiftBtn.widthAnchor.constraint(equalTo: r3.widthAnchor, multiplier: 0.135),
            delBtn.widthAnchor.constraint(equalTo: r3.widthAnchor, multiplier: 0.135),
        ])
        rows.addArrangedSubview(r3)

        // Row 4: 符, 123, (globe), ，, 空格, 。, 中/英, 发送/换行
        let r4 = hStack(spacing: 6)
        let symBtn = textFnKey("符") { [weak self] in self?.setPage(.symbols) }
        let numBtn = textFnKey("123") { [weak self] in self?.setPage(.numbers) }
        let commaBtn = simpleKey(asciiMode ? "," : "，") { [weak self] in
            guard let self else { return }
            self.onDirectText?(self.asciiMode ? "," : "，")
        }
        let spaceBtn = simpleKey("空格") { [weak self] in self?.onSpace?() }
        let periodBtn = simpleKey(asciiMode ? "." : "。") { [weak self] in
            guard let self else { return }
            self.onDirectText?(self.asciiMode ? "." : "。")
        }
        let langBtn = textFnKey(asciiMode ? "英" : "中") { [weak self] in self?.onToggleLang?() }
        let retBtn = accentKey(returnLabel) { [weak self] in self?.onReturn?() }

        r4.addArrangedSubview(symBtn)
        r4.addArrangedSubview(numBtn)
        var globeBtn: UIButton?
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
    }

    private func buildNumbers() {
        let rows = vStack(spacing: 8)
        let layout: [[(String, Bool)]] = [
            [("+", true), ("1", false), ("2", false), ("3", false), ("⌫", true)],
            [("-", true), ("4", false), ("5", false), ("6", false), (".", true)],
            [("*", true), ("7", false), ("8", false), ("9", false), ("@", true)],
            [("返回", true), (",", false), ("0", false), ("空格", false), (returnLabel, true)],
        ]
        for (ri, row) in layout.enumerated() {
            let h = hStack(spacing: 5)
            for (ci, item) in row.enumerated() {
                let btn: UIButton
                if item.0 == "⌫" {
                    btn = backspaceKey()
                } else if ri == 3 && ci == 4 {
                    btn = accentKey(item.0) { [weak self] in self?.onReturn?() }
                } else if item.0 == "返回" {
                    btn = textFnKey("返回") { [weak self] in self?.setPage(.qwerty) }
                } else if item.0 == "空格" {
                    btn = simpleKey("空格") { [weak self] in self?.onDirectText?(" ") }
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
        let rows = vStack(spacing: 8)
        for line in Self.cnSymbols {
            let h = hStack(spacing: 5)
            for (cn, en) in line {
                let s = asciiMode ? en : cn
                h.addArrangedSubview(simpleKey(s) { [weak self] in self?.onDirectText?(s) })
            }
            rows.addArrangedSubview(h)
        }
        let r4 = hStack(spacing: 5)
        let back = textFnKey("返回") { [weak self] in self?.setPage(.qwerty) }
        let num = textFnKey("123") { [weak self] in self?.setPage(.numbers) }
        let sp = simpleKey("空格") { [weak self] in self?.onDirectText?(" ") }
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
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        let cols = 8
        for i in stride(from: 0, to: Self.emojis.count, by: cols) {
            let r = hStack(spacing: 2)
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

        let foot = hStack(spacing: 8)
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

        let actions = hStack(spacing: 8)
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
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        let cols = 4
        for i in stride(from: 0, to: candidates.count, by: cols) {
            let r = hStack(spacing: 6)
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

    private func letterKey(_ ch: String, hint: String) -> UIButton {
        let b = UIButton(type: .custom)
        b.backgroundColor = KeyboardTheme.keyBack
        b.layer.cornerRadius = 6

        let hintLbl = UILabel()
        hintLbl.text = hint
        hintLbl.font = .systemFont(ofSize: 9)
        hintLbl.textColor = KeyboardTheme.hint
        hintLbl.textAlignment = .center
        hintLbl.isUserInteractionEnabled = false
        hintLbl.translatesAutoresizingMaskIntoConstraints = false

        let mainLbl = UILabel()
        mainLbl.text = ch.uppercased()
        mainLbl.font = .systemFont(ofSize: 19, weight: .regular)
        mainLbl.textColor = KeyboardTheme.text
        mainLbl.textAlignment = .center
        mainLbl.isUserInteractionEnabled = false
        mainLbl.translatesAutoresizingMaskIntoConstraints = false

        b.addSubview(hintLbl)
        b.addSubview(mainLbl)
        NSLayoutConstraint.activate([
            hintLbl.topAnchor.constraint(equalTo: b.topAnchor, constant: 2),
            hintLbl.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            mainLbl.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            mainLbl.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -5),
        ])

        attachHighlight(b, normal: KeyboardTheme.keyBack, pressed: KeyboardTheme.keyHighlight)
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.haptic.impactOccurred()
            let out = self.shifted ? ch.uppercased() : ch
            self.onLetter?(out)
            if self.shifted {
                self.shifted = false
                self.rebuild()
            }
        }, for: .touchUpInside)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.42
        b.accessibilityHint = hint
        b.addGestureRecognizer(lp)
        applyKeyShadow(b)
        return b
    }

    private func applyKeyShadow(_ b: UIButton) {
        b.layer.shadowColor = UIColor.black.cgColor
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowOpacity = 0.14
        b.layer.shadowRadius = 0.5
        b.layer.masksToBounds = false
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began, let hint = gr.view?.accessibilityHint else { return }
        haptic.impactOccurred()
        onDirectText?(hint)
    }

    private func simpleKey(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.setTitleColor(KeyboardTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 17)
        b.backgroundColor = KeyboardTheme.keyBack
        b.layer.cornerRadius = 6
        attachHighlight(b, normal: KeyboardTheme.keyBack, pressed: KeyboardTheme.keyHighlight)
        b.addAction(UIAction { [weak self] _ in self?.haptic.impactOccurred(); action() }, for: .touchUpInside)
        applyKeyShadow(b)
        return b
    }

    private func textFnKey(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.setTitleColor(KeyboardTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.backgroundColor = KeyboardTheme.fnBack
        b.layer.cornerRadius = 6
        attachHighlight(b, normal: KeyboardTheme.fnBack, pressed: KeyboardTheme.fnHighlight)
        b.addAction(UIAction { [weak self] _ in self?.haptic.impactOccurred(); action() }, for: .touchUpInside)
        applyKeyShadow(b)
        return b
    }

    private func iconFnKey(_ sfName: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: sfName)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        b.tintColor = KeyboardTheme.text
        b.backgroundColor = KeyboardTheme.fnBack
        b.layer.cornerRadius = 6
        attachHighlight(b, normal: KeyboardTheme.fnBack, pressed: KeyboardTheme.fnHighlight)
        b.addAction(UIAction { [weak self] _ in self?.haptic.impactOccurred(); action() }, for: .touchUpInside)
        applyKeyShadow(b)
        return b
    }

    private func accentKey(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .custom)
        b.setTitle(title, for: .normal)
        b.setTitleColor(KeyboardTheme.accentText, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.backgroundColor = KeyboardTheme.accentBack
        b.layer.cornerRadius = 6
        b.addAction(UIAction { [weak self] _ in self?.haptic.impactOccurred(); action() }, for: .touchUpInside)
        applyKeyShadow(b)
        return b
    }

    private func backspaceKey() -> UIButton {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(systemName: "delete.left")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        b.tintColor = KeyboardTheme.text
        b.backgroundColor = KeyboardTheme.fnBack
        b.layer.cornerRadius = 6
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            b.backgroundColor = KeyboardTheme.fnHighlight
            self.haptic.impactOccurred()
            self.onBackspace?()
            self.repeatTimer?.invalidate()
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    self?.onBackspace?()
                }
            }
        }, for: .touchDown)
        let stop = UIAction { [weak self] _ in
            b.backgroundColor = KeyboardTheme.fnBack
            self?.repeatTimer?.invalidate()
            self?.repeatTimer = nil
        }
        b.addAction(stop, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        applyKeyShadow(b)
        return b
    }

    private func attachHighlight(_ b: UIButton, normal: UIColor, pressed: UIColor) {
        b.addAction(UIAction { _ in b.backgroundColor = pressed }, for: .touchDown)
        b.addAction(UIAction { _ in b.backgroundColor = normal }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    private func vStack(spacing: CGFloat) -> UIStackView {
        let s = UIStackView()
        s.axis = .vertical
        s.distribution = .fillEqually
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func hStack(spacing: CGFloat) -> UIStackView {
        let s = UIStackView()
        s.axis = .horizontal
        s.distribution = .fillProportionally
        s.spacing = spacing
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
