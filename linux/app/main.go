//go:build linux

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"qi/sync/client"
	"qi/sync/protocol"
)

var version = "1.3.1"

type rpcReq struct {
	Cmd    string   `json:"cmd"`
	Scheme string   `json:"scheme,omitempty"`
	Label  string   `json:"label,omitempty"`
	Rime   []string `json:"rime,omitempty"`
	Sym    string   `json:"sym,omitempty"`
	Ctrl   bool     `json:"ctrl,omitempty"`
	Alt    bool     `json:"alt,omitempty"`
	Shift  bool     `json:"shift,omitempty"`
	Server string   `json:"server,omitempty"`
	Code   string   `json:"code,omitempty"`
	Manual bool     `json:"manual,omitempty"`
	Beta   bool     `json:"beta,omitempty"`
}

type stateResp struct {
	OK            bool          `json:"ok"`
	Error         string        `json:"error,omitempty"`
	Version       string        `json:"version"`
	Scheme        client.Scheme `json:"scheme"`
	SchemeTitle   string        `json:"scheme_title"`
	Hotkey        client.Hotkey `json:"hotkey"`
	IsDefaultKey  bool          `json:"is_default_key"`
	Status        client.Status `json:"status"`
	StatusLabel   string        `json:"status_label"`
	ServerHost    string        `json:"server_host"`
	Paired        bool          `json:"paired"`
	InviteCode    string        `json:"invite_code"`
	InviteLeft    int           `json:"invite_left"`
	Message       string        `json:"message"`
	Busy          bool          `json:"busy"`
	UpdateVersion string        `json:"update_version"`
	UpdateMessage string        `json:"update_message"`
	Beta          bool          `json:"beta"`
	Framework     string        `json:"framework"`
}

type Daemon struct {
	store     *client.Store
	rime      *client.RimeState
	framework string
	syncer    *client.Syncer
	clip      LinuxClipboard
	ctx       context.Context
	cancel    context.CancelFunc

	mu            sync.Mutex
	pairCode      string
	message       string
	busy          bool
	update        *client.Release
	updateMessage string
	lastClip      string
}

func newDaemon() *Daemon {
	store := client.NewStore(configDir())
	dirs, fw := detectRimeDirs()
	rime := client.NewRimeState(dirs...)
	rime.EnsureUserCopies(filepath.Join(dataDir(), "rime-data"))
	clip := LinuxClipboard{}
	syncer := client.NewSyncer(store.DeviceID(), clip)
	// T2: Fcitx5 / IBus 没有从外部触发「同步用户资料」的入口，这里只收发快照，合并要用户在输入法菜单里点「同步」。
	syncer.Dict = &client.DictSync{Dirs: dirs}
	ctx, cancel := context.WithCancel(context.Background())

	d := &Daemon{
		store:     store,
		rime:      rime,
		framework: fw,
		syncer:    syncer,
		clip:      clip,
		ctx:       ctx,
		cancel:    cancel,
		pairCode:  store.PairCode(),
	}
	syncer.OnClip = func(c protocol.Clip) {
		d.mu.Lock()
		d.lastClip = c.Text
		d.mu.Unlock()
	}
	return d
}

func assetNameForLinux() string {
	if runtime.GOARCH == "arm64" {
		return "YiQi-Linux-arm64.tar.gz"
	}
	return "YiQi-Linux-x86_64.tar.gz"
}

func (d *Daemon) snapshot(errMsg string) stateResp {
	d.mu.Lock()
	paired := d.pairCode != ""
	msg := d.message
	busy := d.busy
	upd := d.update
	updMsg := d.updateMessage
	d.mu.Unlock()

	invCode, invExp := d.syncer.InviteInfo()
	left := 0
	if invCode != "" {
		left = max(0, int(time.Until(invExp).Seconds()))
	}
	sc := d.rime.Scheme()
	hk := d.rime.Hotkey()
	st := d.syncer.Status()
	resp := stateResp{
		OK:            errMsg == "",
		Error:         errMsg,
		Version:       version,
		Scheme:        sc,
		SchemeTitle:   sc.Title(),
		Hotkey:        hk,
		IsDefaultKey:  hk.Equal(client.DefaultHotkey),
		Status:        st,
		StatusLabel:   st.Label(),
		ServerHost:    d.syncer.ServerHost(),
		Paired:        paired,
		InviteCode:    invCode,
		InviteLeft:    left,
		Message:       msg,
		Busy:          busy,
		UpdateMessage: updMsg,
		Beta:          d.store.BetaUpdates(),
		Framework:     d.framework,
	}
	if upd != nil {
		resp.UpdateVersion = upd.Version
	}
	return resp
}

func (d *Daemon) checkUpdate(manual bool) {
	if manual {
		d.mu.Lock()
		d.updateMessage = "正在检查…"
		d.mu.Unlock()
	}
	go func() {
		rel, ok := client.CheckUpdate(d.ctx, nil, "", version, assetNameForLinux(), d.store.BetaUpdates())
		d.mu.Lock()
		d.update = rel
		if manual || d.updateMessage == "正在检查…" {
			if rel != nil {
				d.updateMessage = ""
			} else if ok {
				d.updateMessage = "已是最新版本"
			} else {
				d.updateMessage = "暂时无法检查更新，请稍后再试"
			}
		}
		d.mu.Unlock()
		if rel != nil {
			d.store.SetUpdateAvailable(rel.Version)
		} else {
			d.store.SetUpdateAvailable("")
		}
	}()
}

func (d *Daemon) installUpdate() {
	d.mu.Lock()
	rel := d.update
	if rel == nil {
		d.mu.Unlock()
		return
	}
	d.updateMessage = fmt.Sprintf("正在下载 %s…", rel.Version)
	d.mu.Unlock()

	go func() {
		tmpDir, err := os.MkdirTemp("", "yiqi-update-*")
		if err != nil {
			d.setUpdateMessage("创建临时目录失败：" + err.Error())
			return
		}
		tarPath := filepath.Join(tmpDir, assetNameForLinux())
		if err := client.DownloadRelease(d.ctx, nil, *rel, tarPath); err != nil {
			d.setUpdateMessage(fmt.Sprintf("下载失败：%v，请稍后重试。", err))
			return
		}
		d.setUpdateMessage("正在安装新版本…")
		extDir := filepath.Join(tmpDir, "pkg")
		_ = os.MkdirAll(extDir, 0o755)
		if out, err := exec.Command("tar", "-xzf", tarPath, "-C", extDir).CombinedOutput(); err != nil {
			d.setUpdateMessage("解压失败：" + strings.TrimSpace(string(out)))
			return
		}
		installer := filepath.Join(extDir, "install.sh")
		if out, err := exec.Command("bash", installer, "--upgrade").CombinedOutput(); err != nil {
			d.setUpdateMessage("安装失败：" + strings.TrimSpace(string(out)))
			return
		}
		d.setUpdateMessage("更新已完成，即将重新启动…")
		time.AfterFunc(800*time.Millisecond, func() {
			d.cancel()
		})
	}()
}

func (d *Daemon) setUpdateMessage(s string) {
	d.mu.Lock()
	d.updateMessage = s
	d.mu.Unlock()
}

func (d *Daemon) pollClipboard() {
	if cur, err := d.clip.Read(); err == nil {
		d.mu.Lock()
		d.lastClip = cur
		d.mu.Unlock()
	}
	t := time.NewTicker(400 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			cur, err := d.clip.Read()
			if err != nil || cur == "" {
				continue
			}
			d.mu.Lock()
			same := cur == d.lastClip
			if !same {
				d.lastClip = cur
			}
			d.mu.Unlock()
			if !same {
				d.syncer.OnLocalCopy(cur)
			}
		}
	}
}

func (d *Daemon) handleReq(req rpcReq) stateResp {
	switch req.Cmd {
	case "state":
		return d.snapshot("")
	case "set_scheme":
		sc := client.SchemeFlypy
		if req.Scheme == string(client.SchemeQuanpin) {
			sc = client.SchemeQuanpin
		}
		_ = d.rime.RequestScheme(sc)
		return d.snapshot("")
	case "toggle_scheme":
		_ = d.rime.RequestScheme(d.rime.Scheme().Toggle())
		return d.snapshot("")
	case "set_hotkey":
		if req.Sym != "" {
			h, ok := HotkeyFromKeysym(req.Sym, req.Ctrl, req.Alt, req.Shift)
			if !ok {
				return d.snapshot("快捷键需包含 Ctrl 或 Alt（F1–F12 可单独使用）。")
			}
			_ = d.rime.SetHotkey(h)
		} else if req.Label != "" && len(req.Rime) > 0 {
			_ = d.rime.SetHotkey(client.Hotkey{Label: req.Label, Rime: req.Rime})
		}
		return d.snapshot("")
	case "reset_hotkey":
		_ = d.rime.SetHotkey(client.DefaultHotkey)
		return d.snapshot("")
	case "join", "register":
		register := req.Cmd == "register"
		d.mu.Lock()
		d.busy = true
		if register {
			d.message = "正在注册…"
		} else {
			d.message = "正在加入…"
		}
		d.mu.Unlock()
		go func() {
			var pairCode string
			var err error
			if register {
				pairCode, err = client.Register(d.ctx, nil, req.Server, req.Code)
			} else {
				pairCode, err = client.Join(d.ctx, nil, req.Server, req.Code)
			}
			d.mu.Lock()
			d.busy = false
			if err != nil {
				d.message = err.Error()
			} else {
				_ = d.store.SetPairCode(pairCode)
				d.pairCode = pairCode
				d.message = ""
			}
			d.mu.Unlock()
			if err == nil {
				d.syncer.Configure(pairCode)
			}
		}()
		return d.snapshot("")
	case "start_invite":
		_, _, err := d.syncer.StartInvite()
		if err != nil {
			d.mu.Lock()
			d.message = err.Error()
			d.mu.Unlock()
			return d.snapshot(err.Error())
		}
		d.mu.Lock()
		d.message = ""
		d.mu.Unlock()
		return d.snapshot("")
	case "stop_invite":
		d.syncer.StopInvite()
		return d.snapshot("")
	case "leave":
		d.syncer.StopInvite()
		_ = d.store.SetPairCode("")
		d.mu.Lock()
		d.pairCode = ""
		d.message = ""
		d.mu.Unlock()
		d.syncer.Configure("")
		return d.snapshot("")
	case "set_beta":
		d.store.SetBetaUpdates(req.Beta)
		d.checkUpdate(true)
		return d.snapshot("")
	case "check_update":
		d.checkUpdate(req.Manual)
		return d.snapshot("")
	case "install_update":
		d.installUpdate()
		return d.snapshot("")
	case "quit":
		go func() {
			time.Sleep(100 * time.Millisecond)
			d.cancel()
		}()
		return d.snapshot("")
	default:
		return d.snapshot("unknown command")
	}
}

func (d *Daemon) serveSocket() error {
	sock := socketPath()
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		return err
	}
	_ = os.Chmod(sock, 0o600)
	go func() {
		<-d.ctx.Done()
		_ = ln.Close()
		_ = os.Remove(sock)
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if d.ctx.Err() != nil {
				return nil
			}
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			sc := bufio.NewScanner(c)
			sc.Buffer(make([]byte, 4096), 1<<20)
			if !sc.Scan() {
				return
			}
			var req rpcReq
			if json.Unmarshal(sc.Bytes(), &req) != nil {
				return
			}
			resp := d.handleReq(req)
			b, _ := json.Marshal(resp)
			_, _ = c.Write(append(b, '\n'))
		}(conn)
	}
}

func sendRPC(req rpcReq) (*stateResp, error) {
	conn, err := net.DialTimeout("unix", socketPath(), 2*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	b, _ := json.Marshal(req)
	if _, err := conn.Write(append(b, '\n')); err != nil {
		return nil, err
	}
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		return nil, err
	}
	var resp stateResp
	if err := json.Unmarshal(line, &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}

func launchUI(args ...string) {
	exe, err := os.Executable()
	if err == nil {
		cand := filepath.Join(filepath.Dir(exe), "yiqi-ui")
		if _, err := os.Stat(cand); err == nil {
			_ = exec.Command(cand, args...).Start()
			return
		}
	}
	if p, err := exec.LookPath("yiqi-ui"); err == nil {
		_ = exec.Command(p, args...).Start()
	}
}

func main() {
	bg := false
	settings := false
	toggle := false
	status := false
	for _, a := range os.Args[1:] {
		switch a {
		case "--background":
			bg = true
		case "--settings":
			settings = true
		case "--toggle-scheme":
			toggle = true
		case "--status":
			status = true
		}
	}

	if toggle {
		if _, err := sendRPC(rpcReq{Cmd: "toggle_scheme"}); err != nil {
			dirs, _ := detectRimeDirs()
			r := client.NewRimeState(dirs...)
			_ = r.RequestScheme(r.Scheme().Toggle())
		}
		return
	}
	if status {
		resp, err := sendRPC(rpcReq{Cmd: "state"})
		if err != nil {
			fmt.Fprintln(os.Stderr, "yiqi daemon not running")
			os.Exit(1)
		}
		b, _ := json.MarshalIndent(resp, "", "  ")
		fmt.Println(string(b))
		return
	}

	// 如果后台服务已在运行，直接拉起设置界面
	if _, err := sendRPC(rpcReq{Cmd: "state"}); err == nil {
		if !bg || settings {
			launchUI("--settings")
		}
		return
	}

	// 非 --background 时先在后台拉起守护进程并打开设置界面
	if !bg {
		exe, _ := os.Executable()
		cmd := exec.Command(exe, "--background")
		_ = cmd.Start()
		for i := 0; i < 20; i++ {
			time.Sleep(100 * time.Millisecond)
			if _, err := sendRPC(rpcReq{Cmd: "state"}); err == nil {
				break
			}
		}
		launchUI("--settings")
		return
	}

	d := newDaemon()
	go d.syncer.Start(d.ctx)
	d.syncer.Configure(d.pairCode)
	go d.pollClipboard()
	d.checkUpdate(false)
	go func() {
		t := time.NewTicker(6 * time.Hour)
		defer t.Stop()
		for {
			select {
			case <-d.ctx.Done():
				return
			case <-t.C:
				d.checkUpdate(false)
			}
		}
	}()

	first := !d.store.Welcomed()
	if first {
		d.store.MarkWelcomed()
		reloadInputMethod(d.framework)
	}
	if first || d.pairCode == "" {
		launchUI("--tray", "--settings")
	} else {
		launchUI("--tray")
	}

	_ = d.serveSocket()
}
