package relay

import (
	"context"
	"encoding/base64"
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

func claim(t *testing.T, srv *httptest.Server, code string, k protocol.Key) int {
	body, _ := json.Marshal(map[string]string{"code": code, "v": protocol.Verifier(k.AuthToken())})
	resp, err := srv.Client().Post(srv.URL+"/v1/claim", "application/json", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func setup(t *testing.T) (*httptest.Server, protocol.Key, string) {
	dir := t.TempDir()
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewTLSServer(s.Handler())
	t.Cleanup(srv.Close)
	k, _ := protocol.NewKey()
	code, err := NewSetupCode(dir, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if c := claim(t, srv, code, k); c != http.StatusOK {
		t.Fatal("claim:", c)
	}
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

// C5, C7: 第一台设备凭服务器上现场生成的临时密码注册同步组：没生成、过期、输错都被拒；用过即作废；
// 已注册时不能再生成；重置后旧设备立即断开，可重新生成并注册。
func TestRegisterWithSetupCode(t *testing.T) {
	dir := t.TempDir()
	s, _ := New(dir)
	srv := httptest.NewTLSServer(s.Handler())
	defer srv.Close()
	k1, _ := protocol.NewKey()
	if c := claim(t, srv, "123456", k1); c != http.StatusForbidden {
		t.Fatal("register without a generated code:", c)
	}
	expired, _ := NewSetupCode(dir, -time.Second)
	if c := claim(t, srv, expired, k1); c != http.StatusForbidden {
		t.Fatal("expired code accepted:", c)
	}
	code, err := NewSetupCode(dir, time.Minute)
	if err != nil || len(code) != 6 {
		t.Fatal(code, err)
	}
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	if c := claim(t, srv, wrong, k1); c != http.StatusForbidden {
		t.Fatal("wrong code:", c)
	}
	if c := claim(t, srv, code, k1); c != http.StatusOK {
		t.Fatal("register:", c)
	}
	k2, _ := protocol.NewKey()
	if c := claim(t, srv, code, k2); c != http.StatusConflict {
		t.Fatal("second register:", c)
	}
	if _, err := NewSetupCode(dir, time.Minute); err != ErrRegistered {
		t.Fatal("code generated for a registered group")
	}
	a, _, err := dial(t, srv, k1.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	if err := Reset(dir); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := a.Read(ctx); err == nil {
		t.Fatal("old device still connected after reset")
	}
	if _, resp, err := dial(t, srv, k1.AuthToken()); err == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatal("old device accepted after reset")
	}
	newCode, _ := NewSetupCode(dir, time.Minute)
	if c := claim(t, srv, newCode, k2); c != http.StatusOK {
		t.Fatal("register after reset:", c)
	}
}

// C5: 输错次数过多后注册临时密码作废
func TestSetupCodeAttemptLimit(t *testing.T) {
	dir := t.TempDir()
	s, _ := New(dir)
	srv := httptest.NewTLSServer(s.Handler())
	defer srv.Close()
	code, _ := NewSetupCode(dir, time.Minute)
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	k, _ := protocol.NewKey()
	for i := 0; i < 10; i++ {
		claim(t, srv, wrong, k)
	}
	if c := claim(t, srv, code, k); c != http.StatusForbidden {
		t.Fatal("code still valid after too many attempts:", c)
	}
}

// C5: 新设备凭已同步设备给出的 6 位临时密码加入：拿到同一个同步组密钥；密码错误拿不到；没有邀请或尝试过多被拒。
func TestJoinWithTemporaryCode(t *testing.T) {
	srv, k, _ := setup(t)
	a, _, err := dial(t, srv, k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	join := func(code string) (protocol.Key, int) {
		priv, _ := protocol.NewEphemeral()
		body, _ := json.Marshal(protocol.Frame{T: "join", D: base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes())})
		resp, err := srv.Client().Post(srv.URL+"/v1/join", "application/json", strings.NewReader(string(body)))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return protocol.Key{}, resp.StatusCode
		}
		var f protocol.Frame
		json.NewDecoder(resp.Body).Decode(&f)
		got, err := protocol.OpenGroupKey(priv, f.D, code)
		if err != nil {
			return protocol.Key{}, http.StatusForbidden
		}
		return got, http.StatusOK
	}
	if _, c := join("123456"); c != http.StatusNotFound {
		t.Fatal("join without invite:", c)
	}

	code := protocol.NewCode()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	msg, _ := json.Marshal(protocol.Frame{T: "invite"})
	a.Write(ctx, websocket.MessageText, msg)
	go func() {
		for {
			_, data, err := a.Read(ctx)
			if err != nil {
				return
			}
			var f protocol.Frame
			json.Unmarshal(data, &f)
			if f.T != "join" {
				continue
			}
			pub, _ := base64.StdEncoding.DecodeString(f.D)
			d, _ := protocol.SealGroupKey(pub, code, k)
			reply, _ := json.Marshal(protocol.Frame{T: "join-ok", J: f.J, D: d})
			a.Write(ctx, websocket.MessageText, reply)
		}
	}()
	time.Sleep(100 * time.Millisecond)
	wrong := "000000"
	if code == wrong {
		wrong = "111111"
	}
	if _, c := join(wrong); c != http.StatusForbidden {
		t.Fatal("wrong code accepted:", c)
	}
	got, c := join(code)
	if c != http.StatusOK || got != k {
		t.Fatal("join failed:", c)
	}
	if _, _, err := dial(t, srv, got.AuthToken()); err != nil {
		t.Fatal("joined device rejected:", err)
	}
	for i := 0; i < 5; i++ {
		join(wrong)
	}
	if _, c := join(code); c != http.StatusTooManyRequests && c != http.StatusNotFound {
		t.Fatal("attempt limit not enforced:", c)
	}
}
