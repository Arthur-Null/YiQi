//go:build windows

package main

import (
	"errors"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	user32                     = syscall.NewLazyDLL("user32.dll")
	kernel32                   = syscall.NewLazyDLL("kernel32.dll")
	gdi32                      = syscall.NewLazyDLL("gdi32.dll")
	shell32                    = syscall.NewLazyDLL("shell32.dll")
	comctl32                   = syscall.NewLazyDLL("comctl32.dll")
	procRegisterClassExW       = user32.NewProc("RegisterClassExW")
	procCreateWindowExW        = user32.NewProc("CreateWindowExW")
	procDestroyWindow          = user32.NewProc("DestroyWindow")
	procDefWindowProcW         = user32.NewProc("DefWindowProcW")
	procShowWindow             = user32.NewProc("ShowWindow")
	procUpdateWindow           = user32.NewProc("UpdateWindow")
	procSetForegroundWindow    = user32.NewProc("SetForegroundWindow")
	procGetMessageW            = user32.NewProc("GetMessageW")
	procTranslateMessage       = user32.NewProc("TranslateMessage")
	procDispatchMessageW       = user32.NewProc("DispatchMessageW")
	procPostQuitMessage        = user32.NewProc("PostQuitMessage")
	procPostMessageW           = user32.NewProc("PostMessageW")
	procSendMessageW           = user32.NewProc("SendMessageW")
	procSetWindowTextW         = user32.NewProc("SetWindowTextW")
	procGetWindowTextLengthW   = user32.NewProc("GetWindowTextLengthW")
	procGetWindowTextW         = user32.NewProc("GetWindowTextW")
	procEnableWindow           = user32.NewProc("EnableWindow")
	procMoveWindow             = user32.NewProc("MoveWindow")
	procSetTimer               = user32.NewProc("SetTimer")
	procKillTimer              = user32.NewProc("KillTimer")
	procMessageBoxW            = user32.NewProc("MessageBoxW")
	procFindWindowW            = user32.NewProc("FindWindowW")
	procRegisterWindowMessageW = user32.NewProc("RegisterWindowMessageW")
	procLoadCursorW            = user32.NewProc("LoadCursorW")
	procLoadIconW              = user32.NewProc("LoadIconW")
	procGetSystemMetrics       = user32.NewProc("GetSystemMetrics")
	procGetDpiForSystem        = user32.NewProc("GetDpiForSystem")
	procSetProcessDpiAwareCtx  = user32.NewProc("SetProcessDpiAwarenessContext")
	procGetKeyState            = user32.NewProc("GetKeyState")
	procSetFocus               = user32.NewProc("SetFocus")
	procCreatePopupMenu        = user32.NewProc("CreatePopupMenu")
	procAppendMenuW            = user32.NewProc("AppendMenuW")
	procTrackPopupMenu         = user32.NewProc("TrackPopupMenu")
	procDestroyMenu            = user32.NewProc("DestroyMenu")
	procGetCursorPos           = user32.NewProc("GetCursorPos")
	procAddClipboardListener   = user32.NewProc("AddClipboardFormatListener")
	procOpenClipboard          = user32.NewProc("OpenClipboard")
	procCloseClipboard         = user32.NewProc("CloseClipboard")
	procEmptyClipboard         = user32.NewProc("EmptyClipboard")
	procGetClipboardData       = user32.NewProc("GetClipboardData")
	procSetClipboardData       = user32.NewProc("SetClipboardData")
	procIsClipboardFormatAvail = user32.NewProc("IsClipboardFormatAvailable")
	procGetClipboardSeqNum     = user32.NewProc("GetClipboardSequenceNumber")
	procInvalidateRect         = user32.NewProc("InvalidateRect")
	procSetBkMode              = gdi32.NewProc("SetBkMode")
	procSetTextColor           = gdi32.NewProc("SetTextColor")
	procCreateSolidBrush       = gdi32.NewProc("CreateSolidBrush")
	procCreateFontW            = gdi32.NewProc("CreateFontW")
	procGetModuleHandleW       = kernel32.NewProc("GetModuleHandleW")
	procCreateMutexW           = kernel32.NewProc("CreateMutexW")
	procGlobalAlloc            = kernel32.NewProc("GlobalAlloc")
	procGlobalLock             = kernel32.NewProc("GlobalLock")
	procGlobalUnlock           = kernel32.NewProc("GlobalUnlock")
	procGlobalFree             = kernel32.NewProc("GlobalFree")
	procShellExecuteW          = shell32.NewProc("ShellExecuteW")
	procShellNotifyIconW       = shell32.NewProc("Shell_NotifyIconW")
	procInitCommonControlsEx   = comctl32.NewProc("InitCommonControlsEx")
)

const (
	cfUnicodeText    = 13
	gmemMoveable     = 0x0002
	wmDestroy        = 0x0002
	wmClose          = 0x0010
	wmCommand        = 0x0111
	wmTimer          = 0x0113
	wmKeyDown        = 0x0100
	wmSysKeyDown     = 0x0104
	wmCtlColorStatic = 0x0138
	wmClipboardUpd   = 0x031D
	wmApp            = 0x8000
	wmTray           = wmApp + 1
	wmRefreshUI      = wmApp + 2
	wmShowSettings   = wmApp + 3
	wmLButtonUp      = 0x0202
	wmLButtonDblClk  = 0x0203
	wmRButtonUp      = 0x0205
	swHide           = 0
	swShow           = 5
	swRestore        = 9
	wsOverlapped     = 0x00000000
	wsCaption        = 0x00C00000
	wsSysMenu        = 0x00080000
	wsMinimizeBox    = 0x00020000
	wsChild          = 0x40000000
	wsVisible        = 0x10000000
	wsTabStop        = 0x00010000
	wsGroup          = 0x00020000
	wsBorder         = 0x00800000
	wsExClientEdge   = 0x00000200
	bsPushButton     = 0x00000000
	bsAutoRadio      = 0x00000009
	bsAutoCheckBox   = 0x00000003
	bsGroupBox       = 0x00000007
	bmSetCheck       = 0x00F1
	bmGetCheck       = 0x00F0
	bstUnchecked     = 0
	bstChecked       = 1
	esAutoHScroll    = 0x0080
	ssLeft           = 0x00000000
	wmSetFont        = 0x0030
	emSetCueBanner   = 0x1501
	mbOKCancel       = 0x00000001
	mbIconQuestion   = 0x00000020
	idOK             = 1
	nimAdd           = 0x00000000
	nimModify        = 0x00000001
	nimDelete        = 0x00000002
	nifMessage       = 0x00000001
	nifIcon          = 0x00000002
	nifTip           = 0x00000004
	mfString         = 0x00000000
	mfSeparator      = 0x00000800
	tpmRightButton   = 0x0002
	tpmBottomAlign   = 0x0020
	tpmReturnCmd     = 0x0100
	idcArrow         = 32512
	idiApplication   = 32512
	vkEscape         = 0x1B
	vkControl        = 0x11
	vkMenu           = 0x12
	vkShift          = 0x10
	smCxScreen       = 0
	smCyScreen       = 1
)

type wndClassExW struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       uintptr
}

type point struct{ x, y int32 }

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

type initCommonControlsExStruct struct {
	dwSize uint32
	dwICC  uint32
}

type notifyIconDataW struct {
	cbSize           uint32
	hWnd             uintptr
	uID              uint32
	uFlags           uint32
	uCallbackMessage uint32
	hIcon            uintptr
	szTip            [128]uint16
}

func u16(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func getModuleHandle() uintptr {
	h, _, _ := procGetModuleHandleW.Call(0)
	return h
}

func initDPIAndControls() {
	if procSetProcessDpiAwareCtx.Find() == nil {
		const perMonitorV2 = ^uintptr(3) // (DPI_AWARENESS_CONTEXT)-4
		procSetProcessDpiAwareCtx.Call(perMonitorV2)
	}
	icc := initCommonControlsExStruct{dwSize: uint32(unsafe.Sizeof(initCommonControlsExStruct{})), dwICC: 0x00004000}
	procInitCommonControlsEx.Call(uintptr(unsafe.Pointer(&icc)))
}

func dpiScale(px int32) int32 {
	dpi := int32(96)
	if procGetDpiForSystem.Find() == nil {
		if d, _, _ := procGetDpiForSystem.Call(); d > 0 {
			dpi = int32(d)
		}
	}
	return px * dpi / 96
}

func createUIFont(pt int32, bold bool, mono bool) uintptr {
	h := -dpiScale(pt * 96 / 72)
	weight := int32(400)
	if bold {
		weight = 700
	}
	face := "Microsoft YaHei UI"
	if mono {
		face = "Consolas"
	}
	f, _, _ := procCreateFontW.Call(
		uintptr(h), 0, 0, 0, uintptr(weight),
		0, 0, 0, 1, 0, 0, 5, 0,
		uintptr(unsafe.Pointer(u16(face))),
	)
	return f
}

func getText(hwnd uintptr) string {
	n, _, _ := procGetWindowTextLengthW.Call(hwnd)
	if n == 0 {
		return ""
	}
	buf := make([]uint16, n+1)
	procGetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(&buf[0])), n+1)
	return syscall.UTF16ToString(buf)
}

func setText(hwnd uintptr, s string) {
	procSetWindowTextW.Call(hwnd, uintptr(unsafe.Pointer(u16(s))))
}

func setCueBanner(hwnd uintptr, hint string) {
	procSendMessageW.Call(hwnd, emSetCueBanner, 1, uintptr(unsafe.Pointer(u16(hint))))
}

func shellOpen(path string) {
	procShellExecuteW.Call(0, uintptr(unsafe.Pointer(u16("open"))), uintptr(unsafe.Pointer(u16(path))), 0, 0, swShow)
}

func keyDown(vk uint32) bool {
	r, _, _ := procGetKeyState.Call(uintptr(vk))
	return (uint16(r) & 0x8000) != 0
}

// WinClipboard C3: Windows 系统剪贴板读写（CF_UNICODETEXT），支持几千字长文本直接 Ctrl+V 粘贴。
type WinClipboard struct{}

func openClipboardRetry() bool {
	for i := 0; i < 8; i++ {
		r, _, _ := procOpenClipboard.Call(0)
		if r != 0 {
			return true
		}
		time.Sleep(15 * time.Millisecond)
	}
	return false
}

func (WinClipboard) Read() (string, error) {
	avail, _, _ := procIsClipboardFormatAvail.Call(cfUnicodeText)
	if avail == 0 {
		return "", nil
	}
	if !openClipboardRetry() {
		return "", errors.New("clipboard busy")
	}
	defer procCloseClipboard.Call()
	h, _, _ := procGetClipboardData.Call(cfUnicodeText)
	if h == 0 {
		return "", nil
	}
	ptr, _, _ := procGlobalLock.Call(h)
	if ptr == 0 {
		return "", nil
	}
	defer procGlobalUnlock.Call(h)
	const maxRunes = 1 << 20
	var raw []uint16
	for i := 0; i < maxRunes; i++ {
		v := *(*uint16)(unsafe.Pointer(ptr + uintptr(i)*2))
		if v == 0 {
			break
		}
		raw = append(raw, v)
	}
	return string(utf16.Decode(raw)), nil
}

func (WinClipboard) Write(text string) error {
	encoded := utf16.Encode([]rune(text))
	encoded = append(encoded, 0)
	bytesLen := uintptr(len(encoded) * 2)
	h, _, _ := procGlobalAlloc.Call(gmemMoveable, bytesLen)
	if h == 0 {
		return errors.New("GlobalAlloc failed")
	}
	ptr, _, _ := procGlobalLock.Call(h)
	if ptr == 0 {
		procGlobalFree.Call(h)
		return errors.New("GlobalLock failed")
	}
	dst := unsafe.Slice((*uint16)(unsafe.Pointer(ptr)), len(encoded))
	copy(dst, encoded)
	procGlobalUnlock.Call(h)

	if !openClipboardRetry() {
		procGlobalFree.Call(h)
		return errors.New("clipboard busy")
	}
	defer procCloseClipboard.Call()
	procEmptyClipboard.Call()
	r, _, _ := procSetClipboardData.Call(cfUnicodeText, h)
	if r == 0 {
		procGlobalFree.Call(h)
		return errors.New("SetClipboardData failed")
	}
	return nil
}

func clipboardSeq() uint32 {
	r, _, _ := procGetClipboardSeqNum.Call()
	return uint32(r)
}
