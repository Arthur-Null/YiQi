#!/usr/bin/env python3
# 在同文输入法源码上接入一炁：雾凇词库、输入方式切换按钮（C2）、剪贴板同步（C3、C4、C5）。
import pathlib
import sys

T = pathlib.Path(sys.argv[1])
VERSION = sys.argv[2]


def patch(rel, old, new, count=1):
    p = T / rel
    s = p.read_text()
    if s.count(old) != count:
        sys.exit(f"patch failed: {rel}: {old[:60]!r}")
    p.write_text(s.replace(old, new))


patch("app/build.gradle.kts", '    id("com.osfans.trime.opencc-data")\n', "")
patch("app/build.gradle.kts", 'applicationId = "com.osfans.trime"', 'applicationId = "im.yiqi.input"')
patch("app/build.gradle.kts", "minSdk = 21", "minSdk = 24")
major, minor, micro = (int(x) for x in VERSION.split("."))
patch("app/build.gradle.kts", "versionCode = 20261101", f"versionCode = {20261101 + major * 10000 + minor * 100 + micro}")
patch("app/build.gradle.kts", 'versionName = "3.3.13"', f'versionName = "{VERSION}"')
patch("app/build.gradle.kts", 'resValue("string", "trime_app_name", "@string/app_name_release")',
      'resValue("string", "trime_app_name", "一炁输入法")')
patch("app/build.gradle.kts", "    implementation(libs.kotlinx.coroutines)\n",
      "    implementation(libs.kotlinx.coroutines)\n"
      '    implementation("com.squareup.okhttp3:okhttp:4.12.0")\n'
      )

# C2: 首次打开只需两步（启用、选用），数据放在应用内部；默认只列出小鹤双拼与全拼
patch("app/src/main/java/com/osfans/trime/data/prefs/AppPrefs.kt",
      "DATA_STORAGE_MODE, DataStorageMode.EXTERNAL_SYNC)", "DATA_STORAGE_MODE, DataStorageMode.APP_STORAGE)")
patch("app/src/main/java/com/osfans/trime/core/data/UserDataManager.kt",
      "          - schema: luna_pinyin\n          - schema: luna_pinyin_simp\n",
      "          - schema: double_pinyin_flypy\n          - schema: rime_ice\n")
patch("app/src/main/java/com/osfans/trime/ui/setup/SetupActivity.kt",
      "        viewPager.isUserInputEnabled = modeSetupDone\n\n        prevButton.isGone = isFirstPage\n",
      "        viewPager.isUserInputEnabled = false\n\n        prevButton.isGone = viewPager.currentItem <= 1\n")
patch("app/src/main/java/com/osfans/trime/ui/setup/SetupPage.kt",
      "            Enable -> R.string.setup__step_two\n            Select -> R.string.setup__step_three\n",
      "            Enable -> R.string.setup__step_one\n            Select -> R.string.setup__step_two\n")

# C3, C5: 剪贴板同步接入
patch("app/src/main/java/com/osfans/trime/TrimeApplication.kt",
      "            ClipboardHelper.init(ctx)\n",
      "            ClipboardHelper.init(ctx)\n            com.osfans.trime.qi.QiSync.init(ctx)\n")
patch("app/src/main/java/com/osfans/trime/data/db/ClipboardHelper.kt",
      "                if (bean.text.isNullOrBlank()) return@withLock\n",
      "                if (bean.text.isNullOrBlank()) return@withLock\n"
      "                com.osfans.trime.qi.QiSync.onLocalCopy(bean.text)\n")
# C3: 手机端候选栏显示同步来的内容：键盘刚出现时也显示近期内容，并留足从电脑转到手机的时间
patch("app/src/main/java/com/osfans/trime/ime/bar/InputBarDelegate.kt",
      "            ClipboardHelper.addOnUpdateListener(onClipboardUpdateListener)\n",
      "            ClipboardHelper.addOnUpdateListener(onClipboardUpdateListener)\n"
      "            ClipboardHelper.lastBean?.let {\n"
      "                if (System.currentTimeMillis() - it.time < clipboardSuggestionTimeout * 1000L) {\n"
      "                    onClipboardUpdateListener.onUpdate(it)\n"
      "                }\n"
      "            }\n")
patch("app/src/main/java/com/osfans/trime/ime/bar/InputBarDelegate.kt",
      "    override fun onStartInput(info: EditorInfo) {\n",
      "    override fun onStartInput(info: EditorInfo) {\n"
      "        com.osfans.trime.qi.QiSync.reconnectNow()\n"
      "        val want = com.osfans.trime.qi.QiSyncActivity.currentScheme()\n"
      "        rime.launchOnReady { api ->\n"
      "            if (api.statusCached.schemaId != want) api.selectSchema(want)\n"
      "        }\n")
# C2: 输入方式切换后立即更新工具栏图标与空格键方案显示，无需等待输入第一个字符
patch("app/src/main/java/com/osfans/trime/ime/bar/InputBarDelegate.kt",
      "    override fun onRimeOptionUpdated(value: RimeMessage.OptionMessage.Data) {\n",
      "    override fun onRimeSchemaUpdated(schema: com.osfans.trime.core.SchemaItem) {\n"
      "        alwaysUi.updateButtonsStyle(\"qi_flypy\", schema.id == com.osfans.trime.qi.QiSyncActivity.FLYPY)\n"
      "        syncToolbarOptionStates()\n"
      "    }\n\n"
      "    override fun onRimeOptionUpdated(value: RimeMessage.OptionMessage.Data) {\n")
patch("app/src/main/java/com/osfans/trime/ime/keyboard/CommonKeyboardActionListener.kt",
      "            private fun handleSwitchCharset(action: KeyAction) {\n"
      "                val option = action.toggle.ifEmpty { return }\n",
      "            private fun handleSwitchCharset(action: KeyAction) {\n"
      "                val option = action.toggle.ifEmpty { return }\n"
      "                if (option == \"qi_flypy\") {\n"
      "                    rime.launchOnReady { api ->\n"
      "                        val target = if (api.statusCached.schemaId == com.osfans.trime.qi.QiSyncActivity.FLYPY) {\n"
      "                            com.osfans.trime.qi.QiSyncActivity.QUANPIN\n"
      "                        } else {\n"
      "                            com.osfans.trime.qi.QiSyncActivity.FLYPY\n"
      "                        }\n"
      "                        val raw = if (api.statusCached.isComposing) api.getRawInput() else \"\"\n"
      "                        com.osfans.trime.qi.QiSyncActivity.requestScheme(target)\n"
      "                        api.selectSchema(target)\n"
      "                        if (raw.isNotEmpty()) api.simulateKeySequence(raw)\n"
      "                    }\n"
      "                    return\n"
      "                }\n")
patch("app/src/main/java/com/osfans/trime/ime/keyboard/KeyboardWindow.kt",
      "    override fun onRimeSchemaUpdated(schema: SchemaItem) {\n"
      "        switchKeyboard(\".default\")\n"
      "    }\n",
      "    override fun onRimeSchemaUpdated(schema: SchemaItem) {\n"
      "        switchKeyboard(\".default\")\n"
      "        ContextCompat.getMainExecutor(service).execute {\n"
      "            cachedKeyboards.values.forEach { (_, v) -> v.invalidateAllKeys() }\n"
      "        }\n"
      "    }\n")
# C2: 工具栏按钮支持 badge@ 圆角线框徽标，并统一图标按钮内边距（含候选栏展开箭头）
patch("app/src/main/java/com/osfans/trime/ime/bar/ui/ToolButton.kt",
      "        image.padding = dp(4)\n",
      "        image.padding = dp(9)\n")
patch("app/src/main/java/com/osfans/trime/ime/bar/ui/ToolButton.kt",
      "        } else if (style.startsWith(\"ic@\")) {\n",
      "        } else if (style.startsWith(\"badge@\")) {\n"
      "            com.osfans.trime.qi.QiBadgeDrawable(context, style.substring(6))\n"
      "        } else if (style.startsWith(\"ic@\")) {\n")
# C3: 候选栏剪贴板提示改为微信输入法风格圆角气泡卡片
patch("app/src/main/java/com/osfans/trime/ime/bar/ui/ClipboardSuggestionUi.kt",
      "            val spacing = dp(4)\n",
      "            val spacing = dp(8)\n"
      "            setPadding(dp(4), 0, dp(4), 0)\n")
patch("app/src/main/java/com/osfans/trime/ime/bar/ui/ClipboardSuggestionUi.kt",
      "            imageDrawable =\n"
      "                drawable(R.drawable.ic_clipboard_24)!!.apply {\n"
      "                    setTint(scope.colors.candidateTextColor)\n"
      "                }\n",
      "            imageDrawable =\n"
      "                drawable(R.drawable.ic_clipboard_24)!!.apply {\n"
      "                    setTint(scope.color(\"accent_back\"))\n"
      "                }\n")
patch("app/src/main/java/com/osfans/trime/ime/bar/ui/ClipboardSuggestionUi.kt",
      "        background = rippleDrawable(scope.colors.hilitedCandidateBackColor)\n",
      "        background = android.graphics.drawable.GradientDrawable().apply {\n"
      "            setColor(scope.color(\"text_back_color\"))\n"
      "            cornerRadius = ctx.dp(16).toFloat()\n"
      "        }\n")
patch("app/src/main/java/com/osfans/trime/ime/bar/ui/ClipboardSuggestionUi.kt",
      "        icon.imageDrawable?.setTint(scope.colors.candidateTextColor)\n"
      "        text.setTextColor(scope.colors.candidateTextColor)\n"
      "        dismiss.imageDrawable?.setTint(scope.colors.candidateTextColor)\n"
      "        suggestionView.background =\n"
      "            rippleDrawable(scope.colors.hilitedCandidateBackColor)\n",
      "        icon.imageDrawable?.setTint(scope.color(\"accent_back\"))\n"
      "        text.setTextColor(scope.colors.candidateTextColor)\n"
      "        dismiss.imageDrawable?.setTint(scope.color(\"comment_text_color\"))\n"
      "        suggestionView.background = android.graphics.drawable.GradientDrawable().apply {\n"
      "            setColor(scope.color(\"text_back_color\"))\n"
      "            cornerRadius = ctx.dp(16).toFloat()\n"
      "        }\n")
# C6: 浅色/深色按键增加轻微 1dp 底部立体阴影，贴近微信输入法与原生键盘质感
patch("app/src/main/java/com/osfans/trime/ime/keyboard/KeyView.kt",
      "        bg.setBounds(\n"
      "            paddingLeft,\n"
      "            paddingTop,\n"
      "            width - paddingRight,\n"
      "            height - paddingBottom,\n"
      "        )\n"
      "        bg.draw(canvas)\n",
      "        if (!keyPressed) {\n"
      "            val sh = GradientDrawable().apply {\n"
      "                setColor(0x22000000)\n"
      "                k.roundCorner.takeIf { it > 0f }?.let { cornerRadius = dp(it) }\n"
      "            }\n"
      "            val dy = dp(1)\n"
      "            sh.setBounds(paddingLeft, paddingTop + dy, width - paddingRight, height - paddingBottom + dy)\n"
      "            sh.draw(canvas)\n"
      "        }\n"
      "        bg.setBounds(\n"
      "            paddingLeft,\n"
      "            paddingTop,\n"
      "            width - paddingRight,\n"
      "            height - paddingBottom,\n"
      "        )\n"
      "        bg.draw(canvas)\n")
# C6: 修复按键字符不居中：无上方长按提示的按键不做垂直下移，全角标点与符号按字形墨迹边界精确居中
patch("app/src/main/java/com/osfans/trime/ime/keyboard/KeyView.kt",
      "        if (label.isIconFont) {\n"
      "            drawIcon(canvas, label, textSize.toInt(), textColor, key.keyTextOffsetX, key.keyTextOffsetY)\n"
      "        } else {\n"
      "            textPaint.apply {\n"
      "                color = textColor\n"
      "                this.textSize = textSize\n"
      "                typeface = theme.fonts.key\n"
      "                clearShadowLayer()\n"
      "            }\n\n"
      "            val centerX = (width - paddingLeft - paddingRight) / 2f + paddingLeft\n"
      "            val centerY = (height - paddingTop - paddingBottom) / 2f + paddingTop\n"
      "            val fontMetrics = textPaint.fontMetrics\n"
      "            val adjustmentY = -(fontMetrics.ascent + fontMetrics.descent) / 2f\n\n"
      "            canvas.drawText(label, centerX + sp(key.keyTextOffsetX), centerY + adjustmentY + sp(key.keyTextOffsetY), textPaint)\n"
      "        }\n",
      "        val hasTopSymbol = key.symbolLabel.isNotEmpty() && !keyboardView.hideKeySymbol\n"
      "        val offsetY = if (hasTopSymbol) key.keyTextOffsetY else 0f\n"
      "        if (label.isIconFont) {\n"
      "            drawIcon(canvas, label, textSize.toInt(), textColor, key.keyTextOffsetX, offsetY)\n"
      "        } else {\n"
      "            textPaint.apply {\n"
      "                color = textColor\n"
      "                this.textSize = textSize\n"
      "                typeface = theme.fonts.key\n"
      "                clearShadowLayer()\n"
      "            }\n\n"
      "            val centerX = (width - paddingLeft - paddingRight) / 2f + paddingLeft\n"
      "            val centerY = (height - paddingTop - paddingBottom) / 2f + paddingTop\n"
      "            if (label.length == 1 && !label[0].isLetterOrDigit()) {\n"
      "                val ink = Rect()\n"
      "                textPaint.textAlign = Paint.Align.LEFT\n"
      "                textPaint.getTextBounds(label, 0, label.length, ink)\n"
      "                canvas.drawText(\n"
      "                    label,\n"
      "                    centerX - ink.exactCenterX() + sp(key.keyTextOffsetX),\n"
      "                    centerY - ink.exactCenterY() + sp(offsetY),\n"
      "                    textPaint,\n"
      "                )\n"
      "                textPaint.textAlign = Paint.Align.CENTER\n"
      "            } else {\n"
      "                val fontMetrics = textPaint.fontMetrics\n"
      "                val adjustmentY = -(fontMetrics.ascent + fontMetrics.descent) / 2f\n"
      "                canvas.drawText(label, centerX + sp(key.keyTextOffsetX), centerY + adjustmentY + sp(offsetY), textPaint)\n"
      "            }\n"
      "        }\n")
patch("app/src/main/java/com/osfans/trime/ime/keyboard/KeyView.kt",
      "            for (i in lines.indices) {\n"
      "                val lineY = startY + lineHeight * i\n"
      "                canvas.drawText(lines[i], centerX, lineY, symbolPaint)\n"
      "            }\n",
      "            for (i in lines.indices) {\n"
      "                val line = lines[i]\n"
      "                val lineY = startY + lineHeight * i\n"
      "                if (line.length == 1 && !line[0].isLetterOrDigit()) {\n"
      "                    val ink = Rect()\n"
      "                    symbolPaint.textAlign = Paint.Align.LEFT\n"
      "                    symbolPaint.getTextBounds(line, 0, line.length, ink)\n"
      "                    canvas.drawText(line, centerX - ink.exactCenterX(), lineY, symbolPaint)\n"
      "                    symbolPaint.textAlign = Paint.Align.CENTER\n"
      "                } else {\n"
      "                    canvas.drawText(line, centerX, lineY, symbolPaint)\n"
      "                }\n"
      "            }\n")
patch("app/src/main/java/com/osfans/trime/data/prefs/AppPrefs.kt",
      "            CLIPBOARD_SUGGESTION_TIMEOUT,\n            20,\n",
      "            CLIPBOARD_SUGGESTION_TIMEOUT,\n            100,\n")
# C1: 减少安卓端误触：提高长按触发阈值避免打字误出长按符号，并扩展边缘空白处热区
patch("app/src/main/java/com/osfans/trime/data/prefs/AppPrefs.kt",
      "        val expandKeypressArea = switch(R.string.expand_keypress_area_to_edge, EXPAND_KEYPRESS_AREA, false)\n",
      "        val expandKeypressArea = switch(R.string.expand_keypress_area_to_edge, EXPAND_KEYPRESS_AREA, true)\n")
patch("app/src/main/java/com/osfans/trime/data/prefs/AppPrefs.kt",
      "            LONG_PRESS_TIMEOUT,\n            300,\n",
      "            LONG_PRESS_TIMEOUT,\n            420,\n")

# C4: 经公网服务器中转需要联网；在线更新需要安装新版的权限
patch("app/src/main/AndroidManifest.xml",
      "    <application\n",
      '    <uses-permission android:name="android.permission.INTERNET" />\n'
      '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />\n\n    <application\n')

# C2, C3: 设置入口
patch("app/src/main/AndroidManifest.xml",
      '        <activity\n            android:name=".ui.setup.SetupActivity"',
      '        <activity\n            android:name=".qi.QiSyncActivity"\n            android:exported="false" />\n\n'
      '        <activity\n            android:name=".ui.setup.SetupActivity"')
patch("app/src/main/java/com/osfans/trime/ui/main/MainFragment.kt",
      "        preferenceScreen = preferenceManager.createPreferenceScreen(requireContext()).apply {\n",
      "        preferenceScreen = preferenceManager.createPreferenceScreen(requireContext()).apply {\n"
      '            addPreference(\n'
      '                title = "输入方式与剪贴板同步",\n'
      '                summary = "小鹤双拼 / 全拼切换；剪贴板同步；检查更新",\n'
      '                icon = R.drawable.ic_clipboard_24,\n'
      '            ) {\n'
      '                startActivity(android.content.Intent(requireContext(), com.osfans.trime.qi.QiSyncActivity::class.java))\n'
      '            }\n')

# C2: 设置首页只保留普通用户需要的条目，去掉 Rime / 同文底层技术项（含顶部部署与开发者菜单）
for indent, route, title, icon in [
    ("            ", "SchemaList", "schemata", "ic_round_view_list_24"),
    ("            ", "UserDict", "user_dictionary", "ic_baseline_book_24"),
    ("            ", "Profile", "profile", "ic_baseline_snippet_folder_24"),
    ("                ", "General", "general", "ic_baseline_tune_24"),
    ("                ", "CandidatesWindow", "candidates_window", "ic_baseline_list_alt_24"),
    ("                ", "Theme", "theme", "ic_baseline_color_lens_24"),
    ("                ", "Advanced", "advanced", "ic_baseline_more_horiz_24"),
]:
    patch("app/src/main/java/com/osfans/trime/ui/main/MainFragment.kt",
          f"{indent}addDestinationPreference(\n{indent}    R.string.{title},\n{indent}    R.drawable.{icon},\n"
          f"{indent}    NavigationRoute.{route},\n{indent})\n", "")
patch("app/src/main/java/com/osfans/trime/ui/main/MainActivity.kt",
      "        val optionMenuItems = listOf(\n"
      "            menu.item(R.string.deploy, R.drawable.ic_baseline_refresh_reversed_24, showAsAction = true) {\n"
      "                viewModel.rime.launchOnReady { it.deploy() }\n"
      "            },\n"
      "            menu.item(R.string.test_input, R.drawable.ic_baseline_keyboard_24, showAsAction = true) {\n"
      "                testInputPanel?.show(window)\n"
      "            },\n"
      "            menu.item(R.string.developer) {\n"
      "                navController.navigate(NavigationRoute.Developer)\n"
      "            },\n"
      "            menu.item(R.string.about) {\n"
      "                navController.navigate(NavigationRoute.About)\n"
      "            },\n"
      "        )\n",
      "        val optionMenuItems = listOf(\n"
      "            menu.item(R.string.test_input, R.drawable.ic_baseline_keyboard_24, showAsAction = true) {\n"
      "                testInputPanel?.show(window)\n"
      "            },\n"
      "        )\n")

KB = "app/src/main/java/com/osfans/trime/ime/keyboard/"
patch(KB + "Keyboard.kt", "    fun resetShift() {\n",
      "    private var lastShiftTap = 0L\n\n"
      "    fun clickShift() {\n"
      "        val now = android.os.SystemClock.elapsedRealtime()\n"
      "        val key = mShiftKey\n"
      "        val shifted = modifier.hasFlag(KeyEvent.META_SHIFT_ON)\n"
      "        when {\n"
      "            key?.isOn == true -> {\n"
      "                key.setOn(false)\n"
      "                setModifier(KeyEvent.META_SHIFT_ON, false)\n"
      "            }\n"
      "            shifted && now - lastShiftTap < 400 -> key?.setOn(true)\n"
      "            shifted -> setModifier(KeyEvent.META_SHIFT_ON, false)\n"
      "            else -> setModifier(KeyEvent.META_SHIFT_ON, true)\n"
      "        }\n"
      "        lastShiftTap = now\n"
      "    }\n\n"
      "    fun resetShift() {\n")
patch(KB + "KeyView.kt",
      "        if (action.isModifierKey) {\n            keyboard.clickModifierKey(\n",
      "        if (action.isModifierKey && key.isShift) {\n"
      "            keyboard.clickShift()\n"
      "            keyboardView.invalidateAllKeys()\n"
      "            return\n"
      "        }\n\n"
      "        if (action.isModifierKey) {\n            keyboard.clickModifierKey(\n")
patch(KB + "Key.kt", "    fun getLabel(): String = when {\n",
      "    fun getLabel(): String = when {\n"
      '        isShift -> when {\n'
      '            isOn -> "ic@qi_shift_lock"\n'
      '            parent.modifier.hasFlag(KeyEvent.META_SHIFT_ON) -> "ic@qi_shift_on"\n'
      '            else -> "ic@qi_shift"\n'
      '        }\n\n')
patch(KB + "KeyView.kt",
      "        val halfSize = size / 2\n\n        val cmdName = iconName.toIconName()\n",
      "        val halfSize = size / 2\n\n"
      "        val qiName = iconName.removePrefix(\"ic@\")\n"
      "        if (com.osfans.trime.qi.QiIcons.has(qiName)) {\n"
      "            val qx = (width - paddingLeft - paddingRight) / 2f + paddingLeft + sp(offsetX)\n"
      "            val qy = when (isTop) {\n"
      "                true -> paddingTop + halfSize + sp(offsetY)\n"
      "                false -> height - paddingBottom - size + sp(offsetY)\n"
      "                null -> (height - paddingTop - paddingBottom) / 2f + paddingTop + sp(offsetY)\n"
      "            }\n"
      "            com.osfans.trime.qi.QiIcons.draw(canvas, qiName, qx, qy, size * 0.95f, color)\n"
      "            return\n"
      "        }\n\n"
      "        val cmdName = iconName.toIconName()\n")
patch(KB + "KeyView.kt",
      "        isSlideCursor = key.click?.isSlideCursor ?: false\n",
      "        isSlideCursor = key.click?.let {\n"
      "            it.isSlideCursor || (!it.isModifierKey && !it.isRepeatable && !it.isSlideDelete)\n"
      "        } ?: false\n")

# C2: 一炁主题：简洁的键盘外观（浅色 / 深色跟随系统），左上角「小鹤 / 全拼」按钮
ROOT = pathlib.Path(__file__).resolve().parent
base = (T / "app/src/main/assets/shared/trime.yaml").read_text()


def section(name, until):
    a = base.index(f"\n{name}:\n") + 1
    b = base.index(f"\n{until}:\n", a) + 1
    return base[a:b]


keys = section("preset_keys", "preset_keyboards").replace("preset_keys:\n", """preset_keys:
  Qi_scheme: {toggle: qi_flypy, send: SWITCH_CHARSET, states: [ 全拼, 小鹤 ]}
  Qi_lang: {toggle: ascii_mode, send: SWITCH_CHARSET, states: [ 中, 英 ]}
  Qi_symbols: {label: 符, send: Eisu_toggle, select: symbols}
  Qi_number: {label: '123', send: Eisu_toggle, select: number}
  Qi_back: {label: 返回, send: Eisu_toggle, select: .default}
  Qi_shift: {label: 'ic@qi_shift', send: Shift_L}
  Qi_backspace: {label: 'ic@qi_backspace', repeatable: true, send: BackSpace}
  Qi_space: {label: 空格, functional: false, send: space}
  Qi_emoji: {label: 表情, send: FUNCTION, command: liquid_keyboard, option: "表情"}
  Qi_lq_exit: {label: '←', send: FUNCTION, command: liquid_keyboard, option: "-1"}
""", 1)
liquid = section("liquid_keyboard", "android_keys")
liquid = (ROOT / "theme/yiqi.liquid.yaml").read_text() + liquid[liquid.index("\n  tabs:\n") + 1:]
liquid = liquid.replace("  emoji:\n    type: SINGLE\n", "  emoji:\n    type: SINGLE\n    name: 表情\n", 1)
liquid = liquid.replace("    name: 全emoji\n", "    name: 全部表情\n", 1)
theme = ((ROOT / "theme/yiqi.head.yaml").read_text() + "\n"
         + liquid + section("android_keys", "preset_keys") + keys + "\n"
         + (ROOT / "theme/yiqi.tail.yaml").read_text())
(T / "app/src/main/assets/shared/yiqi.trime.yaml").write_text(theme)
# C2: 表情面板：格子无底色，列数按屏幕宽度均分，右侧不留白
patch("app/src/main/java/com/osfans/trime/ime/symbol/LiquidItemUi.kt",
      '            "key_back_color",\n', '            "liquid_key_back_color",\n', count=2)
patch("app/src/main/java/com/osfans/trime/ime/symbol/LiquidAdapter.kt",
      "                width = context.dp(scope.theme.liquidKeyboard.singleWidth)\n",
      "                val total = parent.width.takeIf { it > 0 } ?: context.resources.displayMetrics.widthPixels\n"
      "                val cols = (total / context.dp(scope.theme.liquidKeyboard.singleWidth)).coerceAtLeast(1)\n"
      "                width = total / cols - 2 * context.dp(scope.theme.liquidKeyboard.marginX.toInt())\n")
patch("app/src/main/java/com/osfans/trime/data/theme/ThemePrefs.kt",
      "            SELECTED_THEME,\n            \"trime\",", "            SELECTED_THEME,\n            \"yiqi.trime\",")
patch("app/src/main/java/com/osfans/trime/data/theme/ThemePrefs.kt",
      "            FOLLOW_SYSTEM_DAY_NIGHT,\n            false,", "            FOLLOW_SYSTEM_DAY_NIGHT,\n            true,")

# C6: 界面中统一称「一炁输入法」
for rel, pairs in {
    "app/src/main/res/values-zh-rCN/strings.xml": [
        ("同文输入法", "一炁输入法"),
        ("同文", "一炁"),
        ("击响中文之韵", "小鹤双拼 · 全拼 · 跨端同步"),
    ],
    "app/src/main/res/values-zh-rTW/strings.xml": [
        ("同文輸入法", "一炁輸入法"),
        ("同文", "一炁"),
        ("擊響中文之韻", "小鶴雙拼 · 全拼 · 跨端同步"),
    ],
    "app/src/main/res/values/strings.xml": [
        ("Trime", "YiQi"),
        ("Rimes with Your Keystrokes on Android", "小鹤双拼 · 全拼 · 跨端同步"),
    ],
}.items():
    p = T / rel
    s = p.read_text()
    for a, b in pairs:
        s = s.replace(a, b)
    p.write_text(s)
