//go:build windows

package main

import (
	"os"
	"syscall"
	"unsafe"
)

var version = "1.3.1"

func main() {
	background := false
	forceSettings := false
	for _, arg := range os.Args[1:] {
		if arg == "--background" {
			background = true
		}
		if arg == "--settings" {
			forceSettings = true
		}
	}

	// C1: 单实例运行；再次打开一炁或从输入法菜单点设置时唤起已有窗口。
	const errorAlreadyExists = 183
	mutex, _, err := procCreateMutexW.Call(0, 1, uintptr(unsafe.Pointer(u16("Local\\YiQiAppMutex"))))
	if mutex != 0 && err == syscall.Errno(errorAlreadyExists) {
		if existing, _, _ := procFindWindowW.Call(uintptr(unsafe.Pointer(u16("YiQiSettingsWindow"))), 0); existing != 0 {
			procPostMessageW.Call(existing, wmShowSettings, 0, 0)
		}
		return
	}

	ensureAutoStart()
	app := newApp(version)
	first := !app.store.Welcomed()
	if first {
		app.store.MarkWelcomed()
		deployRime()
	}
	show := forceSettings || first || app.pairCode == "" || !background
	app.run(show)
}
