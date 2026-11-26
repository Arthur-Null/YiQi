import UIKit

// C2, C3: 键盘顶部栏：空闲时左侧显示「小鹤 / 全拼」切换按钮、中间显示跨设备同步来的剪贴板气泡、右侧为工具按钮；
// 打字时显示内联拼音与横向滑动候选词，右侧可展开更多候选。
final class KeyboardTopBar: UIView {
    var onToggleScheme: (() -> Void)?
    var onSelectCandidate: ((Int) -> Void)?
    var onToggleExpandCandidates: (() -> Void)?
    var onTapClipboardSuggestion: ((String) -> Void)?
    var onToggleEmoji: (() -> Void)?
    var onToggleClipboardPanel: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?

    private let preeditLabel = UILabel()
    private let barContainer = UIView()

    // 空闲态工具栏
    private let idleStack = UIStackView()
    private let schemeButton = UIButton(type: .system)
    private let clipPill = UIButton(type: .system)
    private let rightTools = UIStackView()

    // 打字态候选栏
    private let candContainer = UIView()
    private let candScroll = UIScrollView()
    private let candStack = UIStackView()
    private let expandButton = UIButton(type: .system)

    private var suggestionText: String?
    private var shownCandidateKey: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        backgroundColor = KeyboardTheme.background

        barContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barContainer)
        let barHeight = barContainer.heightAnchor.constraint(equalToConstant: 52)
        barHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            barContainer.topAnchor.constraint(equalTo: topAnchor),
            barContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            barContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            barContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            barHeight,
        ])

        // 拼音预编辑：显示在候选词上方的一行小字
        preeditLabel.font = .systemFont(ofSize: 13, weight: .medium)
        preeditLabel.textColor = KeyboardTheme.candidateHighlight
        preeditLabel.lineBreakMode = .byTruncatingHead
        preeditLabel.translatesAutoresizingMaskIntoConstraints = false
        candContainer.addSubview(preeditLabel)

        // 空闲态：中间为同步剪贴板圆角卡片，右侧为无底色极简图标（表情 / 剪贴板 / 双全切换 / 收起）
        idleStack.axis = .horizontal
        idleStack.alignment = .center
        idleStack.spacing = 4
        idleStack.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(idleStack)
        NSLayoutConstraint.activate([
            idleStack.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor, constant: 8),
            idleStack.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor, constant: -6),
            idleStack.topAnchor.constraint(equalTo: barContainer.topAnchor),
            idleStack.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
        ])

        // C2: 右侧紧凑的「双 / 全」圆角线框徽标按钮，与安卓端样式一致
        schemeButton.setTitle("双", for: .normal)
        schemeButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        schemeButton.setTitleColor(KeyboardTheme.text, for: .normal)
        schemeButton.backgroundColor = .clear
        schemeButton.layer.cornerRadius = 4.5
        schemeButton.layer.borderWidth = 1.4
        schemeButton.layer.borderColor = KeyboardTheme.text.cgColor
        schemeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            schemeButton.widthAnchor.constraint(equalToConstant: 20),
            schemeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        schemeButton.addTarget(self, action: #selector(tapScheme), for: .touchUpInside)

        // C3: 候选栏剪贴板提示圆角气泡（点一下直接输入全文）
        clipPill.isHidden = true
        var pillConfig = UIButton.Configuration.plain()
        pillConfig.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        pillConfig.image = UIImage(systemName: "doc.on.clipboard")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        pillConfig.imagePadding = 4
        pillConfig.baseForegroundColor = KeyboardTheme.text
        pillConfig.titleLineBreakMode = .byTruncatingTail
        pillConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = .systemFont(ofSize: 13)
            return a
        }
        clipPill.configuration = pillConfig
        clipPill.tintColor = KeyboardTheme.candidateHighlight
        clipPill.backgroundColor = KeyboardTheme.pillBack
        clipPill.layer.cornerRadius = 15
        clipPill.addTarget(self, action: #selector(tapClipPill), for: .touchUpInside)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rightTools.axis = .horizontal
        rightTools.spacing = 4
        rightTools.alignment = .center
        rightTools.setContentHuggingPriority(.required, for: .horizontal)
        rightTools.addArrangedSubview(iconButton("face.smiling", action: #selector(tapEmoji)))
        rightTools.addArrangedSubview(iconButton("doc.on.clipboard", action: #selector(tapClipPanel)))
        rightTools.addArrangedSubview(schemeButton)
        rightTools.addArrangedSubview(iconButton("chevron.down", action: #selector(tapDismiss)))

        idleStack.addArrangedSubview(clipPill)
        idleStack.addArrangedSubview(spacer)
        idleStack.addArrangedSubview(rightTools)

        // 打字态候选栏
        candContainer.isHidden = true
        candContainer.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(candContainer)
        NSLayoutConstraint.activate([
            candContainer.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
            candContainer.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
            candContainer.topAnchor.constraint(equalTo: barContainer.topAnchor),
            candContainer.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
        ])

        candScroll.showsHorizontalScrollIndicator = false
        candScroll.disableEdgeEffects()
        candScroll.translatesAutoresizingMaskIntoConstraints = false
        candStack.axis = .horizontal
        candStack.alignment = .center
        candStack.spacing = 4
        candStack.translatesAutoresizingMaskIntoConstraints = false
        candScroll.addSubview(candStack)

        expandButton.setImage(UIImage(systemName: "chevron.down")?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
        expandButton.tintColor = KeyboardTheme.text
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.addTarget(self, action: #selector(tapExpand), for: .touchUpInside)

        candContainer.addSubview(candScroll)
        candContainer.addSubview(expandButton)
        NSLayoutConstraint.activate([
            preeditLabel.topAnchor.constraint(equalTo: candContainer.topAnchor, constant: 4),
            preeditLabel.leadingAnchor.constraint(equalTo: candContainer.leadingAnchor, constant: 14),
            preeditLabel.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -4),
            preeditLabel.heightAnchor.constraint(equalToConstant: 14),

            candScroll.leadingAnchor.constraint(equalTo: candContainer.leadingAnchor, constant: 6),
            candScroll.topAnchor.constraint(equalTo: preeditLabel.bottomAnchor, constant: 2),
            candScroll.bottomAnchor.constraint(equalTo: candContainer.bottomAnchor),
            candScroll.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -2),

            candStack.leadingAnchor.constraint(equalTo: candScroll.contentLayoutGuide.leadingAnchor),
            candStack.trailingAnchor.constraint(equalTo: candScroll.contentLayoutGuide.trailingAnchor),
            candStack.topAnchor.constraint(equalTo: candScroll.contentLayoutGuide.topAnchor),
            candStack.bottomAnchor.constraint(equalTo: candScroll.contentLayoutGuide.bottomAnchor),
            candStack.heightAnchor.constraint(equalTo: candScroll.frameLayoutGuide.heightAnchor),

            expandButton.trailingAnchor.constraint(equalTo: candContainer.trailingAnchor, constant: -6),
            expandButton.centerYAnchor.constraint(equalTo: candContainer.centerYAnchor),
            expandButton.widthAnchor.constraint(equalToConstant: 40),
            expandButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func iconButton(_ sfName: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: sfName)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        b.tintColor = KeyboardTheme.text
        b.backgroundColor = .clear
        b.layer.cornerRadius = 16
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 32),
            b.heightAnchor.constraint(equalToConstant: 32),
        ])
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    func update(snapshot: QiRimeSnapshot, clipSuggestion: String?, expanded: Bool) {
        schemeButton.setTitle(snapshot.schema == .flypy ? "双" : "全", for: .normal)
        suggestionText = clipSuggestion
        if let s = clipSuggestion, !s.isEmpty {
            let clean = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let preview = clean.count > 24 ? String(clean.prefix(24)) + "…" : clean
            clipPill.setTitle(preview, for: .normal)
            clipPill.isHidden = false
        } else {
            clipPill.isHidden = true
        }

        let composing = snapshot.isComposing
        preeditLabel.text = snapshot.preedit
        idleStack.isHidden = composing
        candContainer.isHidden = !composing

        let iconName = expanded ? "chevron.up" : "chevron.down"
        expandButton.setImage(UIImage(systemName: iconName)?.withConfiguration(
            UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)

        let key = snapshot.candidates.map { "\($0.text)\u{1}\($0.comment)" } + ["#\(snapshot.highlightedIndex)"]
        if key == shownCandidateKey { return }
        shownCandidateKey = key
        candStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, cand) in snapshot.candidates.enumerated() {
            let b = UIButton(type: .system)
            let title = cand.comment.isEmpty ? cand.text : "\(cand.text) \(cand.comment)"
            let highlighted = idx == snapshot.highlightedIndex
            var config = UIButton.Configuration.plain()
            config.title = title
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.baseForegroundColor = highlighted ? KeyboardTheme.candidateHighlight : KeyboardTheme.text
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = .systemFont(ofSize: 19, weight: highlighted ? .medium : .regular)
                return a
            }
            b.configuration = config
            b.tag = idx
            b.addTarget(self, action: #selector(tapCand(_:)), for: .touchUpInside)
            candStack.addArrangedSubview(b)
        }
        candScroll.setContentOffset(.zero, animated: false)
    }

    @objc private func tapScheme() { onToggleScheme?() }
    @objc private func tapClipPill() {
        if let s = suggestionText { onTapClipboardSuggestion?(s) }
    }
    @objc private func tapEmoji() { onToggleEmoji?() }
    @objc private func tapClipPanel() { onToggleClipboardPanel?() }
    @objc private func tapDismiss() { onDismissKeyboard?() }
    @objc private func tapExpand() { onToggleExpandCandidates?() }
    @objc private func tapCand(_ sender: UIButton) { onSelectCandidate?(sender.tag) }
}
