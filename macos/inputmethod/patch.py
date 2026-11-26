#!/usr/bin/env python3
# C6: 在鼠须管 1.1.2 源码上做出「一炁输入法」：改名、去掉自带更新，下拉菜单提供设置入口与输入方式切换（C2）。
import pathlib
import sys

S = pathlib.Path(sys.argv[1]) / "sources"


def patch(rel, old, new, count=1):
    p = S / rel
    s = p.read_text()
    if s.count(old) != count:
        sys.exit(f"patch failed: {rel}: {old[:70]!r}")
    p.write_text(s.replace(old, new))


def cut(rel, start, end):
    p = S / rel
    s = p.read_text()
    i = s.index(start)
    j = s.index(end, i)
    p.write_text(s[:i] + s[j:])


d = "SquirrelApplicationDelegate.swift"
patch(d, "import Sparkle\n", "")
patch(d, "NSApplicationDelegate, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate",
      "NSApplicationDelegate, UNUserNotificationCenterDelegate")
patch(d, "  let updateController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)\n", "")
cut(d, "  var supportsGentleScheduledUpdateReminders: Bool {", "  func userNotificationCenter(")
patch(d, "      updateController.updater.checkForUpdates()\n    }\n\n    completionHandler()",
      "    }\n\n    completionHandler()")
cut(d, "    if updateController.updater.canCheckForUpdates {", "  func openWiki() {")
patch(d, "  func checkForUpdates() {\n  func openWiki() {", "  func checkForUpdates() {}\n\n  func openWiki() {")
patch(d, 'NSLocalizedString("Squirrel", comment: "")', '"一炁输入法"')
patch(d, 'squirrelTraits.setCString("Squirrel", to: \\.distribution_code_name)',
      'squirrelTraits.setCString("YiQi", to: \\.distribution_code_name)')
patch(d, 'squirrelTraits.setCString("鼠鬚管", to: \\.distribution_name)',
      'squirrelTraits.setCString("一炁输入法", to: \\.distribution_name)')
for name in ["SquirrelReloadNotification", "SquirrelSyncNotification"]:
    patch(d, f'"{name}"', f'"{name.replace("Squirrel", "YiQi")}"')

m = "Main.swift"
patch(m, '"/Library/Input Library/Squirrel.app"', '"/Library/Input Methods/YiQiInput.app"')
patch(m, '"rime.squirrel", directoryHint', '"rime.yiqi", directoryHint')
for name in ["SquirrelReloadNotification", "SquirrelSyncNotification"]:
    patch(m, f'"{name}"', f'"{name.replace("Squirrel", "YiQi")}"')

i = "InputSource.swift"
patch(i, '    case hans = "im.rime.inputmethod.Squirrel.Hans"\n    case hant = "im.rime.inputmethod.Squirrel.Hant"\n',
      '    case hans = "im.yiqi.inputmethod.YiQi.Hans"\n')

# C2: 系统输入法下拉菜单：一炁设置、有新版本时的提示、输入方式与中英切换
c = "SquirrelInputController.swift"
p = S / c
s = p.read_text()
a = s.index("  override func menu() -> NSMenu! {")
b = s.index("  @objc func deploy() {")
s = s[:a] + '''  override func menu() -> NSMenu! {
    let menu = NSMenu()
    let settings = NSMenuItem(title: "一炁输入法设置…", action: #selector(qiOpenSettings), keyEquivalent: "")
    settings.target = self
    menu.addItem(settings)
    if let v = try? String(contentsOf: Self.qiSupportDir.appending(component: "update-available.txt"), encoding: .utf8),
       !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let update = NSMenuItem(title: "有新版本 \\(v.trimmingCharacters(in: .whitespacesAndNewlines))，点此更新…",
                              action: #selector(qiOpenSettings), keyEquivalent: "")
      update.target = self
      menu.addItem(update)
    }
    let check = NSMenuItem(title: "检查更新…", action: #selector(qiOpenSettings), keyEquivalent: "")
    check.target = self
    menu.addItem(check)
    menu.addItem(.separator())
    let flypy = qiCurrentScheme() == "rime_frost_double_pinyin_flypy"
    let scheme = NSMenuItem(title: "切换至\\(flypy ? "全拼" : "小鹤双拼")（\\(qiHotkeyLabel())）",
                            action: #selector(qiSwitchScheme), keyEquivalent: "")
    scheme.target = self
    menu.addItem(scheme)
    let ascii = session != 0 && rimeAPI.get_option(session, "ascii_mode")
    let lang = NSMenuItem(title: ascii ? "切换至中文输入" : "切换至英文输入", action: #selector(qiToggleAscii), keyEquivalent: "")
    lang.target = self
    menu.addItem(lang)
    return menu
  }

  static let qiSupportDir = FileManager.default.homeDirectoryForCurrentUser
    .appending(components: "Library", "Application Support", "YiQi")

  func qiCurrentScheme() -> String {
    let f = SquirrelApp.userDir.appending(component: "qi_schema.txt")
    if let s = try? String(contentsOf: f, encoding: .utf8), let id = s.split(separator: " ").first {
      return String(id)
    }
    return schemaId
  }

  func qiHotkeyLabel() -> String {
    let f = SquirrelApp.userDir.appending(component: "qi_hotkey.txt")
    if let s = try? String(contentsOf: f, encoding: .utf8), let l = s.split(separator: "\\n").first, !l.isEmpty {
      return String(l)
    }
    return "Ctrl + Shift + 1"
  }

  @objc func qiSwitchScheme() {
    let target = qiCurrentScheme() == "rime_frost_double_pinyin_flypy" ? "rime_frost" : "rime_frost_double_pinyin_flypy"
    let f = SquirrelApp.userDir.appending(component: "qi_schema.txt")
    try? "\\(target) menu-\\(Int(Date().timeIntervalSince1970 * 1000))\\n".write(to: f, atomically: true, encoding: .utf8)
    if session != 0 {
      let input = rimeAPI.get_input(session).map { String(cString: $0) } ?? ""
      _ = rimeAPI.select_schema(session, target)
      if !input.isEmpty { _ = rimeAPI.set_input(session, input) }
      rimeUpdate()
    }
  }

  @objc func qiToggleAscii() {
    guard session != 0 else { return }
    rimeAPI.set_option(session, "ascii_mode", !rimeAPI.get_option(session, "ascii_mode"))
    rimeUpdate()
  }

  @objc func qiOpenSettings() {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "im.yiqi.app").isEmpty {
      DistributedNotificationCenter.default().postNotificationName(
        .init("im.yiqi.app.openSettings"), object: nil, userInfo: nil, deliverImmediately: true)
    } else {
      let cfg = NSWorkspace.OpenConfiguration()
      cfg.arguments = ["--settings"]
      NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/YiQi.app"), configuration: cfg)
    }
  }

''' + s[b:]
p.write_text(s)

# C2: 候选框右侧的「双拼 / 全拼」切换按钮（横排时显示）：细分隔线 + 淡色圆角底，点一下切换
v = "SquirrelView.swift"
patch(v, "  var candidateRanges: [NSRange] = []\n",
      "  var candidateRanges: [NSRange] = []\n  var qiButtonRange: NSRange?\n")
patch(v, "    var ranges = candidateRanges\n    if preeditRange.length > 0 {",
      "    var ranges = candidateRanges\n    if let qi = qiButtonRange { ranges.append(qi) }\n    if preeditRange.length > 0 {")
patch(v, '''    if let color = theme.highlightedBackColor, let path = highlightedPath {
      let layer = shapeFromPath(path: path)''', '''    if let qi = qiButtonRange,
       let qiPath = drawPath(highlightedRange: qi, backgroundRect: backgroundRect, preeditRect: preeditRect,
                             containingRect: containingRect, extraExpansion: 0) {
      let full = qiPath.boundingBox
      let inset = full.insetBy(dx: full.height * 0.08, dy: full.height * 0.16)
      let chip = shapeFromPath(path: CGPath(roundedRect: inset, cornerWidth: inset.height * 0.3, cornerHeight: inset.height * 0.3, transform: nil))
      chip.fillColor = (theme.labelAttrs[.foregroundColor] as? NSColor ?? .secondaryLabelColor).withAlphaComponent(0.14).cgColor
      panelLayer.addSublayer(chip)
      let box = full
      let line = CGMutablePath()
      let x = box.minX - separatorWidth / 2
      line.move(to: CGPoint(x: x, y: box.minY + box.height * 0.22))
      line.addLine(to: CGPoint(x: x, y: box.maxY - box.height * 0.22))
      let sep = CAShapeLayer()
      sep.path = line
      sep.lineWidth = 1
      sep.strokeColor = (theme.labelAttrs[.foregroundColor] as? NSColor ?? .separatorColor).withAlphaComponent(0.35).cgColor
      panelLayer.addSublayer(sep)
    }
    if let color = theme.highlightedBackColor, let path = highlightedPath {
      let layer = shapeFromPath(path: path)''')
patch(v, '''          if index >= preeditRange.location && index < preeditRange.upperBound {
            preeditIndex = index
          } else {''', '''          if let qi = qiButtonRange, index >= qi.location && index < qi.upperBound {
            candidateIndex = -2
          } else if index >= preeditRange.location && index < preeditRange.upperBound {
            preeditIndex = index
          } else {''')

p = "SquirrelPanel.swift"
patch(p, '''    // text done!
    view.textView.textContentStorage?.attributedString = text''', '''    view.qiButtonRange = nil
    if linear && !vertical && !candidates.isEmpty {
      let style = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil)
      let flypy = inputController?.qiCurrentScheme() == "rime_frost_double_pinyin_flypy"
      let gap = NSMutableAttributedString(string: "    ", attributes: theme.attrs)
      let button = NSMutableAttributedString(string: "\\u{2006}\\(flypy ? "双拼" : "全拼")\\u{2006}", attributes: theme.labelAttrs)
      if let style {
        gap.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: gap.length))
        button.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: button.length))
      }
      button.addAttribute(.noBreak, value: true, range: NSRange(location: 0, length: button.length))
      text.append(gap)
      view.qiButtonRange = NSRange(location: text.length, length: button.length)
      text.append(button)
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text''')
patch(p, '''      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }''', '''      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
      if index == -2 && qiPressed {
        inputController?.qiSwitchScheme()
      }
      qiPressed = false''')
patch(p, '''      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:''', '''      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
      qiPressed = index == -2
    case .leftMouseUp:''')
patch(p, "  var inputController: SquirrelInputController?\n",
      "  var inputController: SquirrelInputController?\n  var qiPressed = false\n")
