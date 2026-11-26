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

// C5, C7, C8: 凭服务器上现场生成的临时密码注册同步组：没生成、过期、输错都被拒；用过即作废；
// 已有同步组时可以再注册新的组；删除一个组后它的旧设备立即断开，其他组不受影响。
func TestRegisterWithSetupCode(t *testing.T) {
	dir := t.TempDir()
	s, _ := New(dir)
	srv := httptest.NewTLSServer(s.Handler())
	defer srv.Close()
	k1, _ := protocol.NewKey()
	if c := claim(t, srv, "123456", k1); c != http.StatusForbidden {
		t.Fatal("register without a generated code:", c)
	}
	expired, _ := NewSetupCode(dir, -time.Second, "")
	if c := claim(t, srv, expired, k1); c != http.StatusForbidden {
		t.Fatal("expired code accepted:", c)
	}
	code, err := NewSetupCode(dir, time.Minute, "我的设备")
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
	if c := claim(t, srv, code, k2); c != http.StatusForbidden {
		t.Fatal("used code accepted:", c)
	}
	code2, err := NewSetupCode(dir, time.Minute, "")
	if err != nil {
		t.Fatal(err)
	}
	if c := claim(t, srv, code2, k2); c != http.StatusOK {
		t.Fatal("register a second group:", c)
	}
	a, _, err := dial(t, srv, k1.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := dial(t, srv, k2.AuthToken()); err != nil {
		t.Fatal(err)
	}
	if gs := Groups(dir); len(gs) != 2 {
		t.Fatal("groups:", gs)
	}
	if err := Reset(dir, "我的设备"); err != nil {
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
	if _, _, err := dial(t, srv, k2.AuthToken()); err != nil {
		t.Fatal("other group affected by reset:", err)
	}
}

// C8: 两个同步组互相看不到对方的剪贴板和词库；旧版单组数据升级后成为其中一个组。
func TestGroupsIsolatedAndLegacyMigrated(t *testing.T) {
	dir := t.TempDir()
	k1, _ := protocol.NewKey()
	os.WriteFile(filepath.Join(dir, "verifier"), []byte(protocol.Verifier(k1.AuthToken())+"\n"), 0o600)
	legacy, _ := k1.Seal(protocol.Clip{ID: "l", From: "old", TS: 1, Text: "旧版留下的"})
	lb, _ := json.Marshal(legacy)
	os.WriteFile(filepath.Join(dir, "latest.json"), lb, 0o600)
	s, err := New(dir)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewTLSServer(s.Handler())
	defer srv.Close()
	k2, _ := protocol.NewKey()
	code, _ := NewSetupCode(dir, time.Minute, "")
	if c := claim(t, srv, code, k2); c != http.StatusOK {
		t.Fatal("claim:", c)
	}
	a, _, err := dial(t, srv, k1.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	if got := recv(t, a, k1).Text; got != "旧版留下的" {
		t.Fatal("legacy data lost:", got)
	}
	b, _, _ := dial(t, srv, k2.AuthToken())
	time.Sleep(100 * time.Millisecond)
	send(t, a, k1, "第一组的秘密")
	dict, _ := k1.SealDict("dev1", []byte("词库"))
	db, _ := json.Marshal(dict)
	a.Write(context.Background(), websocket.MessageText, db)
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	if _, data, err := b.Read(ctx); err == nil {
		t.Fatal("other group received:", string(data))
	}
	late, _, _ := dial(t, srv, k2.AuthToken())
	ctx2, cancel2 := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel2()
	if _, data, err := late.Read(ctx2); err == nil {
		t.Fatal("other group received on connect:", string(data))
	}
}

// C9: 每台设备最新一份词库快照由服务器保存（只见密文），转发给本组其他设备，后上线的设备也能拿到。
func TestDictSnapshotRelayedAndKept(t *testing.T) {
	srv, k, dir := setup(t)
	a, _, _ := dial(t, srv, k.AuthToken())
	b, _, _ := dial(t, srv, k.AuthToken())
	time.Sleep(100 * time.Millisecond)
	text := strings.Repeat("ni hao\t你好\tc=1 d=1 t=1\n", 5000)
	f, err := k.SealDict("devA", []byte(text))
	if err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(f)
	if err := a.Write(context.Background(), websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
	read := func(c *websocket.Conn) protocol.Frame {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, d, err := c.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var fr protocol.Frame
		json.Unmarshal(d, &fr)
		return fr
	}
	got := read(b)
	plain, err := k.OpenDict(got)
	if got.F != "devA" || err != nil || string(plain) != text {
		t.Fatal("dict not relayed intact:", got.F, err)
	}
	time.Sleep(100 * time.Millisecond)
	late, _, _ := dial(t, srv, k.AuthToken())
	if f := read(late); f.T != "dict" || f.F != "devA" {
		t.Fatal("late device missed dict:", f.T, f.F)
	}
	files, _ := filepath.Glob(filepath.Join(dir, "groups", "*", "dict-devA.json"))
	if len(files) != 1 {
		t.Fatal("snapshot not persisted")
	}
	raw, _ := os.ReadFile(files[0])
	if strings.Contains(string(raw), "你好") || strings.Contains(string(raw), "ni hao") {
		t.Fatal("plaintext in stored snapshot")
	}
}
