package main

import (
	"testing"

	"qi/sync/client"
)

// C2: Windows 快捷键录制生成与 qi_switch.lua 一致的 Rime 写法，并拒绝无修饰键的普通字母。
func TestHotkeyFromVK(t *testing.T) {
	h, ok := HotkeyFromVK(0x31, true, false, true)
	if !ok || !h.Equal(client.DefaultHotkey) {
		t.Fatalf("got %+v (%v), want %+v", h, ok, client.DefaultHotkey)
	}
	h, ok = HotkeyFromVK(0x4B, true, true, false)
	if !ok || h.Label != "Ctrl + Alt + K" || len(h.Rime) != 1 || h.Rime[0] != "Control+Alt+k" {
		t.Fatalf("unexpected Ctrl+Alt+K: %+v (%v)", h, ok)
	}
	h, ok = HotkeyFromVK(0x77, false, false, false) // F8
	if !ok || h.Label != "F8" || h.Rime[0] != "F8" {
		t.Fatalf("unexpected F8: %+v (%v)", h, ok)
	}
	if _, ok := HotkeyFromVK(0x41, false, false, false); ok {
		t.Fatal("bare letter A should be rejected")
	}
	if _, ok := HotkeyFromVK(0x41, false, false, true); ok {
		t.Fatal("Shift+A without Ctrl/Alt should be rejected")
	}
}
