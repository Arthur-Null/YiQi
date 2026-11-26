package client

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// C2: 小鹤双拼与全拼方案标识，与 rime/lua/qi_switch.lua 一致。
type Scheme string

const (
	SchemeFlypy   Scheme = "rime_frost_double_pinyin_flypy"
	SchemeQuanpin Scheme = "rime_frost"
)

func (s Scheme) Title() string {
	if s == SchemeQuanpin {
		return "全拼"
	}
	return "小鹤双拼"
}

func (s Scheme) Short() string {
	if s == SchemeQuanpin {
		return "全拼"
	}
	return "双拼"
}

func (s Scheme) Toggle() Scheme {
	if s == SchemeFlypy {
		return SchemeQuanpin
	}
	return SchemeFlypy
}

// C2: 切换快捷键由用户设置，保存在 qi_hotkey.txt（第一行显示名称，第二行为空格分隔的 Rime 按键写法）。
type Hotkey struct {
	Label string   `json:"label"`
	Rime  []string `json:"rime"`
}

func (h Hotkey) Equal(o Hotkey) bool {
	if h.Label != o.Label || len(h.Rime) != len(o.Rime) {
		return false
	}
	for i := range h.Rime {
		if h.Rime[i] != o.Rime[i] {
			return false
		}
	}
	return true
}

var DefaultHotkey = Hotkey{
	Label: "Ctrl + Shift + 1",
	Rime:  []string{"Control+Shift+1", "Control+Shift+exclam"},
}

type RimeState struct {
	Dirs []string
}

func NewRimeState(dirs ...string) *RimeState {
	var clean []string
	seen := map[string]bool{}
	for _, d := range dirs {
		if d == "" || seen[d] {
			continue
		}
		seen[d] = true
		clean = append(clean, d)
	}
	return &RimeState{Dirs: clean}
}

func (r *RimeState) Scheme() Scheme {
	var best Scheme
	var bestMod time.Time
	for _, d := range r.Dirs {
		p := filepath.Join(d, "qi_schema.txt")
		st, err := os.Stat(p)
		if err != nil {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		fields := strings.Fields(string(b))
		if len(fields) == 0 {
			continue
		}
		sc := Scheme(fields[0])
		if sc != SchemeFlypy && sc != SchemeQuanpin {
			continue
		}
		if best == "" || st.ModTime().After(bestMod) {
			best = sc
			bestMod = st.ModTime()
		}
	}
	if best == "" {
		return SchemeFlypy
	}
	return best
}

func (r *RimeState) RequestScheme(s Scheme) error {
	line := fmt.Sprintf("%s ui-%d\n", s, time.Now().UnixMilli())
	var firstErr error
	for _, d := range r.Dirs {
		if err := writeAtomic(filepath.Join(d, "qi_schema.txt"), []byte(line)); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (r *RimeState) Hotkey() Hotkey {
	for _, d := range r.Dirs {
		b, err := os.ReadFile(filepath.Join(d, "qi_hotkey.txt"))
		if err != nil {
			continue
		}
		lines := strings.SplitN(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n", 3)
		if len(lines) < 2 {
			continue
		}
		label := strings.TrimSpace(lines[0])
		specs := strings.Fields(lines[1])
		if label != "" && len(specs) > 0 {
			return Hotkey{Label: label, Rime: specs}
		}
	}
	return DefaultHotkey
}

func (r *RimeState) SetHotkey(h Hotkey) error {
	content := fmt.Sprintf("%s\n%s\n", h.Label, strings.Join(h.Rime, " "))
	var firstErr error
	for _, d := range r.Dirs {
		if err := writeAtomic(filepath.Join(d, "qi_hotkey.txt"), []byte(content)); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// C1: 雾凇拼音农历脚本只在用户目录里查找 lua/lunar.db，缺省时从共享目录补一份。
func (r *RimeState) EnsureUserCopies(sharedDir string) {
	if sharedDir == "" {
		return
	}
	src := filepath.Join(sharedDir, "lua", "lunar.db")
	if _, err := os.Stat(src); err != nil {
		return
	}
	for _, d := range r.Dirs {
		dst := filepath.Join(d, "lua", "lunar.db")
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		_ = os.MkdirAll(filepath.Dir(dst), 0o755)
		_ = copyFile(src, dst)
	}
}

func writeAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return os.WriteFile(path, data, 0o644)
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}
