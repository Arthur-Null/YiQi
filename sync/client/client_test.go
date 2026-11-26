package client

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"qi/sync/protocol"
	"qi/sync/relay"
)

type memClip struct {
	mu   sync.Mutex
	text string
	ch   chan string
}

func newMemClip() *memClip { return &memClip{ch: make(chan string, 8)} }

func (m *memClip) Read() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.text, nil
}

func (m *memClip) Write(t string) error {
	m.mu.Lock()
	m.text = t
	m.mu.Unlock()
	select {
	case m.ch <- t:
	default:
	}
	return nil
}

// C7: 服务器地址支持域名和完整 URL。
func TestServerURL(t *testing.T) {
	cases := map[string]string{
		"yiqi.example.com":              "wss://yiqi.example.com/v1/ws",
		"https://yiqi.example.com":      "wss://yiqi.example.com/v1/ws",
		"http://127.0.0.1:8080":         "ws://127.0.0.1:8080/v1/ws",
		"wss://yiqi.example.com/custom": "wss://yiqi.example.com/custom",
	}
	for in, want := range cases {
		got, err := ServerURL(in)
		if err != nil || got != want {
			t.Fatalf("ServerURL(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := ServerURL("   "); err == nil {
		t.Fatal("empty server accepted")
	}
}

// C2: 输入方式与自定义快捷键的持久化格式与 qi_switch.lua 一致。
func TestRimeStateSchemeAndHotkey(t *testing.T) {
	d1 := t.TempDir()
	d2 := t.TempDir()
	r := NewRimeState(d1, d2)
	if got := r.Scheme(); got != SchemeFlypy {
		t.Fatalf("default scheme = %q", got)
	}
	if err := r.RequestScheme(SchemeQuanpin); err != nil {
		t.Fatal(err)
	}
	if got := r.Scheme(); got != SchemeQuanpin {
		t.Fatalf("scheme after request = %q", got)
	}
	for _, d := range []string{d1, d2} {
		b, err := os.ReadFile(filepath.Join(d, "qi_schema.txt"))
		if err != nil || !strings.HasPrefix(string(b), string(SchemeQuanpin)+" ui-") {
			t.Fatalf("unexpected qi_schema.txt in %s: %q %v", d, string(b), err)
		}
	}
	h := Hotkey{Label: "Ctrl + Alt + K", Rime: []string{"Control+Alt+k"}}
	if err := r.SetHotkey(h); err != nil {
		t.Fatal(err)
	}
	if got := r.Hotkey(); !got.Equal(h) {
		t.Fatalf("hotkey = %+v; want %+v", got, h)
	}
}

// C3, C4, C5, C7: 注册同步组、邀请第二台设备加入、同步单网页级长文本，以及重置后旧设备进入 Invalid 状态。
func TestSyncerEndToEnd(t *testing.T) {
	dir := t.TempDir()
	srvImpl, err := relay.New(dir)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(srvImpl.Handler())
	defer srv.Close()

	setupCode, err := relay.NewSetupCode(dir, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	pairA, err := Register(ctx, srv.Client(), srv.URL, setupCode)
	if err != nil {
		t.Fatal(err)
	}
	cbA, cbB := newMemClip(), newMemClip()
	a := NewSyncer("dev-win", cbA)
	a.HTTPClient = srv.Client()
	connectedA := make(chan struct{}, 1)
	a.OnStatus = func(st Status) {
		if st == StatusConnected {
			select {
			case connectedA <- struct{}{}:
			default:
			}
		}
	}
	go a.Start(ctx)
	a.Configure(pairA)
	select {
	case <-connectedA:
	case <-ctx.Done():
		t.Fatal("device A failed to connect")
	}

	inviteCode, _, err := a.StartInvite()
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)

	pairB, err := Join(ctx, srv.Client(), srv.URL, inviteCode)
	if err != nil {
		t.Fatal(err)
	}
	a.StopInvite()

	b := NewSyncer("dev-linux", cbB)
	b.HTTPClient = srv.Client()
	connectedB := make(chan struct{}, 1)
	b.OnStatus = func(st Status) {
		if st == StatusConnected {
			select {
			case connectedB <- struct{}{}:
			default:
			}
		}
	}
	go b.Start(ctx)
	b.Configure(pairB)
	select {
	case <-connectedB:
	case <-ctx.Done():
		t.Fatal("device B failed to connect")
	}

	long := strings.Repeat("单网页级别长文本，包含密码与 sk-api-key-123456。\n", 1500)
	a.OnLocalCopy(long)
	select {
	case got := <-cbB.ch:
		if got != long {
			t.Fatalf("len mismatch: %d vs %d", len(got), len(long))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("device B did not receive long text")
	}

	b.OnLocalCopy("来自 Linux 的短文本")
	select {
	case got := <-cbA.ch:
		if got != "来自 Linux 的短文本" {
			t.Fatalf("unexpected text: %q", got)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("device A did not receive reply")
	}

	// C5: 服务器重置同步组后旧设备不再被认可。
	if err := relay.Reset(dir); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if a.Status() == StatusInvalid {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if a.Status() != StatusInvalid {
		t.Fatalf("expected StatusInvalid after reset, got %s", a.Status())
	}
	_ = protocol.MaxText
}
