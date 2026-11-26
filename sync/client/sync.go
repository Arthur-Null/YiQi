package client

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

type Status string

const (
	StatusUnpaired   Status = "unpaired"
	StatusConnecting Status = "connecting"
	StatusConnected  Status = "connected"
	StatusOffline    Status = "offline"
	StatusInvalid    Status = "invalid"
)

func (s Status) Label() string {
	switch s {
	case StatusUnpaired:
		return "未配对"
	case StatusConnecting:
		return "连接中…"
	case StatusConnected:
		return "已连接"
	case StatusOffline:
		return "暂时连不上服务器，稍后自动重试"
	case StatusInvalid:
		return "这台设备已不在同步组中，请重新加入"
	default:
		return "未配对"
	}
}

type Clipboard interface {
	Read() (string, error)
	Write(text string) error
}

// C7: 服务器地址由用户填写，可以是域名，也可以是完整地址。
func ServerURL(input string) (string, error) {
	t := strings.TrimSpace(input)
	if t == "" {
		return "", errors.New("服务器地址不对，请填写例如 yiqi.example.com。")
	}
	switch {
	case strings.HasPrefix(t, "https://"):
		t = "wss://" + strings.TrimPrefix(t, "https://")
	case strings.HasPrefix(t, "http://"):
		t = "ws://" + strings.TrimPrefix(t, "http://")
	case !strings.HasPrefix(t, "wss://") && !strings.HasPrefix(t, "ws://"):
		t = "wss://" + t
	}
	u, err := url.Parse(t)
	if err != nil || u.Host == "" {
		return "", errors.New("服务器地址不对，请填写例如 yiqi.example.com。")
	}
	if u.Path == "" || u.Path == "/" {
		u.Path = "/v1/ws"
	}
	return u.String(), nil
}

func endpoint(wsURL, path string) (string, error) {
	u, err := url.Parse(wsURL)
	if err != nil {
		return "", err
	}
	if u.Scheme == "ws" {
		u.Scheme = "http"
	} else {
		u.Scheme = "https"
	}
	u.Path = path
	u.RawQuery = ""
	return u.String(), nil
}

func digitsOnly(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func defaultHTTPClient() *http.Client {
	return &http.Client{Timeout: 40 * time.Second}
}

// C5, C7: 第一台设备凭服务器生成的临时密码注册同步组。
func Register(ctx context.Context, hc *http.Client, serverInput, code string) (string, error) {
	if hc == nil {
		hc = defaultHTTPClient()
	}
	wsURL, err := ServerURL(serverInput)
	if err != nil {
		return "", err
	}
	k, err := protocol.NewKey()
	if err != nil {
		return "", err
	}
	ep, err := endpoint(wsURL, "/v1/claim")
	if err != nil {
		return "", err
	}
	body, _ := json.Marshal(map[string]string{
		"code": digitsOnly(code),
		"v":    protocol.Verifier(k.AuthToken()),
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("连不上服务器（%v），请检查地址和网络。", err)
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		return protocol.PairCode(wsURL, k), nil
	case http.StatusForbidden:
		return "", errors.New("临时密码不对或已过期，请核对后重试。")
	case http.StatusConflict:
		return "", errors.New("这台服务器已经注册过同步组。请在已同步的设备上点「添加设备」，用它给出的 6 位临时密码加入。")
	default:
		return "", fmt.Errorf("连不上服务器（HTTP %d），请检查地址和网络。", resp.StatusCode)
	}
}

// C5, C7: 新设备凭已同步设备给出的 6 位临时密码加入同步组。
func Join(ctx context.Context, hc *http.Client, serverInput, code string) (string, error) {
	if hc == nil {
		hc = defaultHTTPClient()
	}
	wsURL, err := ServerURL(serverInput)
	if err != nil {
		return "", err
	}
	priv, err := protocol.NewEphemeral()
	if err != nil {
		return "", err
	}
	ep, err := endpoint(wsURL, "/v1/join")
	if err != nil {
		return "", err
	}
	body, _ := json.Marshal(protocol.Frame{
		T: "join",
		D: base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes()),
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("连不上服务器（%v），请检查地址和网络。", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	switch resp.StatusCode {
	case http.StatusOK:
		var f protocol.Frame
		if err := json.Unmarshal(raw, &f); err != nil || f.D == "" {
			return "", errors.New("临时密码不对或已过期，请核对后重试。")
		}
		k, err := protocol.OpenGroupKey(priv, f.D, digitsOnly(code))
		if err != nil {
			return "", errors.New("临时密码不对或已过期，请核对后重试。")
		}
		return protocol.PairCode(wsURL, k), nil
	case http.StatusNotFound:
		return "", errors.New("没有找到等待加入的邀请。请先在已同步的设备上点「添加设备」，并保持那个窗口打开。")
	case http.StatusTooManyRequests:
		return "", errors.New("尝试次数过多，请在已同步的设备上重新点「添加设备」获取新的临时密码。")
	default:
		return "", fmt.Errorf("连不上服务器（HTTP %d），请检查地址和网络。", resp.StatusCode)
	}
}

// C3, C4, C5: 跨平台剪贴板同步客户端；只同步最新一条文本，AES-GCM 加密后经中转服务器收发。
type Syncer struct {
	DeviceID   string
	Clipboard  Clipboard
	HTTPClient *http.Client
	OnStatus   func(Status)
	OnClip     func(protocol.Clip)
	// Dict C9: 用户词库同步；为空表示这台设备不同步词库。
	Dict *DictSync

	mu            sync.Mutex
	server        string
	key           protocol.Key
	hasKey        bool
	status        Status
	conn          *websocket.Conn
	connCancel    context.CancelFunc
	inviteCode    string
	inviteExpires time.Time
	lastText      string
	lastTS        int64
	pending       *protocol.Clip
	reconf        chan struct{}
	dictKick      chan struct{}
}

func NewSyncer(deviceID string, cb Clipboard) *Syncer {
	return &Syncer{
		DeviceID:  deviceID,
		Clipboard: cb,
		status:    StatusUnpaired,
		reconf:    make(chan struct{}, 1),
		dictKick:  make(chan struct{}, 1),
	}
}

func (s *Syncer) Status() Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.status
}

func (s *Syncer) ServerHost() string {
	s.mu.Lock()
	srv := s.server
	has := s.hasKey
	s.mu.Unlock()
	if !has || srv == "" {
		return ""
	}
	u, err := url.Parse(srv)
	if err != nil {
		return ""
	}
	return u.Host
}

func (s *Syncer) InviteInfo() (string, time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inviteCode != "" && time.Now().After(s.inviteExpires) {
		s.inviteCode = ""
	}
	return s.inviteCode, s.inviteExpires
}

func (s *Syncer) setStatus(st Status) {
	s.mu.Lock()
	changed := s.status != st
	s.status = st
	cb := s.OnStatus
	s.mu.Unlock()
	if changed && cb != nil {
		cb(st)
	}
}

func (s *Syncer) Configure(pairCode string) {
	s.mu.Lock()
	if s.connCancel != nil {
		s.connCancel()
	}
	s.inviteCode = ""
	if strings.TrimSpace(pairCode) == "" {
		s.server = ""
		s.hasKey = false
		s.pending = nil
	} else if srv, k, err := protocol.ParsePairCode(pairCode); err == nil {
		s.server = srv
		s.key = k
		s.hasKey = true
	} else {
		s.server = ""
		s.hasKey = false
	}
	s.mu.Unlock()
	select {
	case s.reconf <- struct{}{}:
	default:
	}
}

func (s *Syncer) Start(ctx context.Context) {
	retry := time.Second
	for {
		s.mu.Lock()
		hasKey := s.hasKey
		srv := s.server
		k := s.key
		s.mu.Unlock()

		if !hasKey {
			s.setStatus(StatusUnpaired)
			select {
			case <-ctx.Done():
				return
			case <-s.reconf:
				retry = time.Second
			}
			continue
		}

		s.setStatus(StatusConnecting)
		runCtx, cancel := context.WithCancel(ctx)
		s.mu.Lock()
		s.connCancel = cancel
		s.mu.Unlock()

		dialCtx, dialCancel := context.WithTimeout(runCtx, 20*time.Second)
		opts := &websocket.DialOptions{
			HTTPHeader: http.Header{"Authorization": {"Bearer " + k.AuthToken()}},
		}
		if s.HTTPClient != nil {
			opts.HTTPClient = s.HTTPClient
		}
		conn, resp, err := websocket.Dial(dialCtx, srv, opts)
		dialCancel()
		if err != nil {
			cancel()
			// C5: 服务器不再认可这台设备（同步组已在服务器上重置）时不再重试。
			if resp != nil && resp.StatusCode == http.StatusUnauthorized {
				s.setStatus(StatusInvalid)
				select {
				case <-ctx.Done():
					return
				case <-s.reconf:
					retry = time.Second
				}
				continue
			}
			s.setStatus(StatusOffline)
			timer := time.NewTimer(retry)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-s.reconf:
				timer.Stop()
				retry = time.Second
			case <-timer.C:
				retry = min(retry*2, 30*time.Second)
			}
			continue
		}

		conn.SetReadLimit(protocol.MaxFrame)
		s.mu.Lock()
		s.conn = conn
		pend := s.pending
		s.pending = nil
		s.mu.Unlock()
		s.setStatus(StatusConnected)
		retry = time.Second

		if pend != nil {
			s.sendClip(runCtx, conn, k, *pend)
		}

		go s.dictLoop(runCtx, conn, k)

		pingDone := make(chan struct{})
		go func() {
			defer close(pingDone)
			t := time.NewTicker(25 * time.Second)
			defer t.Stop()
			for {
				select {
				case <-runCtx.Done():
					return
				case <-t.C:
					pctx, pcancel := context.WithTimeout(runCtx, 15*time.Second)
					perr := conn.Ping(pctx)
					pcancel()
					if perr != nil {
						cancel()
						return
					}
				}
			}
		}()

		for {
			_, data, rerr := conn.Read(runCtx)
			if rerr != nil {
				break
			}
			var f protocol.Frame
			if json.Unmarshal(data, &f) != nil {
				continue
			}
			switch f.T {
			case "clip":
				clip, oerr := k.Open(f)
				if oerr == nil {
					s.apply(clip)
				}
			case "dict":
				s.applyDict(k, f)
			case "join":
				s.answerJoin(runCtx, conn, k, f.D, f.J)
			}
		}

		cancel()
		<-pingDone
		_ = conn.CloseNow()
		s.mu.Lock()
		if s.conn == conn {
			s.conn = nil
		}
		s.mu.Unlock()

		if ctx.Err() != nil {
			return
		}
		select {
		case <-s.reconf:
			retry = time.Second
		default:
			s.setStatus(StatusOffline)
			timer := time.NewTimer(retry)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-s.reconf:
				timer.Stop()
				retry = time.Second
			case <-timer.C:
				retry = min(retry*2, 30*time.Second)
			}
		}
	}
}

func (s *Syncer) apply(clip protocol.Clip) {
	s.mu.Lock()
	if clip.From == s.DeviceID || clip.TS <= s.lastTS {
		s.mu.Unlock()
		return
	}
	s.lastTS = clip.TS
	s.lastText = clip.Text
	cb := s.Clipboard
	onClip := s.OnClip
	s.mu.Unlock()

	if cb != nil {
		_ = cb.Write(clip.Text)
	}
	if onClip != nil {
		onClip(clip)
	}
}

// OnLocalCopy C3: 监测到本机复制新文本后加密发送；未连接时暂存并在连上后发送。
func (s *Syncer) OnLocalCopy(text string) {
	if text == "" || len(text) > protocol.MaxText {
		return
	}
	s.mu.Lock()
	if !s.hasKey || text == s.lastText {
		s.mu.Unlock()
		return
	}
	s.lastText = text
	s.lastTS = time.Now().UnixMilli()
	clip := protocol.Clip{
		ID:   randomHex(12),
		From: s.DeviceID,
		TS:   s.lastTS,
		Text: text,
	}
	conn := s.conn
	k := s.key
	connected := s.status == StatusConnected
	if !connected || conn == nil {
		s.pending = &clip
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()

	go s.sendClip(context.Background(), conn, k, clip)
}

func (s *Syncer) sendClip(ctx context.Context, conn *websocket.Conn, k protocol.Key, clip protocol.Clip) {
	f, err := k.Seal(clip)
	if err != nil {
		return
	}
	b, _ := json.Marshal(f)
	wctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := conn.Write(wctx, websocket.MessageText, b); err != nil {
		s.mu.Lock()
		s.pending = &clip
		if s.connCancel != nil {
			s.connCancel()
		}
		s.mu.Unlock()
	}
}

// StartInvite C5: 生成 6 位临时密码并通知服务器等待新设备加入。
func (s *Syncer) StartInvite() (string, time.Time, error) {
	s.mu.Lock()
	conn := s.conn
	if conn == nil || s.status != StatusConnected {
		s.mu.Unlock()
		return "", time.Time{}, errors.New("需要先连上服务器才能添加设备。")
	}
	code := protocol.NewCode()
	exp := time.Now().Add(5 * time.Minute)
	s.inviteCode = code
	s.inviteExpires = exp
	s.mu.Unlock()

	s.writeFrame(conn, protocol.Frame{T: "invite"})
	return code, exp, nil
}

func (s *Syncer) StopInvite() {
	s.mu.Lock()
	had := s.inviteCode != ""
	s.inviteCode = ""
	s.inviteExpires = time.Time{}
	conn := s.conn
	s.mu.Unlock()
	if had && conn != nil {
		s.writeFrame(conn, protocol.Frame{T: "invite-end"})
	}
}

func (s *Syncer) answerJoin(ctx context.Context, conn *websocket.Conn, k protocol.Key, peerB64, id string) {
	s.mu.Lock()
	code := s.inviteCode
	exp := s.inviteExpires
	s.mu.Unlock()
	if code == "" || time.Now().After(exp) {
		return
	}
	peer, err := base64.StdEncoding.DecodeString(peerB64)
	if err != nil {
		return
	}
	reply, err := protocol.SealGroupKey(peer, code, k)
	if err != nil {
		return
	}
	s.writeFrame(conn, protocol.Frame{T: "join-ok", J: id, D: reply})
}

func (s *Syncer) writeFrame(conn *websocket.Conn, f protocol.Frame) {
	b, _ := json.Marshal(f)
	wctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = conn.Write(wctx, websocket.MessageText, b)
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
