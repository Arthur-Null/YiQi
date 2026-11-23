package relay

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

func setup(t *testing.T) (*httptest.Server, protocol.Key, string) {
	dir := t.TempDir()
	srv := httptest.NewTLSServer(nil)
	code, err := Init(dir, "wss://"+srv.Listener.Addr().String()+"/v1/ws")
	if err != nil {
		t.Fatal(err)
	}
	_, k, err := protocol.ParsePairCode(code)
	if err != nil {
		t.Fatal(err)
	}
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	srv.Config.Handler = s.Handler()
	t.Cleanup(srv.Close)
	return srv, k, dir
}

func dial(t *testing.T, srv *httptest.Server, token string) (*websocket.Conn, *http.Response, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	u := "wss" + strings.TrimPrefix(srv.URL, "https") + "/v1/ws"
	c, resp, err := websocket.Dial(ctx, u, &websocket.DialOptions{
		HTTPClient: srv.Client(),
		HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
	})
	if c != nil {
		c.SetReadLimit(protocol.MaxFrame)
	}
	return c, resp, err
}

func send(t *testing.T, c *websocket.Conn, k protocol.Key, text string) {
	f, err := k.Seal(protocol.Clip{ID: "x", From: "a", TS: 1, Text: text})
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(f)
	if err := c.Write(context.Background(), websocket.MessageText, b); err != nil {
		t.Fatal(err)
	}
}

func recv(t *testing.T, c *websocket.Conn, k protocol.Key) protocol.Clip {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := c.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var f protocol.Frame
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	clip, err := k.Open(f)
	if err != nil {
		t.Fatal(err)
	}
	return clip
}

// C3, C4: 网页级长文本经 TLS 中转完整到达另一台设备，后上线的设备也能拿到最新一条。
func TestLongTextRelayedAndLatestKept(t *testing.T) {
	srv, k, _ := setup(t)
	a, _, err := dial(t, srv, k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	b, _, err := dial(t, srv, k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	long := strings.Repeat("网页正文，包含标点与 English words 123。\n", 2000)
	send(t, a, k, long)
	if got := recv(t, b, k).Text; got != long {
		t.Fatalf("text mismatch: %d vs %d bytes", len(got), len(long))
	}
	send(t, b, k, "最新一条")
	if got := recv(t, a, k).Text; got != "最新一条" {
		t.Fatal(got)
	}
	late, _, err := dial(t, srv, k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	if got := recv(t, late, k).Text; got != "最新一条" {
		t.Fatal(got)
	}
}

// C5: 没有配对密钥的设备被拒绝。
func TestForeignDeviceRejected(t *testing.T) {
	srv, _, _ := setup(t)
	other, _ := protocol.NewKey()
	_, resp, err := dial(t, srv, other.AuthToken())
	if err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %v %v", resp, err)
	}
	_, resp, err = dial(t, srv, "")
	if err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %v %v", resp, err)
	}
}

// C5: 服务器上只有密文，没有配对密钥也没有明文；用别的密钥解不开。
func TestServerHoldsOnlyCiphertext(t *testing.T) {
	srv, k, dir := setup(t)
	a, _, err := dial(t, srv, k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	secret := "sk-ant-api-key-秘密内容"
	send(t, a, k, secret)
	time.Sleep(200 * time.Millisecond)
	files, _ := filepath.Glob(filepath.Join(dir, "*"))
	for _, f := range files {
		b, _ := os.ReadFile(f)
		if strings.Contains(string(b), secret) || strings.Contains(string(b), "sk-ant") {
			t.Fatalf("plaintext found in %s", f)
		}
		if strings.Contains(string(b), k.AuthToken()) {
			t.Fatalf("auth token stored in %s", f)
		}
	}
	stored, err := os.ReadFile(filepath.Join(dir, "latest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f protocol.Frame
	json.Unmarshal(stored, &f)
	other, _ := protocol.NewKey()
	if _, err := other.Open(f); err == nil {
		t.Fatal("foreign key decrypted content")
	}
	if c, err := k.Open(f); err != nil || c.Text != secret {
		t.Fatal("own key failed to decrypt")
	}
}
