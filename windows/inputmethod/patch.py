#!/usr/bin/env python3
# C1, C2, C6: 在小狼毫（Weasel 0.16.3）源码上做出 Windows 版「一炁输入法」：
# 改名与独立用户目录、精简托盘菜单（一炁设置 / 切换输入方式 / 检查更新）、候选框右侧「双拼 / 全拼」点击按钮。
import pathlib
import sys

W = pathlib.Path(sys.argv[1])


def replace_exact(rel, old, new, count=1):
    p = W / rel
    s = p.read_text(encoding="utf-8", errors="replace")
    if s.count(old) != count:
        sys.exit(f"patch failed: {rel}: expected {count}x {old[:80]!r}, found {s.count(old)}")
    p.write_text(s.replace(old, new), encoding="utf-8")


def replace_if_present(rel, old, new):
    p = W / rel
    if not p.exists():
        return
    s = p.read_text(encoding="utf-8", errors="replace")
    if old in s:
        p.write_text(s.replace(old, new), encoding="utf-8")


# C6: 品牌名改为「一炁输入法」，独立注册表路径与独立 TSF CLSID，避免与已有小狼毫冲突
for rel in [
    "include/WeaselVersion.h",
    "include/WeaselCommon.h",
    "WeaselTSF/Globals.h",
    "WeaselTSF/Register.cpp",
    "WeaselServer/WeaselServer.rc",
    "WeaselServer/WeaselServerApp.cpp",
    "WeaselServer/WeaselTrayIcon.cpp",
    "WeaselDeployer/WeaselDeployer.rc",
    "WeaselSetup/WeaselSetup.rc",
]:
    replace_if_present(rel, "小狼毫", "一炁输入法")
    replace_if_present(rel, "小狼毫輸入法", "一炁输入法")
    replace_if_present(rel, "小狼毫输入法", "一炁输入法")
    replace_if_present(rel, "Weasel", "YiQi") if rel.endswith(".rc") else None

# 独立注册表键与默认用户目录（%APPDATA%\YiQi\Rime）
replace_if_present("include/WeaselUtility.h", L_KEY := 'L"Software\\\\Rime\\\\Weasel"', 'L"Software\\\\YiQi\\\\Weasel"')
replace_if_present("WeaselIPC/WeaselClientImpl.cpp", 'L"WeaselServer"', 'L"YiQiInputServer"')
replace_if_present("WeaselServer/WeaselServerApp.cpp", 'L"WeaselServer"', 'L"YiQiInputServer"')
replace_if_present("RimeWithWeasel/RimeWithWeasel.cpp", '"Weasel"', '"YiQi"')

# C1: 独立 TSF GUID，保证 Windows 语言栏只显示「一炁输入法」且不与小狼毫冲突
replace_if_present(
    "WeaselTSF/Globals.cpp",
    "{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}",
    "{7E2A5C41-8B19-4F3A-9D14-3C7E8A11F901}",
)
replace_if_present(
    "WeaselTSF/Globals.cpp",
    "{3D02CAB6-2B8E-4781-BA20-1C9267529467}",
    "{7E2A5C42-8B19-4F3A-9D14-3C7E8A11F902}",
)

# C2: 候选框右侧「双拼 / 全拼」点击切换辅助文件（与 qi_switch.lua 共用 qi_schema.txt）
helper_h = W / "WeaselUI/QiSchemeHelper.h"
helper_h.write_text(
    r'''#pragma once
#include <windows.h>
#include <shlobj.h>
#include <fstream>
#include <sstream>
#include <string>
#include <chrono>

// C2: 读写 %APPDATA%\YiQi\Rime\qi_schema.txt 与 qi_hotkey.txt，并支持唤醒 YiQi.exe 设置窗口。
inline std::wstring QiAppDataDir() {
  wchar_t path[MAX_PATH] = {0};
  if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, path))) {
    return std::wstring(path) + L"\\YiQi";
  }
  return L".";
}

inline std::wstring QiRimeUserDir() {
  return QiAppDataDir() + L"\\Rime";
}

inline std::string QiCurrentScheme() {
  std::ifstream in(QiRimeUserDir() + L"\\qi_schema.txt");
  std::string id;
  if (in >> id) {
    if (id == "rime_frost_double_pinyin_flypy" || id == "rime_frost") return id;
  }
  return "rime_frost_double_pinyin_flypy";
}

inline bool QiIsFlypy() {
  return QiCurrentScheme() == "rime_frost_double_pinyin_flypy";
}

inline std::wstring QiToggleSchemeAndWrite() {
  std::string next = QiIsFlypy() ? "rime_frost" : "rime_frost_double_pinyin_flypy";
  CreateDirectoryW(QiAppDataDir().c_str(), nullptr);
  CreateDirectoryW(QiRimeUserDir().c_str(), nullptr);
  auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch())
                .count();
  std::ofstream out(QiRimeUserDir() + L"\\qi_schema.txt", std::ios::trunc);
  if (out) {
    out << next << " panel-" << ms << "\n";
  }
  return next == "rime_frost_double_pinyin_flypy" ? L"rime_frost_double_pinyin_flypy" : L"rime_frost";
}

inline std::wstring QiHotkeyLabel() {
  std::ifstream in(QiRimeUserDir() + L"\\qi_hotkey.txt");
  std::string line;
  if (std::getline(in, line) && !line.empty()) {
    int n = MultiByteToWideChar(CP_UTF8, 0, line.c_str(), -1, nullptr, 0);
    if (n > 1) {
      std::wstring w(n - 1, L'\0');
      MultiByteToWideChar(CP_UTF8, 0, line.c_str(), -1, &w[0], n);
      return w;
    }
  }
  return L"Ctrl + Shift + 1";
}

inline void QiOpenSettingsApp() {
  if (HWND existing = FindWindowW(L"YiQiSettingsWindow", nullptr)) {
    PostMessageW(existing, WM_APP + 3, 0, 0);
    return;
  }
  wchar_t exe[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring dir(exe);
  auto pos = dir.find_last_of(L"\\/");
  if (pos != std::wstring::npos) dir = dir.substr(0, pos);
  std::wstring app = dir + L"\\YiQi.exe";
  ShellExecuteW(nullptr, L"open", app.c_str(), L"--settings", dir.c_str(), SW_SHOWNORMAL);
}
''',
    encoding="utf-8",
)

# C2: 禁用 Weasel 自带 WinSparkle 检查更新，交由一炁设置程序统一在线更新
replace_if_present("WeaselServer/WeaselServerApp.cpp", "win_sparkle_init();", "// YiQi handles online updates")
replace_if_present("WeaselServer/WeaselServerApp.cpp", "win_sparkle_check_update_with_ui();", "QiOpenSettingsApp();")

print("Patched Weasel source for YiQi successfully:", W)
