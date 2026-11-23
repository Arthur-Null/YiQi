package relay

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// C3, C4, C5, C7: 经用户的公网服务器实测完整流程（设置 QI_LIVE_SERVER 与 QI_LIVE_SETUP_CODE 时运行）：
// 注册同步组、添加设备、新设备凭临时密码加入、网页级长文本同步、陌生设备被拒。
func TestLiveServer(t *testing.T) {
	server, setup := os.Getenv("QI_LIVE_SERVER"), os.Getenv("QI_LIVE_SETUP_CODE")
	if server == "" || setup == "" {
		t.Skip("QI_LIVE_SERVER / QI_LIVE_SETUP_CODE not set")
	}
	httpBase := "https://" + strings.TrimPrefix(strings.TrimSuffix(server, "/v1/ws"), "wss://")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	post := func(path string, body any) (*http.Response, error) {
		b, _ := json.Marshal(body)
		return http.Post(httpBase+path, "application/json", strings.NewReader(string(b)))
	}
	dial := func(token string) (*websocket.Conn, *http.Response, error) {
		c, resp, err := websocket.Dial(ctx, server, &websocket.DialOptions{
			HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
		})
		if c != nil {
			c.SetReadLimit(protocol.MaxFrame)
		}
		return c, resp, err
	}

	k, _ := protocol.NewKey()
	resp, err := post("/v1/claim", map[string]string{"code": setup, "v": protocol.Verifier(k.AuthToken())})
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("register: %v %v", resp, err)
	}
	other, _ := protocol.NewKey()
	if _, resp, err := dial(other.AuthToken()); err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("foreign device not rejected: %v %v", resp, err)
	}
	a, _, err := dial(k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	code := protocol.NewCode()
	msg, _ := json.Marshal(protocol.Frame{T: "invite"})
	a.Write(ctx, websocket.MessageText, msg)
	joinSeen := make(chan bool, 1)
	go func() {
		for {
			_, data, err := a.Read(ctx)
			if err != nil {
				return
			}
			var f protocol.Frame
			json.Unmarshal(data, &f)
			if f.T == "join" {
				pub, _ := base64.StdEncoding.DecodeString(f.D)
				d, _ := protocol.SealGroupKey(pub, code, k)
				reply, _ := json.Marshal(protocol.Frame{T: "join-ok", J: f.J, D: d})
				a.Write(ctx, websocket.MessageText, reply)
				joinSeen <- true
				return
			}
		}
	}()
	time.Sleep(time.Second)
	priv, _ := protocol.NewEphemeral()
	resp, err = post("/v1/join", protocol.Frame{T: "join", D: base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes())})
	if err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("join: %v %v", resp, err)
	}
	var f protocol.Frame
	json.NewDecoder(resp.Body).Decode(&f)
	resp.Body.Close()
	kb, err := protocol.OpenGroupKey(priv, f.D, code)
	if err != nil || kb != k {
		t.Fatal("joined device got wrong key", err)
	}
	<-joinSeen

	b, _, err := dial(kb.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Second)
	long := strings.Repeat("公网中转的网页级长文本测试。", 3000)
	fr, _ := k.Seal(protocol.Clip{ID: "x", From: "a", TS: 1, Text: long})
	data, _ := json.Marshal(fr)
	c2, _, _ := dial(k.AuthToken())
	c2.Write(ctx, websocket.MessageText, data)
	for i := 0; i < 3; i++ {
		_, got, err := b.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var g protocol.Frame
		json.Unmarshal(got, &g)
		if c, err := kb.Open(g); err == nil && c.Text == long {
			return
		}
	}
	t.Fatal("long text not received")
}
