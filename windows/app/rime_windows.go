//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"

	"qi/sync/client"
)

var (
	regAdvapi32 = syscall.NewLazyDLL("advapi32.dll")
	regCreateEx = regAdvapi32.NewProc("RegCreateKeyExW")
	regSetValue = regAdvapi32.NewProc("RegSetValueExW")
	regCloseKey = regAdvapi32.NewProc("RegCloseKey")
)

func appDataDir() string {
	base := os.Getenv("APPDATA")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, "AppData", "Roaming")
	}
	return filepath.Join(base, "YiQi")
}

func rimeUserDir() string {
	return filepath.Join(appDataDir(), "Rime")
}

func exeDir() string {
	p, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(p)
}

func sharedRimeDir() string {
	return filepath.Join(exeDir(), "data")
}

// C1: 开机自启写入当前用户的 Run 注册表项，后台常驻维护剪贴板同步。
func ensureAutoStart() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	const hkcu = 0x80000001
	const keyWrite = 0x20006
	subKey, _ := syscall.UTF16PtrFromString(`Software\Microsoft\Windows\CurrentVersion\Run`)
	var hKey uintptr
	r, _, _ := regCreateEx.Call(
		hkcu,
		uintptr(unsafe.Pointer(subKey)),
		0, 0, 0,
		keyWrite, 0,
		uintptr(unsafe.Pointer(&hKey)), 0,
	)
	if r != 0 {
		return
	}
	defer regCloseKey.Call(hKey)
	name, _ := syscall.UTF16PtrFromString("YiQi")
	val, _ := syscall.UTF16FromString(`"` + exe + `" --background`)
	regSetValue.Call(
		hKey,
		uintptr(unsafe.Pointer(name)),
		0,
		1, // REG_SZ
		uintptr(unsafe.Pointer(&val[0])),
		uintptr(len(val)*2),
	)
}

// C2: 切换输入方式后通知一炁输入法服务立即应用到当前会话。
func notifyInputMethodScheme(rime *client.RimeState, s client.Scheme) {
	_ = rime.RequestScheme(s)
	msgName, _ := syscall.UTF16PtrFromString("YiQiSchemeChanged")
	msgID, _, _ := procRegisterWindowMessageW.Call(uintptr(unsafe.Pointer(msgName)))
	if msgID != 0 {
		const hwndBroadcast = 0xFFFF
		procPostMessageW.Call(hwndBroadcast, msgID, 0, 0)
	}
}

func deployRime() {
	for _, name := range []string{"YiQiDeployer.exe", "WeaselDeployer.exe"} {
		deployer := filepath.Join(exeDir(), name)
		if _, err := os.Stat(deployer); err != nil {
			continue
		}
		cmd := exec.Command(deployer, "/deploy")
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		_ = cmd.Start()
		return
	}
}

// C9: 请输入法服务做一次「同步用户资料」：导出本机词库快照，并合并其他设备的快照。
func syncRimeUserData() error {
	for _, name := range []string{"YiQiDeployer.exe", "WeaselDeployer.exe"} {
		deployer := filepath.Join(exeDir(), name)
		if _, err := os.Stat(deployer); err != nil {
			continue
		}
		cmd := exec.Command(deployer, "/sync")
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		return cmd.Run()
	}
	return os.ErrNotExist
}
