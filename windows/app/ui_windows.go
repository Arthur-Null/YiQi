//go:build windows

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"qi/sync/client"
)

const (
	ctrlUpdateBox = 100 + iota
	ctrlUpdateText
	ctrlUpdateBtn
	ctrlUpdateNote
	ctrlSchemeBox
	ctrlRadioFlypy
	ctrlRadioQuanpin
	ctrlHotkeyLabel
	ctrlHotkeyBtn
	ctrlHotkeyReset
	ctrlSchemeNote
	ctrlSyncBox
	ctrlSyncStatus
	ctrlBtnInvite
	ctrlBtnLeave
	ctrlPairedNote
	ctrlInviteHint
	ctrlInviteHost
	ctrlInviteCode
	ctrlInviteTimer
	ctrlBtnInviteDone
	ctrlBtnInviteRegen
	ctrlServerLbl
	ctrlServerEdit
	ctrlCodeLbl
	ctrlCodeEdit
	ctrlBtnJoin
	ctrlJoinNote
	ctrlBtnRegister
	ctrlRegisterNote
	ctrlSyncMsg
	ctrlSyncFooterNote
	ctrlVersionLbl
	ctrlCheckUpdateBtn
	ctrlCheckUpdateStatus
	ctrlBetaCheck
)

const (
	menuOpenSettings = 2001
	menuUpdate       = 2002
	menuCheckUpdate  = 2003
	menuSwitchScheme = 2004
	menuExit         = 2005
)

const (
	timerPoll       = 1
	timerUpdateAuto = 2
)

type App struct {
	version string
	store   *client.Store
	rime    *client.RimeState
	syncer  *client.Syncer
	clip    WinClipboard
	ctx     context.Context
	cancel  context.CancelFunc

	hwnd        uintptr
	hInstance   uintptr
	fontBody    uintptr
	fontBold    uintptr
	fontNote    uintptr
	fontCode    uintptr
	brushBg     uintptr
	trayAdded   bool
	lastClipSeq uint32

	mu            sync.Mutex
	scheme        client.Scheme
	hotkey        client.Hotkey
	recording     bool
	status        client.Status
	serverHost    string
	pairCode      string
	inviteCode    string
	inviteExp     time.Time
	message       string
	busy          bool
	update        *client.Release
	updateMessage string

	ctrls map[int]uintptr
}

var globalApp *App

func newApp(version string) *App {
	store := client.NewStore(appDataDir())
	rime := client.NewRimeState(rimeUserDir())
	rime.EnsureUserCopies(sharedRimeDir())
	clip := WinClipboard{}
	syncer := client.NewSyncer(store.DeviceID(), clip)
	ctx, cancel := context.WithCancel(context.Background())

	a := &App{
		version:     version,
		store:       store,
		rime:        rime,
		syncer:      syncer,
		clip:        clip,
		ctx:         ctx,
		cancel:      cancel,
		scheme:      rime.Scheme(),
		hotkey:      rime.Hotkey(),
		status:      client.StatusUnpaired,
		pairCode:    store.PairCode(),
		lastClipSeq: clipboardSeq(),
		ctrls:       map[int]uintptr{},
	}
	syncer.OnStatus = func(st client.Status) {
		a.mu.Lock()
		a.status = st
		a.serverHost = syncer.ServerHost()
		a.mu.Unlock()
		a.postRefresh()
	}
	return a
}

func (a *App) postRefresh() {
	if a.hwnd != 0 {
		procPostMessageW.Call(a.hwnd, wmRefreshUI, 0, 0)
	}
}

func (a *App) run(showWindow bool) {
	globalApp = a
	initDPIAndControls()
	a.hInstance = getModuleHandle()
	a.fontBody = createUIFont(10, false, false)
	a.fontBold = createUIFont(11, true, false)
	a.fontNote = createUIFont(9, false, false)
	a.fontCode = createUIFont(22, true, true)
	a.brushBg, _, _ = procCreateSolidBrush.Call(0x00F5F5F5)

	className := u16("YiQiSettingsWindow")
	cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
	icon, _, _ := procLoadIconW.Call(a.hInstance, 1)
	if icon == 0 {
		icon, _, _ = procLoadIconW.Call(0, idiApplication)
	}

	wc := wndClassExW{
		cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		lpfnWndProc:   syscall.NewCallback(wndProc),
		hInstance:     a.hInstance,
		hIcon:         icon,
		hIconSm:       icon,
		hCursor:       cursor,
		hbrBackground: a.brushBg,
		lpszClassName: className,
	}
	procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	w, h := dpiScale(580), dpiScale(640)
	sw, _, _ := procGetSystemMetrics.Call(smCxScreen)
	sh, _, _ := procGetSystemMetrics.Call(smCyScreen)
	x := (int32(sw) - w) / 2
	y := (int32(sh) - h) / 2

	style := uintptr(wsOverlapped | wsCaption | wsSysMenu | wsMinimizeBox)
	a.hwnd, _, _ = procCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(u16("一炁输入法"))),
		style,
		uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		0, 0, a.hInstance, 0,
	)

	a.buildControls()
	a.addTrayIcon(icon)
	procAddClipboardListener.Call(a.hwnd)
	procSetTimer.Call(a.hwnd, timerPoll, 1000, 0)
	procSetTimer.Call(a.hwnd, timerUpdateAuto, 6*3600*1000, 0)

	go a.syncer.Start(a.ctx)
	a.syncer.Configure(a.pairCode)
	a.checkUpdate(false)

	if showWindow {
		a.showSettings()
	}

	var m msg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		if a.isRecording() && (m.message == wmKeyDown || m.message == wmSysKeyDown) {
			a.handleRecordKey(uint32(m.wParam))
			continue
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	a.removeTrayIcon()
	a.cancel()
}

func (a *App) addCtrl(id int, cls, text string, style, exStyle uintptr, x, y, w, h int32, font uintptr) uintptr {
	hwnd, _, _ := procCreateWindowExW.Call(
		exStyle,
		uintptr(unsafe.Pointer(u16(cls))),
		uintptr(unsafe.Pointer(u16(text))),
		wsChild|wsVisible|style,
		uintptr(dpiScale(x)), uintptr(dpiScale(y)), uintptr(dpiScale(w)), uintptr(dpiScale(h)),
		a.hwnd, uintptr(id), a.hInstance, 0,
	)
	if font != 0 {
		procSendMessageW.Call(hwnd, wmSetFont, font, 1)
	}
	a.ctrls[id] = hwnd
	return hwnd
}

func (a *App) buildControls() {
	// 更新提示栏（有新版本时显示）
	a.addCtrl(ctrlUpdateBox, "BUTTON", "软件更新", bsGroupBox, 0, 18, 12, 526, 74, a.fontBold)
	a.addCtrl(ctrlUpdateText, "STATIC", "", ssLeft, 0, 32, 34, 370, 22, a.fontBold)
	a.addCtrl(ctrlUpdateBtn, "BUTTON", "下载并安装", bsPushButton|wsTabStop, 0, 412, 30, 116, 28, a.fontBody)
	a.addCtrl(ctrlUpdateNote, "STATIC", "", ssLeft, 0, 32, 60, 496, 20, a.fontNote)

	// C2: 输入方式区域
	a.addCtrl(ctrlSchemeBox, "BUTTON", "输入方式", bsGroupBox, 0, 18, 16, 526, 134, a.fontBold)
	a.addCtrl(ctrlRadioFlypy, "BUTTON", "小鹤双拼", bsAutoRadio|wsGroup|wsTabStop, 0, 34, 44, 110, 24, a.fontBody)
	a.addCtrl(ctrlRadioQuanpin, "BUTTON", "全拼", bsAutoRadio|wsTabStop, 0, 156, 44, 110, 24, a.fontBody)
	a.addCtrl(ctrlHotkeyLabel, "STATIC", "切换快捷键", ssLeft, 0, 34, 78, 86, 22, a.fontBody)
	a.addCtrl(ctrlHotkeyBtn, "BUTTON", a.hotkey.Label, bsPushButton|wsTabStop, 0, 124, 74, 230, 28, a.fontBody)
	a.addCtrl(ctrlHotkeyReset, "BUTTON", "恢复默认", bsPushButton|wsTabStop, 0, 366, 74, 90, 28, a.fontBody)
	a.addCtrl(ctrlSchemeNote, "STATIC", "快捷键需包含 Ctrl 或 Alt（F1–F12 可单独使用）。也可以点候选框右侧的「双拼 / 全拼」按钮，或右键点击任务栏一炁图标切换。", ssLeft, 0, 34, 110, 494, 34, a.fontNote)

	// C3, C5, C7: 剪贴板同步区域
	a.addCtrl(ctrlSyncBox, "BUTTON", "剪贴板同步", bsGroupBox, 0, 18, 164, 526, 360, a.fontBold)
	a.addCtrl(ctrlSyncStatus, "STATIC", "状态：未配对", ssLeft, 0, 34, 192, 494, 24, a.fontBody)

	// 已配对视图
	a.addCtrl(ctrlBtnInvite, "BUTTON", "添加设备…", bsPushButton|wsTabStop, 0, 34, 226, 118, 30, a.fontBody)
	a.addCtrl(ctrlBtnLeave, "BUTTON", "退出同步组…", bsPushButton|wsTabStop, 0, 164, 226, 118, 30, a.fontBody)
	a.addCtrl(ctrlPairedNote, "STATIC", "要让手机或另一台电脑加入，点「添加设备」，会生成一个 6 位临时密码。", ssLeft, 0, 34, 266, 494, 36, a.fontNote)

	// 邀请视图
	a.addCtrl(ctrlInviteHint, "STATIC", "在新设备的一炁设置里填写：", ssLeft, 0, 34, 222, 494, 22, a.fontBody)
	a.addCtrl(ctrlInviteHost, "STATIC", "", ssLeft, 0, 34, 248, 494, 24, a.fontBold)
	a.addCtrl(ctrlInviteCode, "STATIC", "", ssLeft, 0, 34, 276, 494, 42, a.fontCode)
	a.addCtrl(ctrlInviteTimer, "STATIC", "", ssLeft, 0, 34, 322, 494, 22, a.fontNote)
	a.addCtrl(ctrlBtnInviteDone, "BUTTON", "完成", bsPushButton|wsTabStop, 0, 34, 352, 92, 28, a.fontBody)
	a.addCtrl(ctrlBtnInviteRegen, "BUTTON", "重新生成", bsPushButton|wsTabStop, 0, 138, 352, 98, 28, a.fontBody)

	// 未配对视图
	a.addCtrl(ctrlServerLbl, "STATIC", "服务器地址", ssLeft, 0, 34, 228, 86, 22, a.fontBody)
	srvEdit := a.addCtrl(ctrlServerEdit, "EDIT", "", wsBorder|wsTabStop|esAutoHScroll, wsExClientEdge, 124, 224, 396, 26, a.fontBody)
	setCueBanner(srvEdit, "例如 yiqi.example.com")
	a.addCtrl(ctrlCodeLbl, "STATIC", "临时密码", ssLeft, 0, 34, 264, 86, 22, a.fontBody)
	codeEdit := a.addCtrl(ctrlCodeEdit, "EDIT", "", wsBorder|wsTabStop|esAutoHScroll, wsExClientEdge, 124, 260, 140, 26, a.fontBody)
	setCueBanner(codeEdit, "6 位数字")
	a.addCtrl(ctrlBtnJoin, "BUTTON", "加入同步组", bsPushButton|wsTabStop, 0, 34, 300, 114, 30, a.fontBody)
	a.addCtrl(ctrlJoinNote, "STATIC", "临时密码在已同步的设备上点「添加设备」获得。", ssLeft, 0, 160, 306, 366, 22, a.fontNote)
	a.addCtrl(ctrlBtnRegister, "BUTTON", "注册新同步组", bsPushButton|wsTabStop, 0, 34, 342, 114, 30, a.fontBody)
	a.addCtrl(ctrlRegisterNote, "STATIC", "第一台设备用这个；临时密码在服务器上运行 yiqi-relay code 生成，10 分钟内有效。", ssLeft, 0, 160, 342, 366, 36, a.fontNote)

	// 同步消息与底部说明
	a.addCtrl(ctrlSyncMsg, "STATIC", "", ssLeft, 0, 34, 420, 494, 38, a.fontNote)
	a.addCtrl(ctrlSyncFooterNote, "STATIC", "复制的文字会在本机加密后，经你的服务器同步到同组的其他设备，在那里直接粘贴即可。", ssLeft, 0, 34, 470, 494, 38, a.fontNote)

	// 底部版本与手动检查更新
	a.addCtrl(ctrlBetaCheck, "BUTTON", "接受测试版更新", bsAutoCheckBox|wsTabStop, 0, 22, 542, 130, 24, a.fontNote)
	a.addCtrl(ctrlCheckUpdateStatus, "STATIC", "", ssLeft, 0, 156, 544, 170, 22, a.fontNote)
	a.addCtrl(ctrlVersionLbl, "STATIC", fmt.Sprintf("版本 %s", a.version), ssLeft, 0, 330, 544, 108, 22, a.fontNote)
	a.addCtrl(ctrlCheckUpdateBtn, "BUTTON", "检查更新", bsPushButton|wsTabStop, 0, 444, 538, 100, 28, a.fontBody)

	a.refreshUI()
}

func (a *App) showCtrl(id int, show bool) {
	if h := a.ctrls[id]; h != 0 {
		if show {
			procShowWindow.Call(h, swShow)
		} else {
			procShowWindow.Call(h, swHide)
		}
	}
}

func (a *App) moveCtrl(id int, x, y, w, h int32) {
	if hw := a.ctrls[id]; hw != 0 {
		procMoveWindow.Call(hw, uintptr(dpiScale(x)), uintptr(dpiScale(y)), uintptr(dpiScale(w)), uintptr(dpiScale(h)), 1)
	}
}

func (a *App) refreshUI() {
	a.mu.Lock()
	scheme := a.scheme
	hotkey := a.hotkey
	recording := a.recording
	status := a.status
	host := a.serverHost
	paired := a.pairCode != ""
	invCode := a.inviteCode
	invExp := a.inviteExp
	msgText := a.message
	busy := a.busy
	upd := a.update
	updMsg := a.updateMessage
	a.mu.Unlock()

	if invCode != "" && time.Now().After(invExp) {
		a.stopInvite()
		invCode = ""
	}

	hasUpd := upd != nil
	offset := int32(0)
	if hasUpd {
		offset = 86
		setText(a.ctrls[ctrlUpdateText], fmt.Sprintf("有新版本 %s（当前 %s）", upd.Version, a.version))
		setText(a.ctrls[ctrlUpdateNote], updMsg)
	}
	for _, id := range []int{ctrlUpdateBox, ctrlUpdateText, ctrlUpdateBtn, ctrlUpdateNote} {
		a.showCtrl(id, hasUpd)
	}

	// 动态下移主体控件
	a.moveCtrl(ctrlSchemeBox, 18, 14+offset, 526, 134)
	a.moveCtrl(ctrlRadioFlypy, 34, 42+offset, 110, 24)
	a.moveCtrl(ctrlRadioQuanpin, 156, 42+offset, 110, 24)
	a.moveCtrl(ctrlHotkeyLabel, 34, 76+offset, 86, 22)
	a.moveCtrl(ctrlHotkeyBtn, 124, 72+offset, 240, 28)
	a.moveCtrl(ctrlHotkeyReset, 376, 72+offset, 90, 28)
	a.moveCtrl(ctrlSchemeNote, 34, 108+offset, 494, 34)

	a.moveCtrl(ctrlSyncBox, 18, 160+offset, 526, 326)
	a.moveCtrl(ctrlSyncStatus, 34, 188+offset, 494, 24)
	a.moveCtrl(ctrlBtnInvite, 34, 222+offset, 118, 30)
	a.moveCtrl(ctrlBtnLeave, 164, 222+offset, 118, 30)
	a.moveCtrl(ctrlPairedNote, 34, 262+offset, 494, 36)

	a.moveCtrl(ctrlInviteHint, 34, 218+offset, 494, 22)
	a.moveCtrl(ctrlInviteHost, 34, 244+offset, 494, 24)
	a.moveCtrl(ctrlInviteCode, 34, 272+offset, 494, 40)
	a.moveCtrl(ctrlInviteTimer, 34, 316+offset, 494, 22)
	a.moveCtrl(ctrlBtnInviteDone, 34, 346+offset, 92, 28)
	a.moveCtrl(ctrlBtnInviteRegen, 138, 346+offset, 98, 28)

	a.moveCtrl(ctrlServerLbl, 34, 224+offset, 86, 22)
	a.moveCtrl(ctrlServerEdit, 124, 220+offset, 396, 26)
	a.moveCtrl(ctrlCodeLbl, 34, 260+offset, 86, 22)
	a.moveCtrl(ctrlCodeEdit, 124, 256+offset, 140, 26)
	a.moveCtrl(ctrlBtnJoin, 34, 296+offset, 114, 30)
	a.moveCtrl(ctrlJoinNote, 160, 302+offset, 366, 22)
	a.moveCtrl(ctrlBtnRegister, 34, 338+offset, 114, 30)
	a.moveCtrl(ctrlRegisterNote, 160, 338+offset, 366, 36)

	a.moveCtrl(ctrlSyncMsg, 34, 386+offset, 494, 42)
	a.moveCtrl(ctrlSyncFooterNote, 34, 434+offset, 494, 38)

	a.moveCtrl(ctrlBetaCheck, 22, 500+offset, 130, 24)
	a.moveCtrl(ctrlCheckUpdateStatus, 156, 502+offset, 170, 22)
	betaState := uintptr(bstUnchecked)
	if a.store.BetaUpdates() {
		betaState = bstChecked
	}
	procSendMessageW.Call(a.ctrls[ctrlBetaCheck], bmSetCheck, betaState, 0)
	a.moveCtrl(ctrlVersionLbl, 330, 502+offset, 108, 22)
	a.moveCtrl(ctrlCheckUpdateBtn, 444, 496+offset, 100, 28)

	// 输入方式状态
	if scheme == client.SchemeQuanpin {
		procSendMessageW.Call(a.ctrls[ctrlRadioFlypy], bmSetCheck, bstUnchecked, 0)
		procSendMessageW.Call(a.ctrls[ctrlRadioQuanpin], bmSetCheck, bstChecked, 0)
	} else {
		procSendMessageW.Call(a.ctrls[ctrlRadioFlypy], bmSetCheck, bstChecked, 0)
		procSendMessageW.Call(a.ctrls[ctrlRadioQuanpin], bmSetCheck, bstUnchecked, 0)
	}
	if recording {
		setText(a.ctrls[ctrlHotkeyBtn], "请按下新的快捷键…（Esc 取消）")
	} else {
		setText(a.ctrls[ctrlHotkeyBtn], hotkey.Label)
	}
	a.showCtrl(ctrlHotkeyReset, !recording && !hotkey.Equal(client.DefaultHotkey))

	// 剪贴板同步状态
	stLine := "状态：" + status.Label()
	if host != "" {
		stLine += "    服务器：" + host
	}
	setText(a.ctrls[ctrlSyncStatus], stLine)

	inviting := paired && invCode != ""
	for _, id := range []int{ctrlBtnInvite, ctrlBtnLeave, ctrlPairedNote} {
		a.showCtrl(id, paired && !inviting)
	}
	for _, id := range []int{ctrlInviteHint, ctrlInviteHost, ctrlInviteCode, ctrlInviteTimer, ctrlBtnInviteDone, ctrlBtnInviteRegen} {
		a.showCtrl(id, inviting)
	}
	if inviting {
		setText(a.ctrls[ctrlInviteHost], "服务器地址  "+host)
		if len(invCode) == 6 {
			setText(a.ctrls[ctrlInviteCode], "临时密码  "+invCode[:3]+" "+invCode[3:])
		}
		left := max(0, int(time.Until(invExp).Seconds()))
		if left > 0 {
			setText(a.ctrls[ctrlInviteTimer], fmt.Sprintf("%d:%02d 内有效，请保持此窗口打开", left/60, left%60))
		} else {
			setText(a.ctrls[ctrlInviteTimer], "已过期，请重新生成")
		}
	}
	for _, id := range []int{ctrlServerLbl, ctrlServerEdit, ctrlCodeLbl, ctrlCodeEdit, ctrlBtnJoin, ctrlJoinNote, ctrlBtnRegister, ctrlRegisterNote} {
		a.showCtrl(id, !paired)
	}
	enableJoin := uintptr(1)
	if busy {
		enableJoin = 0
	}
	procEnableWindow.Call(a.ctrls[ctrlBtnJoin], enableJoin)
	procEnableWindow.Call(a.ctrls[ctrlBtnRegister], enableJoin)
	setText(a.ctrls[ctrlSyncMsg], msgText)

	if !hasUpd {
		setText(a.ctrls[ctrlCheckUpdateStatus], updMsg)
	} else {
		setText(a.ctrls[ctrlCheckUpdateStatus], "")
	}
	a.updateTrayTip(scheme)
	procInvalidateRect.Call(a.hwnd, 0, 1)
}

func (a *App) showSettings() {
	a.checkUpdate(false)
	procShowWindow.Call(a.hwnd, swRestore)
	procShowWindow.Call(a.hwnd, swShow)
	procSetForegroundWindow.Call(a.hwnd)
	procUpdateWindow.Call(a.hwnd)
}

func (a *App) isRecording() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.recording
}

func (a *App) handleRecordKey(vk uint32) {
	if vk == vkEscape {
		a.mu.Lock()
		a.recording = false
		a.mu.Unlock()
		a.refreshUI()
		return
	}
	if vk == vkControl || vk == vkMenu || vk == vkShift {
		return
	}
	h, ok := HotkeyFromVK(vk, keyDown(vkControl), keyDown(vkMenu), keyDown(vkShift))
	if !ok {
		return
	}
	_ = a.rime.SetHotkey(h)
	a.mu.Lock()
	a.hotkey = h
	a.recording = false
	a.mu.Unlock()
	a.refreshUI()
}

func (a *App) chooseScheme(s client.Scheme) {
	notifyInputMethodScheme(a.rime, s)
	a.mu.Lock()
	a.scheme = s
	a.mu.Unlock()
	a.refreshUI()
}

func (a *App) pair(register bool) {
	srv := getText(a.ctrls[ctrlServerEdit])
	code := getText(a.ctrls[ctrlCodeEdit])
	a.mu.Lock()
	a.busy = true
	if register {
		a.message = "正在注册…"
	} else {
		a.message = "正在加入…"
	}
	a.mu.Unlock()
	a.refreshUI()

	go func() {
		var pairCode string
		var err error
		if register {
			pairCode, err = client.Register(a.ctx, nil, srv, code)
		} else {
			pairCode, err = client.Join(a.ctx, nil, srv, code)
		}
		a.mu.Lock()
		a.busy = false
		if err != nil {
			a.message = err.Error()
		} else {
			_ = a.store.SetPairCode(pairCode)
			a.pairCode = pairCode
			a.message = ""
		}
		a.mu.Unlock()
		if err == nil {
			a.syncer.Configure(pairCode)
		}
		a.postRefresh()
	}()
}

func (a *App) startInvite() {
	code, exp, err := a.syncer.StartInvite()
	a.mu.Lock()
	if err != nil {
		a.message = err.Error()
	} else {
		a.inviteCode = code
		a.inviteExp = exp
		a.message = ""
	}
	a.mu.Unlock()
	a.refreshUI()
}

func (a *App) stopInvite() {
	a.syncer.StopInvite()
	a.mu.Lock()
	a.inviteCode = ""
	a.inviteExp = time.Time{}
	a.mu.Unlock()
	a.refreshUI()
}

func (a *App) leaveGroup() {
	r, _, _ := procMessageBoxW.Call(
		a.hwnd,
		uintptr(unsafe.Pointer(u16("之后需要在其他已同步的设备上点「添加设备」才能重新加入。"))),
		uintptr(unsafe.Pointer(u16("让这台电脑退出同步组？"))),
		mbOKCancel|mbIconQuestion,
	)
	if r != idOK {
		return
	}
	a.stopInvite()
	_ = a.store.SetPairCode("")
	a.mu.Lock()
	a.pairCode = ""
	a.serverHost = ""
	a.message = ""
	a.mu.Unlock()
	a.syncer.Configure("")
	a.refreshUI()
}

func (a *App) checkUpdate(manual bool) {
	if manual {
		a.mu.Lock()
		a.updateMessage = "正在检查…"
		a.mu.Unlock()
		a.postRefresh()
	}
	go func() {
		rel, ok := client.CheckUpdate(a.ctx, nil, "", a.version, "YiQi-Windows-Setup.exe", a.store.BetaUpdates())
		a.mu.Lock()
		a.update = rel
		if manual || a.updateMessage == "正在检查…" {
			if rel != nil {
				a.updateMessage = ""
			} else if ok {
				a.updateMessage = "已是最新版本"
			} else {
				a.updateMessage = "暂时无法检查更新，请稍后再试"
			}
		}
		a.mu.Unlock()
		if rel != nil {
			a.store.SetUpdateAvailable(rel.Version)
		} else {
			a.store.SetUpdateAvailable("")
		}
		a.postRefresh()
	}()
}

func (a *App) installUpdate() {
	a.mu.Lock()
	rel := a.update
	if rel == nil {
		a.mu.Unlock()
		return
	}
	a.updateMessage = fmt.Sprintf("正在下载 %s…", rel.Version)
	a.mu.Unlock()
	a.refreshUI()

	go func() {
		dest := filepath.Join(os.TempDir(), fmt.Sprintf("YiQi-%s-Setup.exe", rel.Version))
		err := client.DownloadRelease(a.ctx, nil, *rel, dest)
		a.mu.Lock()
		if err != nil {
			a.updateMessage = fmt.Sprintf("下载失败：%v，请稍后重试。", err)
		} else {
			a.updateMessage = "安装程序已打开，按提示完成安装即可。"
		}
		a.mu.Unlock()
		if err == nil {
			shellOpen(dest)
		}
		a.postRefresh()
	}()
}

func (a *App) addTrayIcon(icon uintptr) {
	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = a.hwnd
	nid.uID = 1
	nid.uFlags = nifMessage | nifIcon | nifTip
	nid.uCallbackMessage = wmTray
	nid.hIcon = icon
	tip, _ := syscall.UTF16FromString("一炁输入法（" + a.scheme.Title() + "）")
	copy(nid.szTip[:], tip)
	procShellNotifyIconW.Call(nimAdd, uintptr(unsafe.Pointer(&nid)))
	a.trayAdded = true
}

func (a *App) updateTrayTip(scheme client.Scheme) {
	if !a.trayAdded {
		return
	}
	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = a.hwnd
	nid.uID = 1
	nid.uFlags = nifTip
	tip, _ := syscall.UTF16FromString("一炁输入法（" + scheme.Title() + "）")
	copy(nid.szTip[:], tip)
	procShellNotifyIconW.Call(nimModify, uintptr(unsafe.Pointer(&nid)))
}

func (a *App) removeTrayIcon() {
	if !a.trayAdded {
		return
	}
	var nid notifyIconDataW
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	nid.hWnd = a.hwnd
	nid.uID = 1
	procShellNotifyIconW.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
	a.trayAdded = false
}

func (a *App) showTrayMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	defer procDestroyMenu.Call(menu)

	procAppendMenuW.Call(menu, mfString, menuOpenSettings, uintptr(unsafe.Pointer(u16("一炁输入法设置…"))))
	a.mu.Lock()
	upd := a.update
	scheme := a.scheme
	hk := a.hotkey.Label
	a.mu.Unlock()
	if upd != nil {
		label := fmt.Sprintf("有新版本 %s，点此更新…", upd.Version)
		procAppendMenuW.Call(menu, mfString, menuUpdate, uintptr(unsafe.Pointer(u16(label))))
	}
	procAppendMenuW.Call(menu, mfString, menuCheckUpdate, uintptr(unsafe.Pointer(u16("检查更新…"))))
	procAppendMenuW.Call(menu, mfSeparator, 0, 0)
	nextTitle := "全拼"
	if scheme == client.SchemeQuanpin {
		nextTitle = "小鹤双拼"
	}
	procAppendMenuW.Call(menu, mfString, menuSwitchScheme, uintptr(unsafe.Pointer(u16(fmt.Sprintf("切换至%s（%s）", nextTitle, hk)))))
	procAppendMenuW.Call(menu, mfSeparator, 0, 0)
	procAppendMenuW.Call(menu, mfString, menuExit, uintptr(unsafe.Pointer(u16("退出"))))

	var pt point
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	procSetForegroundWindow.Call(a.hwnd)
	cmd, _, _ := procTrackPopupMenu.Call(menu, tpmRightButton|tpmBottomAlign|tpmReturnCmd, uintptr(pt.x), uintptr(pt.y), 0, a.hwnd, 0)
	switch cmd {
	case menuOpenSettings, menuUpdate:
		a.showSettings()
	case menuCheckUpdate:
		a.showSettings()
		a.checkUpdate(true)
	case menuSwitchScheme:
		a.chooseScheme(scheme.Toggle())
	case menuExit:
		procDestroyWindow.Call(a.hwnd)
	}
}

func wndProc(hwnd uintptr, umsg uint32, wParam, lParam uintptr) uintptr {
	a := globalApp
	if a == nil {
		r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(umsg), wParam, lParam)
		return r
	}
	switch umsg {
	case wmShowSettings:
		a.showSettings()
		return 0
	case wmRefreshUI:
		a.refreshUI()
		return 0
	case wmClipboardUpd:
		seq := clipboardSeq()
		if seq != a.lastClipSeq {
			a.lastClipSeq = seq
			if text, err := a.clip.Read(); err == nil && text != "" {
				a.syncer.OnLocalCopy(text)
			}
		}
		return 0
	case wmTimer:
		switch wParam {
		case timerPoll:
			cur := a.rime.Scheme()
			a.mu.Lock()
			changed := a.scheme != cur
			a.scheme = cur
			inviting := a.inviteCode != ""
			a.mu.Unlock()
			if changed || inviting {
				a.refreshUI()
			}
		case timerUpdateAuto:
			a.checkUpdate(false)
		}
		return 0
	case wmTray:
		switch lParam {
		case wmLButtonDblClk, wmLButtonUp:
			a.showSettings()
		case wmRButtonUp:
			a.showTrayMenu()
		}
		return 0
	case wmCtlColorStatic:
		procSetBkMode.Call(wParam, 1) // TRANSPARENT
		return a.brushBg
	case wmCommand:
		id := int(wParam & 0xFFFF)
		switch id {
		case ctrlRadioFlypy:
			a.chooseScheme(client.SchemeFlypy)
		case ctrlRadioQuanpin:
			a.chooseScheme(client.SchemeQuanpin)
		case ctrlHotkeyBtn:
			a.mu.Lock()
			a.recording = !a.recording
			a.mu.Unlock()
			a.refreshUI()
			procSetFocus.Call(a.hwnd)
		case ctrlHotkeyReset:
			_ = a.rime.SetHotkey(client.DefaultHotkey)
			a.mu.Lock()
			a.hotkey = client.DefaultHotkey
			a.mu.Unlock()
			a.refreshUI()
		case ctrlBtnInvite:
			a.startInvite()
		case ctrlBtnInviteRegen:
			a.startInvite()
		case ctrlBtnInviteDone:
			a.stopInvite()
		case ctrlBtnLeave:
			a.leaveGroup()
		case ctrlBtnJoin:
			a.pair(false)
		case ctrlBtnRegister:
			a.pair(true)
		case ctrlUpdateBtn:
			a.installUpdate()
		case ctrlCheckUpdateBtn:
			a.checkUpdate(true)
		case ctrlBetaCheck:
			r, _, _ := procSendMessageW.Call(a.ctrls[ctrlBetaCheck], bmGetCheck, 0, 0)
			a.store.SetBetaUpdates(r == bstChecked)
			a.checkUpdate(true)
		}
		return 0
	case wmClose:
		a.stopInvite()
		procShowWindow.Call(hwnd, swHide)
		return 0
	case wmDestroy:
		procKillTimer.Call(hwnd, timerPoll)
		procKillTimer.Call(hwnd, timerUpdateAuto)
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, uintptr(umsg), wParam, lParam)
	return r
}
