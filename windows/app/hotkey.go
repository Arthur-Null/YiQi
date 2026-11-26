package main

import (
	"fmt"
	"strings"

	"qi/sync/client"
)

type vkSpec struct {
	base    string
	shifted string
	label   string
}

var vkTable = map[uint32]vkSpec{
	0x30: {"0", "parenright", "0"},
	0x31: {"1", "exclam", "1"},
	0x32: {"2", "at", "2"},
	0x33: {"3", "numbersign", "3"},
	0x34: {"4", "dollar", "4"},
	0x35: {"5", "percent", "5"},
	0x36: {"6", "asciicircum", "6"},
	0x37: {"7", "ampersand", "7"},
	0x38: {"8", "asterisk", "8"},
	0x39: {"9", "parenleft", "9"},
	0xBA: {"semicolon", "colon", ";"},
	0xBB: {"equal", "plus", "="},
	0xBC: {"comma", "less", ","},
	0xBD: {"minus", "underscore", "-"},
	0xBE: {"period", "greater", "."},
	0xBF: {"slash", "question", "/"},
	0xC0: {"grave", "asciitilde", "`"},
	0xDB: {"bracketleft", "braceleft", "["},
	0xDC: {"backslash", "bar", "\\"},
	0xDD: {"bracketright", "braceright", "]"},
	0xDE: {"apostrophe", "quotedbl", "'"},
	0x20: {"space", "", "Space"},
	0x09: {"Tab", "", "Tab"},
}

// HotkeyFromVK C2: 将 Windows 虚拟键码转为 Rime 快捷键写法；必须含 Ctrl 或 Alt（F1–F12 除外）。
func HotkeyFromVK(vk uint32, ctrl, alt, shift bool) (client.Hotkey, bool) {
	var spec vkSpec
	isF := false
	switch {
	case vk >= 0x41 && vk <= 0x5A:
		ch := string(rune('a' + (vk - 0x41)))
		spec = vkSpec{base: ch, label: strings.ToUpper(ch)}
	case vk >= 0x70 && vk <= 0x7B:
		n := vk - 0x70 + 1
		f := fmt.Sprintf("F%d", n)
		spec = vkSpec{base: f, label: f}
		isF = true
	default:
		var ok bool
		spec, ok = vkTable[vk]
		if !ok {
			return client.Hotkey{}, false
		}
	}
	if !ctrl && !alt && !isF {
		return client.Hotkey{}, false
	}
	var mods, labels []string
	if ctrl {
		mods = append(mods, "Control")
		labels = append(labels, "Ctrl")
	}
	if alt {
		mods = append(mods, "Alt")
		labels = append(labels, "Alt")
	}
	if shift {
		mods = append(mods, "Shift")
		labels = append(labels, "Shift")
	}
	labels = append(labels, spec.label)
	rime := []string{strings.Join(append(append([]string{}, mods...), spec.base), "+")}
	if shift && spec.shifted != "" {
		rime = append(rime, strings.Join(append(append([]string{}, mods...), spec.shifted), "+"))
	}
	return client.Hotkey{
		Label: strings.Join(labels, " + "),
		Rime:  rime,
	}, true
}
