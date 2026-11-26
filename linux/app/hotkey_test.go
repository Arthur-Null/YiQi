package main

import (
	"testing"

	"qi/sync/client"
)

// C2: Linux 快捷键录制把 X11/GDK keysym 转为 Rime 写法，并拒绝无修饰键的普通字母。
func TestHotkeyFromKeysym(t *testing.T) {
	h, ok := HotkeyFromKeysym("exclam", true, false, true)
	if !ok || !h.Equal(client.DefaultHotkey) {
		t.Fatalf("got %+v (%v), want %+v", h, ok, client.DefaultHotkey)
	}
	h, ok = HotkeyFromKeysym("K", true, true, false)
	if !ok || h.Label != "Ctrl + Alt + K" || len(h.Rime) != 1 || h.Rime[0] != "Control+Alt+k" {
		t.Fatalf("unexpected Ctrl+Alt+K: %+v (%v)", h, ok)
	}
	h, ok = HotkeyFromKeysym("F9", false, false, false)
	if !ok || h.Label != "F9" || h.Rime[0] != "F9" {
		t.Fatalf("unexpected F9: %+v (%v)", h, ok)
	}
	if _, ok := HotkeyFromKeysym("a", false, false, false); ok {
		t.Fatal("bare letter should be rejected")
	}
}
