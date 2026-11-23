//go:build darwin

package relay

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// C3, C5, C7: Mac 端（Swift）注册同步组、用临时密码让第二台加入，经中转同步网页级长文本；第三方设备按同一协议解密。
func TestMacClientInterop(t *testing.T) {
	root, _ := filepath.Abs("../..")
	bin := filepath.Join(t.TempDir(), "peer")
	build := exec.Command("swiftc", "-O", "-o", bin,
		filepath.Join(root, "macos/Sources/Sync.swift"), filepath.Join(root, "macos/Sources/Rime.swift"),
		filepath.Join(root, "tests/macos/main.swift"))
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	s, _ := New(dir)
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()
	wsURL := "ws://" + srv.Listener.Addr().String() + "/v1/ws"

	long := strings.Repeat("这是一段从网页复制的长文本，含 emoji 🎉 与 API key sk-123。\n", 600)
	textFile := filepath.Join(t.TempDir(), "long.txt")
	os.WriteFile(textFile, []byte(long), 0o600)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	setup, _ := NewSetupCode(dir, time.Minute)
	peer := exec.CommandContext(ctx, bin, wsURL, setup, textFile)
	out, _ := peer.StdoutPipe()
	peer.Stderr = os.Stderr
	if err := peer.Start(); err != nil {
		t.Fatal(err)
	}
	var k protocol.Key
	var other *websocket.Conn
	frames := make(chan protocol.Clip, 8)
	sc := bufio.NewScanner(out)
	for sc.Scan() {
		line := sc.Text()
		t.Log(strings.SplitN(line, "&k=", 2)[0])
		if strings.HasPrefix(line, "TIMEOUT") {
			t.Fatal(line)
		}
		if code, ok := strings.CutPrefix(line, "PAIRED "); ok {
			_, k, _ = protocol.ParsePairCode(code)
			var err error
			other, _, err = websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + k.AuthToken()}}})
			if err != nil {
				t.Fatal(err)
			}
			other.SetReadLimit(protocol.MaxFrame)
			go func() {
				for {
					_, data, err := other.Read(ctx)
					if err != nil {
						return
					}
					var f protocol.Frame
					json.Unmarshal(data, &f)
					if c, err := k.Open(f); err == nil {
						frames <- c
					}
				}
			}()
		}
		if line == "READY" {
			select {
			case c := <-frames:
				if c.Text != long || c.From != "mac-a" {
					t.Fatalf("other device got %d bytes from %q", len(c.Text), c.From)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("other device got nothing")
			}
			fr, _ := k.Seal(protocol.Clip{ID: "o1", From: "phone", TS: time.Now().UnixMilli() + 1000, Text: "来自另一台设备"})
			b, _ := json.Marshal(fr)
			other.Write(ctx, websocket.MessageText, b)
		}
	}
	if err := peer.Wait(); err != nil {
		t.Fatal(err)
	}
}
