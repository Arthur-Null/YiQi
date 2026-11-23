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
      "    override fun onStartInput(info: EditorInfo) {\n        com.osfans.trime.qi.QiSync.reconnectNow()\n")
# C2: 输入方式被设置页或首次按键切换后，工具栏按钮同步显示当前方式
patch("app/src/main/java/com/osfans/trime/ime/bar/InputBarDelegate.kt",
      "    override fun onRimeOptionUpdated(value: RimeMessage.OptionMessage.Data) {\n",
      "    override fun onRimeSchemaUpdated(schema: com.osfans.trime.core.SchemaItem) {\n"
      "        syncToolbarOptionStates()\n"
      "    }\n\n"
      "    override fun onRimeOptionUpdated(value: RimeMessage.OptionMessage.Data) {\n")
patch("app/src/main/java/com/osfans/trime/data/prefs/AppPrefs.kt",
      "            CLIPBOARD_SUGGESTION_TIMEOUT,\n            20,\n",
      "            CLIPBOARD_SUGGESTION_TIMEOUT,\n            100,\n")

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

# C2: 设置首页只保留普通用户需要的条目，去掉 Rime 专用的方案、用户词典、配置
for route, title, icon in [("SchemaList", "schemata", "ic_round_view_list_24"),
                           ("UserDict", "user_dictionary", "ic_baseline_book_24"),
                           ("Profile", "profile", "ic_baseline_snippet_folder_24")]:
    patch("app/src/main/java/com/osfans/trime/ui/main/MainFragment.kt",
          f"            addDestinationPreference(\n                R.string.{title},\n                R.drawable.{icon},\n"
          f"                NavigationRoute.{route},\n            )\n", "")

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
  Qi_shift: {label: '⇧', send: Shift_L, shift_lock: ascii_long}
  Qi_backspace: {label: '⌫', repeatable: true, send: BackSpace}
  Qi_space: {label: 空格, functional: false, send: space}
""", 1)
theme = ((ROOT / "theme/yiqi.head.yaml").read_text() + "\n"
         + section("liquid_keyboard", "android_keys") + section("android_keys", "preset_keys") + keys + "\n"
         + (ROOT / "theme/yiqi.tail.yaml").read_text())
(T / "app/src/main/assets/shared/yiqi.trime.yaml").write_text(theme)
patch("app/src/main/java/com/osfans/trime/data/theme/ThemePrefs.kt",
      "            SELECTED_THEME,\n            \"trime\",", "            SELECTED_THEME,\n            \"yiqi.trime\",")
patch("app/src/main/java/com/osfans/trime/data/theme/ThemePrefs.kt",
      "            FOLLOW_SYSTEM_DAY_NIGHT,\n            false,", "            FOLLOW_SYSTEM_DAY_NIGHT,\n            true,")

# C6: 界面中统一称「一炁输入法」
for rel, pairs in {
    "app/src/main/res/values-zh-rCN/strings.xml": [("同文输入法", "一炁输入法"), ("同文", "一炁")],
    "app/src/main/res/values-zh-rTW/strings.xml": [("同文輸入法", "一炁輸入法"), ("同文", "一炁")],
    "app/src/main/res/values/strings.xml": [("Trime", "YiQi")],
}.items():
    p = T / rel
    s = p.read_text()
    for a, b in pairs:
        s = s.replace(a, b)
    p.write_text(s)
