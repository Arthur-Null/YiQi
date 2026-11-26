package main

import (
	"strings"

	"qi/sync/client"
)

type keySpec struct {
	base    string
	shifted string
	label   string
}

var linuxKeys = map[string]keySpec{
	"0": {"0", "parenright", "0"}, "parenright": {"0", "parenright", "0"},
	"1": {"1", "exclam", "1"}, "exclam": {"1", "exclam", "1"},
	"2": {"2", "at", "2"}, "at": {"2", "at", "2"},
	"3": {"3", "numbersign", "3"}, "numbersign": {"3", "numbersign", "3"},
	"4": {"4", "dollar", "4"}, "dollar": {"4", "dollar", "4"},
	"5": {"5", "percent", "5"}, "percent": {"5", "percent", "5"},
	"6": {"6", "asciicircum", "6"}, "asciicircum": {"6", "asciicircum", "6"},
	"7": {"7", "ampersand", "7"}, "ampersand": {"7", "ampersand", "7"},
	"8": {"8", "asterisk", "8"}, "asterisk": {"8", "asterisk", "8"},
	"9": {"9", "parenleft", "9"}, "parenleft": {"9", "parenleft", "9"},
	"minus": {"minus", "underscore", "-"}, "underscore": {"minus", "underscore", "-"},
	"equal": {"equal", "plus", "="}, "plus": {"equal", "plus", "="},
	"bracketleft": {"bracketleft", "braceleft", "["}, "braceleft": {"bracketleft", "braceleft", "["},
	"bracketright": {"bracketright", "braceright", "]"}, "braceright": {"bracketright", "braceright", "]"},
	"backslash": {"backslash", "bar", "\\"}, "bar": {"backslash", "bar", "\\"},
	"semicolon": {"semicolon", "colon", ";"}, "colon": {"semicolon", "colon", ";"},
	"apostrophe": {"apostrophe", "quotedbl", "'"}, "quotedbl": {"apostrophe", "quotedbl", "'"},
	"comma": {"comma", "less", ","}, "less": {"comma", "less", ","},
	"period": {"period", "greater", "."}, "greater": {"period", "greater", "."},
	"slash": {"slash", "question", "/"}, "question": {"slash", "question", "/"},
	"grave": {"grave", "asciitilde", "`"}, "asciitilde": {"grave", "asciitilde", "`"},
	"space": {"space", "", "Space"},
	"Tab":   {"Tab", "", "Tab"}, "ISO_Left_Tab": {"Tab", "", "Tab"},
}

// HotkeyFromKeysym C2: 将 X11/GDK keysym 与修饰键转为 Rime 快捷键写法；必须含 Ctrl 或 Alt（F1–F12 除外）。
func HotkeyFromKeysym(sym string, ctrl, alt, shift bool) (client.Hotkey, bool) {
	var spec keySpec
	isF := false
	if len(sym) == 1 && ((sym[0] >= 'a' && sym[0] <= 'z') || (sym[0] >= 'A' && sym[0] <= 'Z')) {
		low := strings.ToLower(sym)
		spec = keySpec{base: low, label: strings.ToUpper(low)}
	} else if len(sym) >= 2 && sym[0] == 'F' {
		validF := true
		for _, ch := range sym[1:] {
			if ch < '0' || ch > '9' {
				validF = false
				break
			}
		}
		if validF {
			spec = keySpec{base: sym, label: sym}
			isF = true
		}
	}
	if spec.base == "" {
		var ok bool
		spec, ok = linuxKeys[sym]
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
	return client.Hotkey{Label: strings.Join(labels, " + "), Rime: rime}, true
}
