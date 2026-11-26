//go:build linux

package main

import (
	"os"
	"os/exec"
	"path/filepath"
)

func configDir() string {
	if d := os.Getenv("XDG_CONFIG_HOME"); d != "" {
		return filepath.Join(d, "yiqi")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "yiqi")
}

func dataDir() string {
	if d := os.Getenv("XDG_DATA_HOME"); d != "" {
		return filepath.Join(d, "yiqi")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "yiqi")
}

func socketPath() string {
	if d := os.Getenv("XDG_RUNTIME_DIR"); d != "" {
		return filepath.Join(d, "yiqi.sock")
	}
	return filepath.Join(os.TempDir(), "yiqi.sock")
}

// C1: 自动检测 Fcitx5 与 IBus 的 Rime 用户目录，保持 qi_schema.txt 与 qi_hotkey.txt 同步。
func detectRimeDirs() ([]string, string) {
	home, _ := os.UserHomeDir()
	fcitxDir := filepath.Join(home, ".local", "share", "fcitx5", "rime")
	ibusDir := filepath.Join(home, ".config", "ibus", "rime")

	hasFcitx := commandExists("fcitx5") || dirExists(fcitxDir)
	hasIbus := commandExists("ibus") || dirExists(ibusDir)

	var dirs []string
	framework := ""
	if hasFcitx {
		dirs = append(dirs, fcitxDir)
		framework = "fcitx5"
	}
	if hasIbus {
		dirs = append(dirs, ibusDir)
		if framework == "" {
			framework = "ibus"
		}
	}
	if len(dirs) == 0 {
		dirs = append(dirs, fcitxDir)
	}
	return dirs, framework
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func dirExists(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.IsDir()
}

func reloadInputMethod(framework string) {
	if framework == "fcitx5" && commandExists("fcitx5-remote") {
		_ = exec.Command("fcitx5-remote", "-r").Start()
		return
	}
	if framework == "ibus" && commandExists("ibus") {
		_ = exec.Command("ibus", "engine", "rime").Start()
	}
}
